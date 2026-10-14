import Foundation
import Combine
import CoreBluetooth
import WhoopProtocol
import OSLog

// MARK: - NoopBandSyncAdapter
//
// CoreBluetooth orchestration for the WHOOP 5.0, written directly against the
// vendored Noop protocol package (Vendor/Noop/Packages/WhoopProtocol —
// PolyForm Noncommercial 1.0.0, pinned e580175). The package owns every
// protocol fact (framing, CLIENT_HELLO, puffin commands, 5.0 decoders); this
// file owns only the GATT state machine: scan → connect → BOND → hello →
// subscribe → backfill → decode → RawSampleBatch.
//
// Session flow (bond-first, per the official app — verified via APK recon
// 2026-10-12: the official app bonds via CompanionDeviceManager +
// plain createBond(), then hello; the strap refuses SMP (0x05) unless it is
// in pairing mode, i.e. blue flash):
//   1. Scan for the fd4b0001 service.
//   2. Connect; discover the fd4b service + standard profiles (HR, battery).
//   3. BOND FIRST: write the static CLIENT_HELLO to fd4b0002 withResponse.
//      iOS has no createBond() API — touching the encrypted characteristic
//      makes the OS run pairing itself (system dialog). The write fails
//      until the bond exists; we sit in .pairing and retry hello until it
//      succeeds. If the strap refuses the bond (SMP 0x05 — it wasn't in
//      pairing mode) the link drops and we surface .needsPairingMode with
//      instructions, instead of failing silently.
//   4. On the write confirmation (bond established), subscribe to the puffin
//      notify chars (fd4b0003/0004/0005/0007). Subscribing earlier gets the
//      strap to reject with "insufficient authentication".
//   5. requestSync sends SEND_HISTORICAL_DATA (opcode 22, payload [0x00]).
//      The strap streams HISTORY_START → HISTORICAL_DATA records →
//      HISTORY_END (one per ~50 records) → HISTORY_COMPLETE.
//   6. Every HISTORY_END is acked (opcode 23, payload [0x01] + the verbatim
//      8 end-data bytes at frame[21..<29]); the strap only frees acked records.
//   7. On HISTORY_COMPLETE (or a 60 s backstop), the collected frames are run
//      through extractHistoricalStreams and delivered as one RawSampleBatch.
//
// No destructive commands exist on this path (no DFU, no ship-mode, no
// power-cycle — reads and acks only). Every inbound frame is CRC-gated before
// it is acted on. Zero network calls.

/// Puffin command opcodes (WhoopProtocol schema, CommandNumber). The app-layer
/// WhoopCommand enum lives in Noop's Strand/BLE, which was deliberately not
/// vendored — these are the only opcodes this adapter sends.
private enum PuffinOpcode {
    static let sendHistoricalData: UInt8 = 22
    static let historicalDataResult: UInt8 = 23
    static let getBatteryLevel: UInt8 = 26
}

// GATT identifiers for the WHOOP 5.0 "puffin" transport. These live in
// WhoopProtocol's DeviceFamily (serviceUUIDString / characteristicUUIDStrings),
// but the command-characteristic helper there is internal to the package, so
// the values are repeated here instead of re-derived — same values, one place.
// (Noop's own BLEManager hardcodes these exact UUIDs the same way.)
private enum Whoop5Gatt {
    static let service = "fd4b0001-cce1-4033-93ce-002d5875f58a"
    static let cmdWrite = "fd4b0002-cce1-4033-93ce-002d5875f58a"
    static let notify = [
        "fd4b0003-cce1-4033-93ce-002d5875f58a",
        "fd4b0004-cce1-4033-93ce-002d5875f58a",
        "fd4b0005-cce1-4033-93ce-002d5875f58a",
        "fd4b0007-cce1-4033-93ce-002d5875f58a",
    ]
    static var allCharacteristics: [CBUUID] {
        ([cmdWrite] + notify).map { CBUUID(string: $0) }
    }
    static var notifySet: Set<String> { Set(notify) }
}

final class NoopBandSyncAdapter: NSObject, BandSyncProtocol {

    let connectionState = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    let syncProgress = CurrentValueSubject<SyncProgress, Never>(.idle)
    let discoveredBands = CurrentValueSubject<[BandDevice], Never>([])
    var onBatch: ((RawSampleBatch) -> Void)?

    private var central: CBCentralManager!
    private let bleQueue = DispatchQueue(label: "com.unwhoop.ble", qos: .utility)

    /// Restore identifier for CBCentralManager state preservation/restoration.
    /// WHY (PRD §7): without it, iOS kills background BLE and the morning
    /// offload silently stops working — the #1 background-BLE gotcha.
    private static let restoreIdentifier = "com.unwhoop.ble.restore"
    private static let lastBandKey = "com.unwhoop.ble.lastBandUUID"

    // Session state. Everything below is touched only on bleQueue.
    private var seen: [UUID: (peripheral: CBPeripheral, name: String, rssi: Int)] = [:]
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var puffinNotify: [CBCharacteristic] = []
    private var readiness = BandSessionReadiness(requiredNotifications: Whoop5Gatt.notifySet)
    private var helloAcked: Bool { readiness.helloAccepted }
    private var wantSyncOnHello = false
    private var scanRequested = false

    // Backfill ingest.
    private let frameDecoder = BandFrameDecoder()
    private var journal: SyncFrameJournal?
    private var automaticEnabled = false
    private var maximumRecords = 300
    private var pendingAutomaticSync = false
    private var diagnostics: SyncDiagnostics?
    private let logger = Logger(subsystem: "com.unwhoop.app", category: "BandSync")
    private var seq: UInt8 = 1
    private var chunk: [ParsedFrame] = []
    private var syncing = false
    private var backfillTimeout: DispatchWorkItem?
    private var connectionTimeout: DispatchWorkItem?
    private var transferBudgetTimeout: DispatchWorkItem?
    private var lastBatteryPct: Int?
    private var boundary = HistoryTransferBoundary()
    private var commandWrites: [UInt8] = []
    private var bankPauseTimeout: DispatchWorkItem?
    private var requestedPauseReason: SyncStopReason = .recordBudget

    private static let backfillTimeoutSeconds: TimeInterval = 60

    // Bond-first handshake state. The hello write doubles as the iOS bond
    // trigger (no createBond() API on iOS — the OS pairs when we touch an
    // encrypted characteristic). Attempts are bounded: if the strap keeps
    // refusing, it isn't in pairing mode and retrying is futile.
    private var helloBondAttempts = 0
    private var helloRetry: DispatchWorkItem?
    private static let maxHelloBondAttempts = 6
    private static let helloRetryDelaySeconds: TimeInterval = 5

    override init() {
        super.init()
        // Do not construct CoreBluetooth without its required privacy text.
        // A malformed installation must leave the app usable for exports,
        // rather than trap during AppState initialization.
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionState.send(.invalidInstallation)
            return
        }
        central = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
    }

    // MARK: BandSyncProtocol

    func configureAutomaticSync(enabled: Bool, maximumRecords: Int) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let justEnabled = enabled && !self.automaticEnabled
            self.automaticEnabled = enabled
            self.maximumRecords = max(50, maximumRecords)
            if self.syncing { self.scheduleTransferBudget() }
            if justEnabled, self.central?.state == .poweredOn,
               self.peripheral != nil || UserDefaults.standard.string(forKey: Self.lastBandKey) != nil {
                self.requestSyncOnQueue()
            }
        }
    }

    func startScan() {
        bleQueue.async { [weak self] in
            guard let self, self.central != nil else { return }
            self.scanRequested = true
            // Fresh scan, fresh list — drop stale sightings so a band that
            // walked away can't be tapped from a previous scan.
            self.seen.removeAll()
            self.discoveredBands.send([])
            guard self.central.state == .poweredOn else { return }
            self.connectionState.send(.scanning)
            self.central.scanForPeripherals(
                withServices: [CBUUID(string: Whoop5Gatt.service)],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    func stopScan() {
        bleQueue.async { [weak self] in
            guard let self, self.central != nil else { return }
            self.scanRequested = false
            self.central.stopScan()
            if self.connectionState.value == .scanning {
                self.connectionState.send(.disconnected)
            }
        }
    }

    func connect(to device: BandDevice) {
        bleQueue.async { [weak self] in
            guard let self, self.central != nil else { return }
            self.stopScanOnQueue()
            guard let entry = self.seen[device.id] else { return }
            self.beginConnect(entry.peripheral)
        }
    }

    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self, self.central != nil else { return }
            if self.syncing {
                self.finishSync(completed: false, reason: .requestedStop, keepLink: false)
                return
            }
            self.wantSyncOnHello = false
            if let p = self.peripheral {
                self.central.cancelPeripheralConnection(p)
            }
            self.resetSession()
            self.connectionState.send(.disconnected)
        }
    }

    /// Request another bounded transfer without tearing down a healthy link.
    func requestSync() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard self.central != nil else {
                self.syncProgress.send(.failed("This installation is missing its Bluetooth permission text. Install the latest IPA and try again."))
                return
            }
            self.requestSyncOnQueue()
        }
    }

    private func requestSyncOnQueue() {
            if syncing || wantSyncOnHello { return }
            syncProgress.send(.connecting)
            if central.state == .unknown || central.state == .resetting {
                pendingAutomaticSync = true
                return
            }
            guard central.state == .poweredOn else {
                syncProgress.send(.failed("Bluetooth is unavailable. Enable Bluetooth and allow Unwhoop access in Settings, then try again."))
                return
            }
            if let p = peripheral, p.state == .connected, readiness.isReady {
                self.beginBackfill()
                return
            }
            if let p = peripheral, p.state == .connecting || p.state == .connected {
                wantSyncOnHello = true
                scheduleConnectionTimeout()
                return
            }
            // Reconnect to the last bonded band without a scan.
            if let idString = UserDefaults.standard.string(forKey: Self.lastBandKey),
               let uuid = UUID(uuidString: idString) {
                let known = self.central.retrievePeripherals(withIdentifiers: [uuid])
                if let p = known.first {
                    self.wantSyncOnHello = true
                    self.beginConnect(p)
                    return
                }
            }
            syncProgress.send(.failed("Your paired band could not be found. Keep it nearby and try again."))
    }

    // MARK: - Session internals (bleQueue only)

    private func beginConnect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        readiness = BandSessionReadiness(requiredNotifications: Whoop5Gatt.notifySet)
        frameDecoder.reset()
        helloBondAttempts = 0
        helloRetry?.cancel()
        helloRetry = nil
        puffinNotify = []
        cmdChar = nil
        connectionState.send(.connecting)
        central.connect(p)
        scheduleConnectionTimeout()
    }

    private func stopScanOnQueue() {
        scanRequested = false
        central.stopScan()
    }

    private func resetSession() {
        peripheral = nil
        cmdChar = nil
        puffinNotify = []
        readiness = BandSessionReadiness(requiredNotifications: Whoop5Gatt.notifySet)
        wantSyncOnHello = false
        helloBondAttempts = 0
        helloRetry?.cancel()
        helloRetry = nil
        syncing = false
        chunk = []
        backfillTimeout?.cancel()
        backfillTimeout = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
        journal?.close()
        journal = nil
        transferBudgetTimeout?.cancel()
        transferBudgetTimeout = nil
        bankPauseTimeout?.cancel()
        bankPauseTimeout = nil
        boundary = HistoryTransferBoundary()
        requestedPauseReason = .recordBudget
        commandWrites = []
    }

    private func scheduleConnectionTimeout() {
        connectionTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.readiness.isReady else { return }
            self.failConnection("The band did not finish connecting. Keep it nearby and try again.")
        }
        connectionTimeout = timeout
        bleQueue.asyncAfter(deadline: .now() + 40, execute: timeout)
    }

    private func failConnection(_ message: String) {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetSession()
        syncProgress.send(.failed(message))
        connectionState.send(.outOfRange)
    }

    private func finishHandshakeIfReady() {
        guard readiness.takeReadyTransition() else { return }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        connectionState.send(.connected)
        writeCommand(cmd: PuffinOpcode.getBatteryLevel, payload: [0x00], withResponse: true)
        if wantSyncOnHello || automaticEnabled {
            wantSyncOnHello = false
            beginBackfill()
        }
    }

    private func nextSeq() -> UInt8 {
        let s = seq
        seq = seq &+ 1
        return s
    }

    private func writeCommand(cmd: UInt8, payload: [UInt8], withResponse: Bool) {
        guard let p = peripheral, let c = cmdChar else { return }
        let frame = puffinCommandFrame(cmd: cmd, seq: nextSeq(), payload: payload)
        if withResponse { commandWrites.append(cmd) }
        p.writeValue(Data(frame), for: c, type: withResponse ? .withResponse : .withoutResponse)
    }

    /// Phase 1 of the session: trigger bonding. iOS has no createBond() API —
    /// the OS starts pairing on its own when we touch an encrypted
    /// characteristic, presenting the system pairing dialog. The CLIENT_HELLO
    /// write is that touch: until the bond exists the write fails, and each
    /// failure keeps us in the pairing phase (see didWriteValueFor).
    private func writeHello() {
        guard let p = peripheral, let c = cmdChar,
              !DeviceFamily.whoop5ClientHello.isEmpty else { return }
        p.writeValue(Data(DeviceFamily.whoop5ClientHello), for: c, type: .withResponse)
    }

    private func scheduleHelloRetry() {
        helloRetry?.cancel()
        let attempt = DispatchWorkItem { [weak self] in
            self?.retryHelloBond()
        }
        helloRetry = attempt
        bleQueue.asyncAfter(deadline: .now() + Self.helloRetryDelaySeconds, execute: attempt)
    }

    private func retryHelloBond() {
        guard peripheral != nil, cmdChar != nil else { return }
        guard helloBondAttempts < Self.maxHelloBondAttempts else {
            // The strap never accepted the bond. Per the official app's
            // behavior (APK recon 2026-10-12), the strap only bonds while in
            // pairing mode (blue flash) — further retries are futile.
            enterNeedsPairingMode()
            return
        }
        writeHello()
    }

    /// The strap refused the bond (SMP 0x05) or the link died mid-pairing:
    /// tell the user to put the strap in pairing mode instead of failing
    /// silently. Never auto-retry from here — the fix is physical.
    private func enterNeedsPairingMode() {
        helloRetry?.cancel()
        helloRetry = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        resetSession()
        connectionState.send(.needsPairingMode)
        syncProgress.send(.failed("The band needs pairing mode. Make its light flash blue, then try again."))
    }

    private func beginBackfill() {
        guard !syncing, readiness.isReady else { return }
        if let battery = lastBatteryPct, battery < 10 {
            syncProgress.send(.deferred("Band battery is below 10%. Charge the band; automatic sync will retry later."))
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        do {
            journal = try SyncFrameJournal()
        } catch {
            syncProgress.send(.failed("Could not open sync storage: \(error.localizedDescription)"))
            return
        }
        syncing = true
        chunk = []
        boundary = HistoryTransferBoundary()
        diagnostics = SyncDiagnostics(startedAt: .now, historyCommandSent: true, historyStartMarkers: 0,
                                      historyCompleteSeen: false, historicalRecords: 0, realtimeRecords: 0,
                                      lastRRNotificationAt: nil, lastRRSampleAt: nil, rrValuesReceived: 0,
                                      notificationStates: Dictionary(uniqueKeysWithValues: puffinNotify.map { ($0.uuid.uuidString.lowercased(), $0.isNotifying) }),
                                      lastNotificationAt: [:])
        diagnostics?.recordBudget = maximumRecords
        logger.info("Requesting SEND_HISTORICAL_DATA opcode 22; record budget \(self.maximumRecords)")
        syncProgress.send(.receiving(records: 0))
        connectionState.send(.syncing)
        // Payload MUST be [0x00], not empty — the strap serves zero frames
        // for an empty payload even with records pending (verified on-device).
        writeCommand(cmd: PuffinOpcode.sendHistoricalData, payload: [0x00], withResponse: true)
        scheduleTransferBudget()
        refreshBackfillTimeout()
    }

    private func scheduleTransferBudget() {
        transferBudgetTimeout?.cancel()
        diagnostics?.recordBudget = maximumRecords
        let elapsed = Date().timeIntervalSince(diagnostics?.startedAt ?? .now)
        let seconds = maximumRecords == Int.max ? 600.0 : 120.0
        let budget = DispatchWorkItem { [weak self] in self?.pauseAtBudget(.timeBudget) }
        transferBudgetTimeout = budget
        bleQueue.asyncAfter(deadline: .now() + max(1, seconds - elapsed), execute: budget)
    }

    private func refreshBackfillTimeout() {
        backfillTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishSync(completed: false, reason: .quietTimeout)
        }
        backfillTimeout = timeout
        bleQueue.asyncAfter(deadline: .now() + Self.backfillTimeoutSeconds, execute: timeout)
    }

    private func finishSync(completed: Bool, reason: SyncStopReason = .disconnected, keepLink: Bool = true) {
        guard syncing else { return }
        syncing = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        transferBudgetTimeout?.cancel()
        transferBudgetTimeout = nil
        bankPauseTimeout?.cancel()
        bankPauseTimeout = nil
        diagnostics?.stopReason = completed ? .complete : reason

        // Type-47 records carry real unix seconds from the strap RTC, so an
        // identity clock mapping is safe here.
        let now = Int(Date().timeIntervalSince1970)
        let streams = extractHistoricalStreams(
            chunk, deviceClockRef: now, wallClockRef: now, family: .whoop5)

        let stepByTs = Dictionary(streams.steps.map { ($0.ts, $0) }, uniquingKeysWith: { _, newest in newest })
        diagnostics?.lastRRSampleAt = streams.rr.map(\.ts).max().map { Date(timeIntervalSince1970: Double($0)) }
        diagnostics?.journalFile = journal?.url.lastPathComponent
        let batch = RawSampleBatch(
            heartRates: streams.hr.map {
                (date: Date(timeIntervalSince1970: TimeInterval($0.ts)), bpm: Double($0.bpm))
            },
            rrIntervals: streams.rr.map {
                (date: Date(timeIntervalSince1970: TimeInterval($0.ts)),
                 seconds: Double($0.rrMs) / 1000.0)
            },
            motionFrames: streams.gravity.map { g in
                let step = stepByTs[g.ts]
                return MotionFrame(
                    date: Date(timeIntervalSince1970: TimeInterval(g.ts)),
                    x: g.x, y: g.y, z: g.z,
                    activityClass: step?.activityClass.map { UInt8($0) },
                    stepCount: step.map { UInt32($0.counter) }
                )
            },
            skinTemperatures: streams.skinTemp.map {
                (date: Date(timeIntervalSince1970: TimeInterval($0.ts)),
                 celsius: skinTempCelsius(raw: $0.raw, family: .whoop5))
            },
            batteryPercent: streams.battery.last?.soc.map { Int($0) } ?? lastBatteryPct,
            isComplete: completed, diagnostics: diagnostics
        )
        // The strap freed every acked record as we went, so what we hold is
        // ours — deliver even partial (isComplete=false) rather than lose it.
        syncProgress.send(.saving)
        onBatch?(batch)
        logger.info("Transfer ended: complete=\(completed), records=\(self.chunk.count), RR=\(streams.rr.count)")

        journal?.close()
        journal = nil
        chunk = []
        diagnostics = nil
        boundary = HistoryTransferBoundary()
        if keepLink, peripheral?.state == .connected, readiness.isReady {
            connectionState.send(.connected)
        } else {
            if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
            resetSession()
            connectionState.send(.disconnected)
        }
    }

    private func pauseAtBudget(_ reason: SyncStopReason) {
        guard syncing, !boundary.pauseRequested else { return }
        requestedPauseReason = reason
        diagnostics?.recordBudget = maximumRecords
        if boundary.requestPause(hasOpenBank: boundary.hasOpenBank) {
            finishSync(completed: false, reason: reason)
            return
        }
        // Give the current bank a bounded grace period to reach HISTORY_END.
        // Never free an unreceived bank to force a successful transfer.
        let timeout = DispatchWorkItem { [weak self] in self?.finishSync(completed: false, reason: reason, keepLink: false) }
        bankPauseTimeout = timeout
        bleQueue.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    // MARK: Frame handling (bleQueue only)

    private func handleNotifyBytes(_ bytes: [UInt8], channel: String) {
        for frame in frameDecoder.feed(bytes, channel: channel) {
            let parsed = parseFrame(frame, family: .whoop5)
            // CRC-gate every inbound frame before acting on it.
            guard parsed.ok else { continue }
            if syncing, let rrs = parsed.parsed["rr_intervals"]?.intArrayValue, !rrs.isEmpty {
                diagnostics?.lastRRNotificationAt = .now
                diagnostics?.rrLastNotificationByChannel[channel] = .now
                diagnostics?.rrValuesReceived += rrs.count
            }
            if syncing {
                refreshBackfillTimeout()
                do { try journal?.append(Data(frame)) } catch {
                    finishSync(completed: false, reason: .storageFailure)
                    syncProgress.send(.failed("Sync storage failed: \(error.localizedDescription)"))
                    return
                }
            }
            switch parsed.typeName {
            case "COMMAND_RESPONSE":
                handleCommandResponse(parsed)
            case "METADATA":
                handleMetadata(parsed, rawFrame: frame)
            case "HISTORICAL_DATA":
                if syncing {
                    chunk.append(parsed)
                    diagnostics?.historicalRecords += 1
                    syncProgress.send(.receiving(records: chunk.count))
                }
            case "REALTIME_RAW_DATA":
                if syncing {
                    chunk.append(parsed)
                    diagnostics?.realtimeRecords += 1
                    syncProgress.send(.receiving(records: chunk.count))
                }
            default:
                break
            }
            if syncing && chunk.count >= maximumRecords { pauseAtBudget(.recordBudget) }
        }
    }

    private func handleCommandResponse(_ parsed: ParsedFrame) {
        guard let cmd = parsed.cmdName, cmd.contains("GET_BATTERY_LEVEL") else { return }
        // On 5.0 battery_pct is a direct percent (no deci-percent scaling).
        if let pct = parsed.parsed["battery_pct"]?.intValue {
            lastBatteryPct = pct
            if pct < 10 && syncing {
                finishSync(completed: false, reason: .lowBattery, keepLink: false)
                syncProgress.send(.deferred("Band battery is below 10%. Charge the band; automatic sync will retry later."))
                return
            }
            if pct < 20 {
                connectionState.send(.lowBattery)
            }
        }
    }

    private func handleMetadata(_ parsed: ParsedFrame, rawFrame: [UInt8]) {
        guard syncing else { return }
        switch classifyHistoricalMeta(parsed) {
        case .start:
            diagnostics?.historyStartMarkers += 1
            boundary.bankStarted()
            // Each history bank has a start marker. Keep earlier banks.
            break
        case .end:
            // Ack with the verbatim 8 end-data bytes at frame[21..<29]; the
            // strap only frees banked records once acked.
            if rawFrame.count >= 29 {
                // Commit received frames to disk before allowing the band to
                // release this bank. A killed app still retains the raw data.
                do { try journal?.checkpoint() } catch {
                    finishSync(completed: false, reason: .storageFailure)
                    syncProgress.send(.failed("Could not save received history: \(error.localizedDescription)"))
                    return
                }
                let endData = Array(rawFrame[21..<29])
                let ack = whoop5HistoricalAckFrame(endData: endData, seq: nextSeq())
                if let p = peripheral, let c = cmdChar {
                    boundary.bankEnded()
                    commandWrites.append(PuffinOpcode.historicalDataResult)
                    p.writeValue(Data(ack), for: c, type: .withResponse)
                }
            }
        case .complete:
            diagnostics?.historyCompleteSeen = true
            if boundary.completed() { finishSync(completed: true) }
        case .other:
            chunk.append(parsed)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension NoopBandSyncAdapter: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if pendingAutomaticSync {
                pendingAutomaticSync = false
                requestSyncOnQueue()
            } else if automaticEnabled, peripheral == nil,
                      UserDefaults.standard.string(forKey: Self.lastBandKey) != nil {
                requestSyncOnQueue()
            }
            if scanRequested {
                connectionState.send(.scanning)
                central.scanForPeripherals(
                    withServices: [CBUUID(string: Whoop5Gatt.service)],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            }
        case .poweredOff:
            if syncing { finishSync(completed: false) }
            resetSession()
            connectionState.send(.disconnected)
            syncProgress.send(.failed("Bluetooth is off. Turn it on to resume automatic sync."))
        case .unauthorized, .unsupported:
            resetSession()
            syncProgress.send(.failed("Bluetooth access is unavailable. Check Unwhoop permissions in Settings."))
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "WHOOP"
        seen[peripheral.identifier] = (peripheral, name, RSSI.intValue)
        let bands = seen.map { id, entry in
            BandDevice(id: id, name: entry.name, rssi: entry.rssi)
        }.sorted { $0.rssi > $1.rssi }
        discoveredBands.send(bands)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if automaticEnabled { wantSyncOnHello = true }
        // 5.0 session service + standard profiles (live HR, battery).
        peripheral.discoverServices([
            CBUUID(string: Whoop5Gatt.service),
            CBUUID(string: "180D"),
            CBUUID(string: "180F"),
        ])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        failConnection("Could not connect to your band. Keep it nearby and try again.")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        // Mid-sync drop: deliver what the strap already let us ack rather
        // than lose it; unacked records re-stream on the next sync.
        if syncing {
            finishSync(completed: false, reason: .disconnected, keepLink: false)
        } else if connectionState.value == .pairing {
            // Link dropped mid-pairing: the strap refused the bond (SMP
            // 0x05). Per the official app, the strap only accepts bonds in
            // pairing mode (blue flash) — say so instead of failing silently.
            enterNeedsPairingMode()
        } else {
            let interrupted = wantSyncOnHello
            resetSession()
            connectionState.send(.disconnected)
            if interrupted { syncProgress.send(.failed("The band disconnected before sync started. Try again.")) }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // iOS relaunched us (or woke us in background) with a preserved BLE
        // session. Reattach the delegate so the overnight offload can
        // resume/finish without user interaction.
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for p in peripherals {
            p.delegate = self
        }
        if let p = peripherals.first {
            peripheral = p
            readiness = BandSessionReadiness(requiredNotifications: Whoop5Gatt.notifySet)
            connectionState.send(.connecting)
            wantSyncOnHello = automaticEnabled
            scheduleConnectionTimeout()
            if p.state == .connected { centralManager(central, didConnect: p) }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension NoopBandSyncAdapter: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let services = peripheral.services,
              services.contains(where: { $0.uuid.uuidString.lowercased() == Whoop5Gatt.service }) else {
            failConnection("The band did not expose its history service. Try reconnecting.")
            return
        }
        for s in services {
            switch s.uuid.uuidString.lowercased() {
            case Whoop5Gatt.service:
                peripheral.discoverCharacteristics(
                    Whoop5Gatt.allCharacteristics,
                    for: s
                )
            case "180d", "180f":
                peripheral.discoverCharacteristics(nil, for: s)
            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let chars = service.characteristics else {
            if service.uuid.uuidString.lowercased() == Whoop5Gatt.service {
                failConnection("Could not discover the band's data connection. Try again.")
            }
            return
        }
        let cmdUUID = Whoop5Gatt.cmdWrite
        let notifyUUIDs = Whoop5Gatt.notifySet
        for c in chars {
            let uuid = c.uuid.uuidString.lowercased()
            if uuid == cmdUUID {
                cmdChar = c
                // Bond-first: the hello write doubles as the iOS bond trigger
                // (no createBond() on iOS — the OS pairs when we touch the
                // encrypted characteristic). See writeHello().
                writeHello()
            } else if notifyUUIDs.contains(uuid) {
                // Retained but NOT subscribed yet — on an unauthenticated link
                // the strap rejects these, which can wedge the bond. The
                // hello write confirmation subscribes them.
                puffinNotify.append(c)
            } else if uuid == "2a37" {
                peripheral.setNotifyValue(true, for: c)
            } else if uuid == "2a19", c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        let cmdUUID = Whoop5Gatt.cmdWrite
        guard characteristic.uuid.uuidString.lowercased() == cmdUUID else { return }
        if helloAcked {
            guard !commandWrites.isEmpty else { return }
            let command = commandWrites.removeFirst()
            if error != nil {
                if syncing && (command == PuffinOpcode.historicalDataResult || command == PuffinOpcode.sendHistoricalData) {
                    finishSync(completed: false, reason: .commandFailure)
                }
                return
            }
            if command == PuffinOpcode.historicalDataResult, syncing, boundary.acknowledged() {
                finishSync(completed: boundary.completeReceived, reason: requestedPauseReason)
            }
            return
        }
        if error != nil {
            // Post-hello command failures aren't bonding issues — leave them
            // to the backfill timeout / disconnect handlers.
            guard !helloAcked else { return }
            // Hello is always the first encrypted operation, so any failure
            // here means the link isn't bonded yet. Per the official app's
            // flow (bond FIRST, then hello — APK recon 2026-10-12), don't
            // give up: enter the pairing phase and retry. iOS presents the
            // system pairing dialog for the failed encrypted write; each
            // retry re-attempts hello until the bond completes.
            helloBondAttempts += 1
            connectionState.send(.pairing)
            scheduleHelloRetry()
            return
        }
        // Hello acknowledged: the link is up. Persist the band for
        // scan-free reconnects, subscribe the puffin notifies, and kick the
        // pending sync if one was requested.
        guard readiness.acceptHello() else { return }
        helloRetry?.cancel()
        helloRetry = nil
        UserDefaults.standard.set(
            peripheral.identifier.uuidString, forKey: Self.lastBandKey)
        for c in puffinNotify {
            peripheral.setNotifyValue(true, for: c)
        }
        finishHandshakeIfReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let data = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.lowercased()
        diagnostics?.lastNotificationAt[uuid] = .now
        if uuid == "2a19" {
            // Standard battery level: single uint8 percent.
            if let byte = data.first {
                lastBatteryPct = Int(byte)
                if byte < 10 && syncing {
                    finishSync(completed: false, reason: .lowBattery, keepLink: false)
                    syncProgress.send(.deferred("Band battery is below 10%. Charge the band; automatic sync will retry later."))
                    return
                }
                if byte < 20 {
                    connectionState.send(.lowBattery)
                }
            }
            return
        }
        let notifyUUIDs = Whoop5Gatt.notifySet
        if notifyUUIDs.contains(uuid) {
            handleNotifyBytes(Array(data), channel: uuid)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        let uuid = characteristic.uuid.uuidString.lowercased()
        guard Whoop5Gatt.notifySet.contains(uuid) else { return }
        diagnostics?.notificationStates[uuid] = characteristic.isNotifying && error == nil
        logger.info("Notify channel \(uuid, privacy: .public) enabled=\(characteristic.isNotifying), error=\(error != nil)")
        guard error == nil, characteristic.isNotifying else {
            failConnection("The band refused its data subscription. Reconnect and try again.")
            return
        }
        readiness.notificationChanged(uuid, enabled: true)
        finishHandshakeIfReady()
    }
}

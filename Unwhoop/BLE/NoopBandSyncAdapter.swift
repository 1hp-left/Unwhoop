import Foundation
import Combine
import CoreBluetooth
import WhoopProtocol

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
    private var helloAcked = false
    private var wantSyncOnHello = false
    private var scanRequested = false

    // Backfill ingest.
    private let reassembler = Reassembler(family: .whoop5)
    private var seq: UInt8 = 1
    private var chunk: [ParsedFrame] = []
    private var syncing = false
    private var backfillTimeout: DispatchWorkItem?
    private var lastBatteryPct: Int?

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
        // iOS kills the app inside CBCentralManager.init (SIGABRT) if the
        // installed Info.plist lacks NSBluetoothAlwaysUsageDescription.
        // Re-signing tools rewrite the plist when they change the bundle ID
        // and some drop keys doing it — fail here naming the cause instead
        // of the obscure CoreBluetooth assertion.
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
            fatalError("Unwhoop: installed Info.plist is missing NSBluetoothAlwaysUsageDescription — the IPA was re-signed incorrectly (the Bluetooth permission text was dropped). Reinstall with Sideloadly.")
        }
        super.init()
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

    func startScan() {
        bleQueue.async { [weak self] in
            guard let self else { return }
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
            guard let self else { return }
            self.scanRequested = false
            self.central.stopScan()
            if self.connectionState.value == .scanning {
                self.connectionState.send(.disconnected)
            }
        }
    }

    func connect(to device: BandDevice) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.stopScanOnQueue()
            guard let entry = self.seen[device.id] else { return }
            self.beginConnect(entry.peripheral)
        }
    }

    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.wantSyncOnHello = false
            if let p = self.peripheral {
                self.central.cancelPeripheralConnection(p)
            }
            self.resetSession()
            self.connectionState.send(.disconnected)
        }
    }

    /// Opportunistic sync: connect (if needed), burst-download everything new,
    /// disconnect. No continuous foreground BLE — connect, burst, disconnect
    /// (PRD §7 battery budget).
    func requestSync() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            if self.syncing { return }
            if let p = self.peripheral, p.state == .connected, self.helloAcked {
                self.beginBackfill()
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
            self.connectionState.send(.disconnected)
        }
    }

    // MARK: - Session internals (bleQueue only)

    private func beginConnect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        helloAcked = false
        helloBondAttempts = 0
        helloRetry?.cancel()
        helloRetry = nil
        puffinNotify = []
        cmdChar = nil
        connectionState.send(.connecting)
        central.connect(p)
    }

    private func stopScanOnQueue() {
        scanRequested = false
        central.stopScan()
    }

    private func resetSession() {
        peripheral = nil
        cmdChar = nil
        puffinNotify = []
        helloAcked = false
        helloBondAttempts = 0
        helloRetry?.cancel()
        helloRetry = nil
        syncing = false
        chunk = []
        backfillTimeout?.cancel()
        backfillTimeout = nil
    }

    private func nextSeq() -> UInt8 {
        let s = seq
        seq = seq &+ 1
        return s
    }

    private func writeCommand(cmd: UInt8, payload: [UInt8], withResponse: Bool) {
        guard let p = peripheral, let c = cmdChar else { return }
        let frame = puffinCommandFrame(cmd: cmd, seq: nextSeq(), payload: payload)
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
    }

    private func beginBackfill() {
        guard !syncing, helloAcked else { return }
        syncing = true
        chunk = []
        connectionState.send(.syncing)
        // Payload MUST be [0x00], not empty — the strap serves zero frames
        // for an empty payload even with records pending (verified on-device).
        writeCommand(cmd: PuffinOpcode.sendHistoricalData, payload: [0x00], withResponse: true)
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishSync(completed: false)
        }
        backfillTimeout = timeout
        bleQueue.asyncAfter(deadline: .now() + Self.backfillTimeoutSeconds, execute: timeout)
    }

    private func finishSync(completed: Bool) {
        guard syncing else { return }
        syncing = false
        backfillTimeout?.cancel()
        backfillTimeout = nil

        // Type-47 records carry real unix seconds from the strap RTC, so an
        // identity clock mapping is safe here.
        let now = Int(Date().timeIntervalSince1970)
        let streams = extractHistoricalStreams(
            chunk, deviceClockRef: now, wallClockRef: now, family: .whoop5)

        let stepByTs = Dictionary(uniqueKeysWithValues: streams.steps.map { ($0.ts, $0) })
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
            isComplete: completed
        )
        // The strap freed every acked record as we went, so what we hold is
        // ours — deliver even partial (isComplete=false) rather than lose it.
        onBatch?(batch)

        connectionState.send(.connected)
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        resetSession()
        connectionState.send(.disconnected)
    }

    // MARK: Frame handling (bleQueue only)

    private func handleNotifyBytes(_ bytes: [UInt8]) {
        for frame in reassembler.feed(bytes) {
            let parsed = parseFrame(frame, family: .whoop5)
            // CRC-gate every inbound frame before acting on it.
            guard parsed.ok else { continue }
            switch parsed.typeName {
            case "COMMAND_RESPONSE":
                handleCommandResponse(parsed)
            case "METADATA":
                handleMetadata(parsed, rawFrame: frame)
            case "HISTORICAL_DATA":
                chunk.append(parsed)
            default:
                break
            }
        }
    }

    private func handleCommandResponse(_ parsed: ParsedFrame) {
        guard let cmd = parsed.cmdName, cmd.contains("GET_BATTERY_LEVEL") else { return }
        // On 5.0 battery_pct is a direct percent (no deci-percent scaling).
        if let pct = parsed.parsed["battery_pct"]?.intValue {
            lastBatteryPct = pct
            if pct < 20 {
                connectionState.send(.lowBattery)
            }
        }
    }

    private func handleMetadata(_ parsed: ParsedFrame, rawFrame: [UInt8]) {
        switch classifyHistoricalMeta(parsed) {
        case .start:
            chunk = []
        case .end:
            // Ack with the verbatim 8 end-data bytes at frame[21..<29]; the
            // strap only frees banked records once acked.
            if rawFrame.count >= 29 {
                let endData = Array(rawFrame[21..<29])
                let ack = whoop5HistoricalAckFrame(endData: endData, seq: nextSeq())
                if let p = peripheral, let c = cmdChar {
                    p.writeValue(Data(ack), for: c, type: .withResponse)
                }
            }
        case .complete:
            finishSync(completed: true)
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
            if scanRequested {
                connectionState.send(.scanning)
                central.scanForPeripherals(
                    withServices: [CBUUID(string: Whoop5Gatt.service)],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            }
        case .poweredOff:
            resetSession()
            connectionState.send(.disconnected)
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
        resetSession()
        connectionState.send(.outOfRange)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // Mid-sync drop: deliver what the strap already let us ack rather
        // than lose it; unacked records re-stream on the next sync.
        if syncing {
            finishSync(completed: false)
        } else if connectionState.value == .pairing {
            // Link dropped mid-pairing: the strap refused the bond (SMP
            // 0x05). Per the official app, the strap only accepts bonds in
            // pairing mode (blue flash) — say so instead of failing silently.
            enterNeedsPairingMode()
        } else {
            resetSession()
            connectionState.send(.disconnected)
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
            connectionState.send(.syncing)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension NoopBandSyncAdapter: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
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
        guard error == nil, let chars = service.characteristics else { return }
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
        let cmdUUID = Whoop5Gatt.cmdWrite
        guard characteristic.uuid.uuidString.lowercased() == cmdUUID else { return }
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
        helloAcked = true
        UserDefaults.standard.set(
            peripheral.identifier.uuidString, forKey: Self.lastBandKey)
        for c in puffinNotify {
            peripheral.setNotifyValue(true, for: c)
        }
        connectionState.send(.connected)
        // Opportunistic battery read while the link is warm.
        writeCommand(cmd: PuffinOpcode.getBatteryLevel, payload: [0x00], withResponse: true)
        if wantSyncOnHello {
            wantSyncOnHello = false
            beginBackfill()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.lowercased()
        if uuid == "2a19" {
            // Standard battery level: single uint8 percent.
            if let byte = data.first {
                lastBatteryPct = Int(byte)
                if byte < 20 {
                    connectionState.send(.lowBattery)
                }
            }
            return
        }
        let notifyUUIDs = Whoop5Gatt.notifySet
        if notifyUUIDs.contains(uuid) {
            handleNotifyBytes(Array(data))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Subscription confirmations need no action; frames arrive via
        // didUpdateValueFor.
    }
}

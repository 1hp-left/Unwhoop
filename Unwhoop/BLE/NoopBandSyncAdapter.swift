import Foundation
import Combine
import CoreBluetooth

// MARK: - NoopBandSyncAdapter
//
// Skeleton adapter: the seam between Unwhoop and Noop's forked BLE layer.
// The WHOOP 5.0 protocol work (framing, CLIENT_HELLO, historical streams) is
// NOT reimplemented here — it is vendored from the Noop fork. See
// Vendor/Noop/FORK_PLAN.md for the exact vendoring steps and pinned commit.
//
// Noop files this adapter will wrap (paths inside Vendor/Noop/ once vendored):
//   Protocol / framing / decode — Packages/WhoopProtocol/Sources/WhoopProtocol/
//     - Framing.swift            — CRC16-Modbus frame encode/decode
//     - Whoop5RR.swift           — 5.0 R-R interval stream decode
//     - Whoop5RawImu.swift       — 5.0 raw motion frames (activity class + steps)
//     - Whoop5RawOptical.swift   — 5.0 optical/HR stream decode
//     - HistoricalStreams.swift  — overnight stored-data ("puffin") offload
//     - DeviceFamily.swift       — Whoop-5 path selection
//   BLE orchestration — Strand/BLE/
//     - BLEManager.swift         — central manager, connect/reconnect
//     - SourceCoordinator.swift  — live + historical source coordination
//     - BackfillPolicy.swift     — what to pull on opportunistic sync
//
// Every method below is a TODO(fork) until the fork is vendored.

final class NoopBandSyncAdapter: NSObject, BandSyncProtocol {

    let connectionState = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    let discoveredBands = CurrentValueSubject<[BandDevice], Never>([])
    var onBatch: ((RawSampleBatch) -> Void)?

    private var central: CBCentralManager!
    private let bleQueue = DispatchQueue(label: "com.unwhoop.ble", qos: .utility)

    /// Restore identifier for CBCentralManager state preservation/restoration.
    /// WHY (PRD §7): without it, iOS kills background BLE and the morning
    /// offload silently stops working — the #1 background-BLE gotcha. With
    /// preservation, iOS relaunches/wakes the app into
    /// centralManager(_:willRestoreState:) so the overnight sync can finish.
    private static let restoreIdentifier = "com.unwhoop.ble.restore"

    override init() {
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
        // TODO(fork): delegate scan to Strand/BLE/BLEManager.swift (Whoop-5
        // service UUID family fd4b0001-… filter); publish via discoveredBands.
        forkGate(#function)
    }

    func stopScan() {
        // TODO(fork): BLEManager stopScan passthrough.
        forkGate(#function)
    }

    func connect(to device: BandDevice) {
        // TODO(fork): BLEManager connect + CLIENT_HELLO via
        // Packages/WhoopProtocol (HelloIdentityProbe / DeviceFamily Whoop-5 path).
        forkGate(#function)
    }

    func disconnect() {
        // TODO(fork): BLEManager disconnect; keep bonded peripheral for restore.
        forkGate(#function)
    }

    func requestSync() {
        // TODO(fork): BackfillPolicy-driven historical offload
        // (HistoricalStreams.swift "puffin" packets) -> decode R-R via
        // Whoop5RR.swift, motion via Whoop5RawImu.swift, HR via
        // Whoop5RawOptical.swift/PpgHr.swift -> assemble RawSampleBatch and
        // invoke onBatch on a background queue. Connect, burst-download,
        // disconnect — never poll (PRD §7).
        forkGate(#function)
    }

    // MARK: - Private

    /// Trap for the pre-fork skeleton. Only reachable before Vendor/Noop is
    /// vendored; every call site is marked TODO(fork).
    private func forkGate(_ function: String) -> Never {
        fatalError(
            "NoopBandSyncAdapter.\(function): Noop fork is not vendored yet. " +
            "Follow Vendor/Noop/FORK_PLAN.md, then wire this call to the referenced Noop file."
        )
    }
}

// MARK: - CBCentralManagerDelegate (state restoration)

extension NoopBandSyncAdapter: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Minimal pre-fork handling: surface power state honestly.
        // TODO(fork): hand full state machine to Strand/BLE/BLEManager.swift.
        if central.state == .poweredOff {
            connectionState.send(.disconnected)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // iOS relaunched us (or woke us in background) with a preserved BLE
        // session. Reattach the delegate to any restored peripherals so the
        // overnight offload can resume/finish without user interaction.
        // TODO(fork): hand restored peripherals to BLEManager/SourceCoordinator
        // for session resumption.
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in peripherals {
            peripheral.delegate = self
        }
        if !peripherals.isEmpty {
            connectionState.send(.syncing)
        }
    }
}

// MARK: - CBPeripheralDelegate
//
// Conformance exists so state restoration can reattach the delegate to
// restored peripherals. GATT callbacks move to the vendored Noop layer
// (Strand/BLE/FrameRouter.swift) — TODO(fork).
extension NoopBandSyncAdapter: CBPeripheralDelegate {}

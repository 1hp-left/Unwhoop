import SwiftUI
import SwiftData
import Observation

// MARK: - AppState

/// Single observable owner for pairing flow, band link, and sync state.
/// Analytics results are read from SwiftData via @Query in the views;
/// AppState never recomputes them.
@Observable
final class AppState {
    /// The narrow BLE seam (PRD §5.1). Swap the implementation without
    /// touching analytics or UI.
    let sync: any BandSyncProtocol

    var pairingPhase: PairingPhase = .idle
    /// One-time warning: never open the official WHOOP app against the same
    /// band (a firmware push can break third-party sync). Shown ONCE at
    /// pairing, then never again (PRD §7).
    var showPairingWarning = false
    private(set) var pairingDevice: BandDevice?
    private(set) var pairingHandshakeComplete = false

    init(sync: any BandSyncProtocol = NoopBandSyncAdapter()) {
        self.sync = sync
        // Wire sync batches to persistence. Scoring hooks in here once the
        // analytics workstream lands — today we only record link health.
        // (Calling the analytics stubs from a live path would trap.)
        sync.onBatch = { [weak self] batch in
            self?.handleBatch(batch)
        }
    }

    func beginPairing(to device: BandDevice) {
        pairingDevice = device
        pairingHandshakeComplete = false
        pairingPhase = .connecting(device)
        sync.connect(to: device)
    }

    /// A CurrentValueSubject replays its last value to a new screen. Only
    /// accept success for a band selected in this attempt, once per attempt.
    func acceptPairingConnection() -> Bool {
        guard pairingDevice != nil, !pairingHandshakeComplete else { return false }
        pairingHandshakeComplete = true
        return true
    }

    func cancelPairing() {
        if pairingDevice != nil { sync.disconnect() }
        pairingDevice = nil
        pairingHandshakeComplete = false
        pairingPhase = .idle
    }

    /// Called after the warning is acknowledged, so changing the root view
    /// cannot tear down the warning before the user has read it.
    func completePairing(settings: AppSettings, context: ModelContext) throws {
        guard let device = pairingDevice, pairingHandshakeComplete else { return }
        let link = try context.fetch(FetchDescriptor<SyncState>()).first ?? SyncState()
        settings.pairedDeviceUUID = device.id.uuidString
        settings.pairingWarningShown = true
        if link.modelContext == nil { context.insert(link) }
        link.deviceUUID = device.id.uuidString
        link.deviceName = device.name
        link.connectionRaw = ConnectionState.connected.rawValue
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        pairingDevice = nil
        pairingHandshakeComplete = false
        pairingPhase = .idle
    }

    private func handleBatch(_ batch: RawSampleBatch) {
        // TODO(pipeline): hand batch to ingestion -> analytics (milestone 1+).
        // For now: nothing persists raw samples yet; SyncState.lastSync is
        // updated by the view layer after requestSync completes.
    }
}

/// Pairing flow states (PRD §6).
enum PairingPhase: Equatable {
    case idle
    case requestingPermission
    case scanning
    case connecting(BandDevice)
    case pairing
    case needsPairingMode
    case failed(String)
}

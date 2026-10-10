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
    let sync: any BandSyncProtocol = NoopBandSyncAdapter()

    var pairingPhase: PairingPhase = .idle
    /// One-time warning: never open the official WHOOP app against the same
    /// band (a firmware push can break third-party sync). Shown ONCE at
    /// pairing, then never again (PRD §7).
    var showPairingWarning = false

    init() {
        // Wire sync batches to persistence. Scoring hooks in here once the
        // analytics workstream lands — today we only record link health.
        // (Calling the analytics stubs from a live path would trap.)
        sync.onBatch = { [weak self] batch in
            self?.handleBatch(batch)
        }
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
    case failed(String)
}

import SwiftUI
import SwiftData
import Observation
import Combine

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
    private(set) var syncStatus: SyncProgress = .idle
    private(set) var latestRawExport: URL?
    @ObservationIgnored private var persistenceContext: ModelContext?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private let rawStore: RawSyncStore

    init(sync: any BandSyncProtocol = NoopBandSyncAdapter(), rawStore: RawSyncStore = RawSyncStore()) {
        self.sync = sync
        self.rawStore = rawStore
        sync.syncProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncStatus = $0 }
            .store(in: &subscriptions)
        sync.onBatch = { [weak self] batch in
            self?.handleBatch(batch)
        }
    }

    func configurePersistence(_ context: ModelContext) {
        persistenceContext = context
        if latestRawExport == nil,
           let files = try? FileManager.default.contentsOfDirectory(at: rawStore.directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            latestRawExport = files.filter { $0.pathExtension == "json" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.first
        }
    }

    func requestSync() {
        guard !syncStatus.isBusy else { return }
        syncStatus = .connecting
        sync.requestSync()
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
        // The adapter calls on its BLE queue. Save raw data there, and use
        // the UI's ModelContext only on the main queue.
        let result: Result<(url: URL, samples: Int), Error>
        do { result = .success(try rawStore.save(batch)) }
        catch { result = .failure(error) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let saved = try result.get()
                self.latestRawExport = saved.url
                guard let context = self.persistenceContext else {
                    self.syncStatus = .failed("Received data was saved, but sync settings are unavailable. Reopen the app.")
                    return
                }
                let link = try context.fetch(FetchDescriptor<SyncState>()).first ?? SyncState()
                if link.modelContext == nil { context.insert(link) }
                link.lastSampleCount = saved.samples
                link.batteryPercent = batch.batteryPercent ?? link.batteryPercent
                if batch.isComplete { link.lastSync = .now }
                let outcome = SyncProgress.completed(samples: saved.samples, complete: batch.isComplete)
                link.lastSyncMessage = outcome.label
                do { try context.save() } catch {
                    context.rollback()
                    throw error
                }
                self.syncStatus = outcome
            } catch {
                self.syncStatus = .failed("Could not save sync: \(error.localizedDescription). Please try again.")
            }
        }
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

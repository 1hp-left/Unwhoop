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
    var nextAutomaticSyncAt: Date?
    var automaticSyncHint: String?
    private(set) var hasBudgetContinuation = false
    @ObservationIgnored var onSyncFinished: ((Bool) -> Void)?
    @ObservationIgnored private var persistenceContext: ModelContext?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private let rawStore: RawSyncStore
    @ObservationIgnored private var pipeline: SensorPipeline?
    @ObservationIgnored private let processingQueue = DispatchQueue(label: "com.unwhoop.analytics", qos: .utility)

    init(sync: any BandSyncProtocol = NoopBandSyncAdapter(), rawStore: RawSyncStore = RawSyncStore()) {
        self.sync = sync
        self.rawStore = rawStore
        self.syncStatus = sync.syncProgress.value
        sync.syncProgress
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncStatus = $0 }
            .store(in: &subscriptions)
        sync.onBatch = { [weak self] batch in
            self?.handleBatch(batch)
        }
    }

    func configurePersistence(_ context: ModelContext) {
        let firstConfiguration = persistenceContext == nil
        persistenceContext = context
        pipeline = SensorPipeline(container: context.container)
        if latestRawExport == nil,
           let files = try? FileManager.default.contentsOfDirectory(at: rawStore.directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            latestRawExport = files.filter { $0.pathExtension == "json" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.first
        }
        if firstConfiguration { replayUnprocessedArchives() }
    }

    var hasPairedBand: Bool {
        guard let context = persistenceContext else { return false }
        return (try? context.fetch(FetchDescriptor<AppSettings>()).first?.isPaired) ?? false
    }

    func refreshScores() {
        guard let pipeline else { return }
        processingQueue.async { [weak self] in
            do {
                let message = try pipeline.refresh()
                DispatchQueue.main.async { self?.updateScoringMessage(message) }
            } catch {
                DispatchQueue.main.async { self?.syncStatus = .failed("Could not calculate scores: \(error.localizedDescription)") }
            }
        }
    }

    private func updateScoringMessage(_ message: String) {
        guard let context = persistenceContext,
              let link = try? context.fetch(FetchDescriptor<SyncState>()).first else { return }
        link.scoringMessage = message
        try? context.save()
    }

    private func replayUnprocessedArchives() {
        guard let pipeline else { return }
        let directory = rawStore.directory
        let store = rawStore
        processingQueue.async { [weak self] in
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let marker = file.appendingPathExtension("ingested")
                guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
                do {
                    let stored = try decoder.decode(StoredSyncBatch.self, from: Data(contentsOf: file))
                    let report = try pipeline.ingest(stored.batch)
                    try Data().write(to: marker, options: .atomic)
                    if let journal = stored.diagnostics?.journalFile,
                       journal == URL(fileURLWithPath: journal).lastPathComponent {
                        try Data().write(to: directory.appendingPathComponent(journal).appendingPathExtension("ingested"), options: .atomic)
                    }
                    DispatchQueue.main.async { self?.updateScoringMessage(report.message) }
                } catch {
                    DispatchQueue.main.async { self?.syncStatus = .failed("Stored data could not be processed: \(error.localizedDescription)") }
                }
            }
            for file in files.filter({ $0.pathExtension == "frames" }) {
                let marker = file.appendingPathExtension("ingested")
                guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
                do {
                    let batch = try store.recoverJournal(file)
                    let report = try pipeline.ingest(batch)
                    _ = try store.save(batch)
                    try Data().write(to: marker, options: .atomic)
                    DispatchQueue.main.async { self?.updateScoringMessage(report.message) }
                } catch {
                    DispatchQueue.main.async { self?.syncStatus = .failed("Interrupted history could not be recovered: \(error.localizedDescription)") }
                }
            }
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
                guard self.persistenceContext != nil, let pipeline = self.pipeline else {
                    self.syncStatus = .failed("Received data was saved, but sync settings are unavailable. Reopen the app.")
                    self.onSyncFinished?(false)
                    return
                }
                self.syncStatus = .saving
                if saved.samples == 0 {
                    // No sensor rows or analytics work are needed. Complete
                    // the empty-transfer state on this queue immediately.
                    let report = try pipeline.ingest(batch)
                    try Data().write(to: saved.url.appendingPathExtension("ingested"), options: .atomic)
                    self.finishProcessing(batch, report: report)
                    return
                }
                self.processingQueue.async { [weak self] in
                    do {
                        let report = try pipeline.ingest(batch)
                        try Data().write(to: saved.url.appendingPathExtension("ingested"), options: .atomic)
                        if let journal = batch.diagnostics?.journalFile,
                           journal == URL(fileURLWithPath: journal).lastPathComponent {
                            try Data().write(to: saved.url.deletingLastPathComponent().appendingPathComponent(journal).appendingPathExtension("ingested"), options: .atomic)
                        }
                        DispatchQueue.main.async { self?.finishProcessing(batch, report: report) }
                    } catch {
                        DispatchQueue.main.async {
                            self?.syncStatus = .failed("Data saved, but scoring failed: \(error.localizedDescription)")
                            self?.onSyncFinished?(false)
                        }
                    }
                }
            } catch {
                self.syncStatus = .failed("Could not save sync: \(error.localizedDescription). Please try again.")
                self.onSyncFinished?(false)
            }
        }
    }

    private func finishProcessing(_ batch: RawSampleBatch, report: ScoringReport) {
        guard let context = persistenceContext else { return }
        do {
                let link = try context.fetch(FetchDescriptor<SyncState>()).first ?? SyncState()
                if link.modelContext == nil { context.insert(link) }
                link.lastSampleCount = report.acceptedSamples
                if report.acceptedSamples > 0 { link.lastReceivedAt = .now }
                link.batteryPercent = batch.batteryPercent ?? link.batteryPercent
                if batch.isComplete && report.acceptedSamples > 0 { link.lastSync = .now }
                let outcome: SyncProgress
                if report.acceptedSamples == 0 { outcome = .waitingForData }
                else if !batch.isComplete, let reason = batch.diagnostics?.stopReason, reason.isBudgetPause {
                    outcome = .paused(samples: report.acceptedSamples, reason: reason.explanation)
                } else { outcome = .completed(samples: report.acceptedSamples, complete: batch.isComplete) }
                hasBudgetContinuation = !batch.isComplete && report.acceptedSamples > 0
                    && batch.diagnostics?.stopReason?.isBudgetPause == true
                link.lastSyncMessage = outcome.label
                link.transferMessage = batch.diagnostics?.stopReason?.explanation
                link.historyMessage = report.history
                link.rrMessage = report.rr
                link.scoringMessage = report.message
                do { try context.save() } catch {
                    context.rollback()
                    throw error
                }
                syncStatus = outcome
                onSyncFinished?(batch.isComplete && report.acceptedSamples > 0)
        } catch {
            syncStatus = .failed("Could not save sync metadata: \(error.localizedDescription)")
            onSyncFinished?(false)
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

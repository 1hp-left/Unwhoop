import XCTest
import SwiftData
import Combine
@testable import Unwhoop

private final class SyncTestBand: BandSyncProtocol {
    let connectionState = CurrentValueSubject<ConnectionState, Never>(.connected)
    let discoveredBands = CurrentValueSubject<[BandDevice], Never>([])
    let syncProgress = CurrentValueSubject<SyncProgress, Never>(.idle)
    var onBatch: ((RawSampleBatch) -> Void)?
    var requests = 0
    func startScan() {}
    func stopScan() {}
    func connect(to device: BandDevice) {}
    func disconnect() {}
    func requestSync() { requests += 1 }
}

final class SyncTests: XCTestCase {
    func testCommandAcknowledgementsCannotRestartHello() {
        var ready = BandSessionReadiness(requiredNotifications: ["history", "metadata"])
        XCTAssertTrue(ready.acceptHello())
        XCTAssertFalse(ready.acceptHello())
        XCTAssertFalse(ready.isReady)
        ready.notificationChanged("history", enabled: true)
        XCTAssertFalse(ready.takeReadyTransition())
        ready.notificationChanged("metadata", enabled: true)
        XCTAssertTrue(ready.takeReadyTransition())
        XCTAssertFalse(ready.takeReadyTransition())
        // The historical command write ack does not send hello/battery again.
        XCTAssertFalse(ready.acceptHello())
    }

    func testLostSubscriptionPreventsHistoryStart() {
        var ready = BandSessionReadiness(requiredNotifications: ["history"])
        XCTAssertTrue(ready.acceptHello())
        ready.notificationChanged("history", enabled: true)
        XCTAssertTrue(ready.isReady)
        ready.notificationChanged("history", enabled: false)
        XCTAssertFalse(ready.isReady)
    }

    private func batch(complete: Bool) -> RawSampleBatch {
        RawSampleBatch(heartRates: [(Date(timeIntervalSince1970: 1_790_000_000), 64)],
                       rrIntervals: [(Date(timeIntervalSince1970: 1_790_000_000), 0.95)],
                       motionFrames: [], skinTemperatures: [], batteryPercent: 72,
                       isComplete: complete)
    }

    func testRawArchivePreservesReceivedValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = try RawSyncStore(directory: directory).save(batch(complete: false))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let stored = try decoder.decode(StoredSyncBatch.self, from: Data(contentsOf: saved.url))
        XCTAssertEqual(stored.heartRates.first?.value, 64)
        XCTAssertEqual(stored.rrIntervals.first?.value, 0.95)
        XCTAssertEqual(saved.samples, 2)
        XCTAssertFalse(stored.complete)
    }

    func testJournalCommitsFramesBeforeAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SyncFrameJournal(directory: directory)
        try journal.append(Data([0xaa, 1, 2, 3]))
        try journal.checkpoint()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: file), Data([0xaa, 1, 2, 3]))
        journal.close()
    }

    @MainActor
    func testStorageFailureIsVisibleAndAllowsRetry() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let band = SyncTestBand()
        let state = AppState(sync: band, rawStore: RawSyncStore(directory: path))
        band.onBatch?(batch(complete: true))
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .failed = state.syncStatus else { return XCTFail("Storage failure was hidden") }
        XCTAssertFalse(state.syncStatus.isBusy)
        XCTAssertNil(state.latestRawExport)
    }

    @MainActor
    func testSyncUpdatesPersistenceAndPartialSyncDoesNotClaimCompletion() async throws {
        let schema = Schema([AppSettings.self, SyncState.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let band = SyncTestBand()
        let state = AppState(sync: band, rawStore: RawSyncStore(directory: directory))
        state.configurePersistence(ModelContext(container))
        // Drain the initial current-value publisher before invoking the UI action.
        await Task.yield()
        state.requestSync()
        state.requestSync()
        XCTAssertEqual(band.requests, 1)
        band.onBatch?(batch(complete: true))
        try await Task.sleep(nanoseconds: 100_000_000)
        let context = ModelContext(container)
        let link = try XCTUnwrap(context.fetch(FetchDescriptor<SyncState>()).first)
        let lastSuccess = try XCTUnwrap(link.lastSync)
        XCTAssertEqual(link.lastSampleCount, 2)
        XCTAssertEqual(link.batteryPercent, 72)
        XCTAssertEqual(state.syncStatus, .completed(samples: 2, complete: true))
        XCTAssertNotNil(state.latestRawExport)
        band.onBatch?(batch(complete: false))
        try await Task.sleep(nanoseconds: 100_000_000)
        let reloaded = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SyncState>()).first)
        XCTAssertEqual(reloaded.lastSync, lastSuccess)
        XCTAssertEqual(state.syncStatus, .completed(samples: 2, complete: false))
    }
}

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
    func testBudgetPauseWaitsForBankEndAndWriteAcknowledgement() {
        var boundary = HistoryTransferBoundary()
        boundary.bankStarted()
        XCTAssertFalse(boundary.requestPause(hasOpenBank: boundary.hasOpenBank), "A record limit cannot stop inside a bank")
        boundary.bankEnded()
        XCTAssertEqual(boundary.pendingAcknowledgements, 1)
        XCTAssertTrue(boundary.acknowledged(), "Pause only after the bank's ACK write is confirmed")
        XCTAssertFalse(boundary.completeReceived)
    }

    func testHistoryCompleteWaitsForAllOutstandingAcknowledgements() {
        var boundary = HistoryTransferBoundary()
        boundary.bankEnded(); boundary.bankEnded()
        XCTAssertFalse(boundary.completed())
        XCTAssertFalse(boundary.acknowledged())
        XCTAssertTrue(boundary.acknowledged())
        XCTAssertTrue(boundary.completeReceived)
    }

    func testLiveOnlyBudgetPauseDoesNotWaitForNonexistentBank() {
        var boundary = HistoryTransferBoundary()
        XCTAssertTrue(boundary.requestPause(hasOpenBank: false))
    }

    func testChargingContinuationDoesNotWaitThirtyMinutes() {
        XCTAssertEqual(AutomaticSyncPolicy.foregroundInterval(charging: true, lowPower: false, continuing: true), 60)
        XCTAssertEqual(AutomaticSyncPolicy.foregroundInterval(charging: true, lowPower: false, continuing: false), 300)
        XCTAssertEqual(AutomaticSyncPolicy.foregroundInterval(charging: false, lowPower: false, continuing: true), 300)
        XCTAssertEqual(AutomaticSyncPolicy.foregroundInterval(charging: true, lowPower: true, continuing: true), 14_400)
    }

    @MainActor
    func testRepeatedPartialTransfersUpdateSavedDataWithoutClaimingFullSync() async throws {
        let schema = Schema([AppSettings.self, SyncState.self, SensorMinute.self, NightSummary.self, DaySummary.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let band = SyncTestBand()
        let state = AppState(sync: band, rawStore: RawSyncStore(directory: directory))
        state.configurePersistence(ModelContext(container))
        let now = SensorPipeline.minute(Date()).addingTimeInterval(30)
        var diag = SyncDiagnostics(startedAt: now, historyCommandSent: true, historyStartMarkers: 1,
                                   historyCompleteSeen: false, historicalRecords: 300, realtimeRecords: 0,
                                   rrValuesReceived: 0, notificationStates: [:], lastNotificationAt: [:])
        diag.stopReason = .recordBudget; diag.recordBudget = 300
        let first = expectation(description: "first partial stored")
        state.onSyncFinished = { success in XCTAssertFalse(success); first.fulfill() }
        band.onBatch?(RawSampleBatch(heartRates: [(now.addingTimeInterval(-600), 65)], rrIntervals: [], motionFrames: [], skinTemperatures: [], batteryPercent: 80, isComplete: false, diagnostics: diag))
        await fulfillment(of: [first], timeout: 15)
        XCTAssertEqual(state.syncStatus, .paused(samples: 1, reason: SyncStopReason.recordBudget.explanation))
        XCTAssertTrue(state.hasBudgetContinuation)
        let second = expectation(description: "second partial stored")
        state.onSyncFinished = { _ in second.fulfill() }
        state.requestSync()
        XCTAssertEqual(band.requests, 1)
        band.onBatch?(RawSampleBatch(heartRates: [(now.addingTimeInterval(-120), 66), (now.addingTimeInterval(-119), 67)], rrIntervals: [], motionFrames: [], skinTemperatures: [], batteryPercent: 80, isComplete: false, diagnostics: diag))
        await fulfillment(of: [second], timeout: 15)
        let context = ModelContext(container)
        let link = try XCTUnwrap(context.fetch(FetchDescriptor<SyncState>()).first)
        XCTAssertEqual(link.lastSampleCount, 2)
        XCTAssertNotNil(link.lastReceivedAt)
        XCTAssertNil(link.lastSync)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SensorMinute>()), 2)
        XCTAssertTrue(link.transferMessage?.contains("record budget") == true)
        XCTAssertTrue(state.syncStatus.label?.contains("2 samples saved") == true)
        withExtendedLifetime(state) {}
    }

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
        RawSampleBatch(heartRates: [(Date().addingTimeInterval(-60), 64)],
                       rrIntervals: [(Date().addingTimeInterval(-60), 0.95)],
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
        let schema = Schema([AppSettings.self, SyncState.self, SensorMinute.self, NightSummary.self, DaySummary.self])
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
        let completed = expectation(description: "complete data persisted")
        state.onSyncFinished = { _ in completed.fulfill() }
        band.onBatch?(batch(complete: true))
        await fulfillment(of: [completed], timeout: 15)
        let context = ModelContext(container)
        let link = try XCTUnwrap(context.fetch(FetchDescriptor<SyncState>()).first)
        let lastSuccess = try XCTUnwrap(link.lastSync)
        XCTAssertEqual(link.lastSampleCount, 2)
        XCTAssertEqual(link.batteryPercent, 72)
        XCTAssertEqual(state.syncStatus, .completed(samples: 2, complete: true))
        XCTAssertNotNil(state.latestRawExport)
        let partial = expectation(description: "partial data persisted")
        state.onSyncFinished = { _ in partial.fulfill() }
        band.onBatch?(batch(complete: false))
        await fulfillment(of: [partial], timeout: 15)
        let reloaded = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SyncState>()).first)
        XCTAssertEqual(reloaded.lastSync, lastSuccess)
        XCTAssertEqual(state.syncStatus, .completed(samples: 2, complete: false))
    }
}

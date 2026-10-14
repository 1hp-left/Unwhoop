import XCTest
import SwiftData
import WhoopProtocol
import Combine
@testable import Unwhoop

private final class PipelineTestBand: BandSyncProtocol {
    let connectionState = CurrentValueSubject<ConnectionState, Never>(.connected)
    let discoveredBands = CurrentValueSubject<[BandDevice], Never>([])
    let syncProgress = CurrentValueSubject<SyncProgress, Never>(.idle)
    var onBatch: ((RawSampleBatch) -> Void)?
    func startScan() {}
    func stopScan() {}
    func connect(to device: BandDevice) {}
    func disconnect() {}
    func requestSync() {}
}

final class ScoringPipelineTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    private func container() throws -> ModelContainer {
        let schema = Schema([SensorMinute.self, NightSummary.self, DaySummary.self, AppSettings.self, SyncState.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    func testSparseAndStoppedRRNeverProduceHRV() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let sparse = (0..<94).map { StoredSyncBatch.Value(date: start.addingTimeInterval(Double($0) * 416 / 94), value: 0.82) }
        let quality = RRWindowQuality.evaluate(sparse, window: DateInterval(start: start, duration: 416))
        XCTAssertFalse(quality.isUsable)
        XCTAssertNil(quality.lnRMSSD)
        XCTAssertLessThan(quality.cleanCount, 120)
        let stopped = (0..<223).map { StoredSyncBatch.Value(date: start.addingTimeInterval(Double($0)), value: 0.82 + Double($0 % 2) * 0.01) }
        XCTAssertFalse(RRWindowQuality.evaluate(stopped, window: DateInterval(start: start, duration: 300)).isUsable)
    }

    func testTwentyPercentArtifactsAreRejectedBeforeHRV() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let values = (0..<300).map { StoredSyncBatch.Value(date: start.addingTimeInterval(Double($0)), value: $0 % 5 == 0 ? 2.4 : 0.82 + 0.01 * sin(Double($0))) }
        let quality = RRWindowQuality.evaluate(values, window: DateInterval(start: start, duration: 300))
        XCTAssertGreaterThan(quality.artifactFraction, 0.15)
        XCTAssertFalse(quality.isUsable)
        XCTAssertNil(quality.lnRMSSD)
    }

    func testCleanCoveredWindowProducesFiniteHRV() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let values = (0..<300).map { StoredSyncBatch.Value(date: start.addingTimeInterval(Double($0)), value: 0.85 + 0.04 * sin(Double($0) / 10)) }
        let quality = RRWindowQuality.evaluate(values, window: DateInterval(start: start, duration: 300))
        XCTAssertTrue(quality.isUsable, quality.reason ?? "")
        XCTAssertTrue(quality.lnRMSSD?.isFinite == true)
    }

    private func nightBatch(morning: Date, badRR: Bool = false) -> RawSampleBatch {
        let start = morning.addingTimeInterval(-2 * 3600)
        let seconds = 4 * 3600
        var hr: [(date: Date, bpm: Double)] = []
        var rr: [(date: Date, seconds: Double)] = []
        var motion: [MotionFrame] = []
        for i in 0..<seconds {
            let date = start.addingTimeInterval(Double(i))
            let awake = i < 1200 || i >= seconds - 1200
            hr.append((date, awake ? 95 : 60 + 0.5 * sin(Double(i) / 50)))
            rr.append((date, badRR && i % 5 == 0 ? 2.4 : 0.85 + 0.03 * sin(Double(i) / 15)))
            motion.append(MotionFrame(date: date, x: awake && i % 2 == 0 ? 0.8 : 0, y: 0, z: 1, activityClass: nil, stepCount: nil))
        }
        return RawSampleBatch(heartRates: hr, rrIntervals: rr, motionFrames: motion, skinTemperatures: [], batteryPercent: 80, isComplete: true)
    }

    @MainActor
    func testNightIngestCalculatesSleepAndStrainAndIsIdempotent() throws {
        let store = try container()
        let context = ModelContext(store)
        let settings = AppSettings(); settings.maximumHeartRate = 190; settings.trainingSexRaw = BiologicalSex.male.rawValue
        context.insert(settings); try context.save()
        let morning = calendar.startOfDay(for: Date())
        let batch = nightBatch(morning: morning)
        let pipeline = SensorPipeline(container: store, calendar: calendar)
        _ = try pipeline.ingest(batch, now: morning.addingTimeInterval(2 * 3600))
        let fresh = ModelContext(store)
        let night = try XCTUnwrap(fresh.fetch(FetchDescriptor<NightSummary>()).first)
        XCTAssertFalse(night.lowConfidence, night.confidenceReason ?? "")
        XCTAssertTrue(night.hrvAvailable)
        XCTAssertNotNil(night.sleepScore)
        XCTAssertNil(night.recoveryScore, "First night cannot have seven prior baselines")
        XCTAssertGreaterThan(night.totalSleepMinutes, 90)
        let days = try fresh.fetch(FetchDescriptor<DaySummary>())
        XCTAssertTrue(days.contains { $0.strainAvailable && $0.strain >= 0 && $0.strain <= 21 })
        let count = try fresh.fetchCount(FetchDescriptor<SensorMinute>())
        _ = try pipeline.ingest(batch, now: morning.addingTimeInterval(2 * 3600))
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<SensorMinute>()), count)
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<NightSummary>()), 1)
    }

    @MainActor
    func testFlaggedNightHasNoSleepOrRecoveryScore() throws {
        let store = try container()
        let morning = calendar.startOfDay(for: Date())
        _ = try SensorPipeline(container: store, calendar: calendar).ingest(nightBatch(morning: morning, badRR: true), now: morning.addingTimeInterval(2 * 3600))
        let night = try XCTUnwrap(ModelContext(store).fetch(FetchDescriptor<NightSummary>()).first)
        XCTAssertTrue(night.lowConfidence)
        XCTAssertFalse(night.hrvAvailable)
        XCTAssertNil(night.sleepScore)
        XCTAssertNil(night.recoveryScore)
        XCTAssertNil(night.respiratoryRate)
    }

    @MainActor
    func testRecoveryUsesSevenPriorUsableNights() throws {
        let store = try container()
        let context = ModelContext(store)
        let morning = calendar.startOfDay(for: Date())
        for i in 1...7 {
            context.insert(NightSummary(nightDate: morning.addingTimeInterval(Double(-i) * 86_400), lnRMSSD: log(35 + Double(i)), restingHR: 60 + Double(i % 2), totalSleepMinutes: 450, sleepNeedMinutes: 480))
        }
        try context.save()
        _ = try SensorPipeline(container: store, calendar: calendar).ingest(nightBatch(morning: morning), now: morning.addingTimeInterval(2 * 3600))
        let night = try XCTUnwrap(ModelContext(store).fetch(FetchDescriptor<NightSummary>()).first { $0.nightDate == morning })
        XCTAssertNotNil(night.recoveryScore)
        XCTAssertTrue((0...100).contains(night.recoveryScore ?? -1))
    }

    func testRepeatedRRTimestampsRetainAllIntervalsWithoutDuplicates() {
        let date = Date()
        var original = MinuteSignals()
        original.rr = [.init(date: date, value: 0.8), .init(date: date, value: 0.8), .init(date: date, value: 0.9)]
        let duplicate = original
        original.merge(duplicate)
        XCTAssertEqual(original.rr.count, 3)
        var partial = MinuteSignals(); partial.rr = [.init(date: date, value: 0.8)]
        original.merge(partial)
        XCTAssertEqual(original.rr.count, 3)
    }

    @MainActor
    func testEmptyTransferDoesNotAdvanceLastSync() async throws {
        let store = try container()
        let context = ModelContext(store)
        let previous = Date().addingTimeInterval(-3600)
        let link = SyncState(lastSync: previous); context.insert(link); try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let band = PipelineTestBand()
        let state = AppState(sync: band, rawStore: RawSyncStore(directory: directory))
        state.configurePersistence(context)
        let done = expectation(description: "empty transfer processed")
        state.onSyncFinished = { success in XCTAssertFalse(success); done.fulfill() }
        band.onBatch?(RawSampleBatch(heartRates: [], rrIntervals: [], motionFrames: [], skinTemperatures: [], batteryPercent: 80, isComplete: true))
        await fulfillment(of: [done], timeout: 15)
        XCTAssertEqual(state.syncStatus, .waitingForData)
        XCTAssertEqual(try ModelContext(store).fetch(FetchDescriptor<SyncState>()).first?.lastSync, previous)
    }

    func testAutomaticBatteryPolicyLimitsOffloadAndBacksOff() {
        XCTAssertEqual(AutomaticSyncPolicy.recordBudget(charging: false, lowPower: false), 300)
        XCTAssertEqual(AutomaticSyncPolicy.recordBudget(charging: true, lowPower: false), Int.max)
        XCTAssertEqual(AutomaticSyncPolicy.recordBudget(charging: true, lowPower: true), 300)
        XCTAssertGreaterThanOrEqual(AutomaticSyncPolicy.retryInterval(charging: true, lowPower: false), 1800)
        XCTAssertGreaterThanOrEqual(AutomaticSyncPolicy.retryInterval(charging: false, lowPower: true), 14_400)
    }

    func testHistoryCommandUsesVendoredProtocolAndCorrectOpcode() {
        let frame = puffinCommandFrame(cmd: 22, seq: 1, payload: [0x00])
        let parsed = parseFrame(frame, family: .whoop5)
        XCTAssertTrue(parsed.ok)
        XCTAssertTrue(parsed.cmdName?.contains("SEND_HISTORICAL_DATA") == true)
    }

    func testInterleavedNotificationChannelsDoNotLoseFrames() {
        let history = puffinCommandFrame(cmd: 22, seq: 1, payload: [0x00])
        let battery = puffinCommandFrame(cmd: 26, seq: 2, payload: [0x00])
        let decoder = BandFrameDecoder()
        let halfA = history.count / 2, halfB = battery.count / 2
        XCTAssertTrue(decoder.feed(Array(history.prefix(halfA)), channel: "history").isEmpty)
        XCTAssertTrue(decoder.feed(Array(battery.prefix(halfB)), channel: "battery").isEmpty)
        XCTAssertEqual(decoder.feed(Array(history.dropFirst(halfA)), channel: "history"), [history])
        XCTAssertEqual(decoder.feed(Array(battery.dropFirst(halfB)), channel: "battery"), [battery])
    }

    @MainActor
    func testOlderHistoryIsDistinctFromLiveWindowData() throws {
        let store = try container()
        let now = Date()
        let diag = SyncDiagnostics(startedAt: now, historyCommandSent: true, historyStartMarkers: 1,
                                   historyCompleteSeen: true, historicalRecords: 1, realtimeRecords: 0,
                                   lastRRNotificationAt: nil, lastRRSampleAt: nil, rrValuesReceived: 0,
                                   notificationStates: [:], lastNotificationAt: [:])
        let pipeline = SensorPipeline(container: store)
        let old = RawSampleBatch(heartRates: [(now.addingTimeInterval(-7200), 65)], rrIntervals: [], motionFrames: [], skinTemperatures: [], batteryPercent: nil, isComplete: true, diagnostics: diag)
        XCTAssertTrue(try pipeline.ingest(old, now: now).history.contains("Older history received"))
        let live = RawSampleBatch(heartRates: [(now, 65)], rrIntervals: [], motionFrames: [], skinTemperatures: [], batteryPercent: nil, isComplete: true, diagnostics: diag)
        XCTAssertTrue(try pipeline.ingest(live, now: now).history.contains("Live-window"))
    }
}

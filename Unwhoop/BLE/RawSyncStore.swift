import Foundation
import WhoopProtocol

/// One file per transfer; keeps the received values independent of scoring.
struct StoredSyncBatch: Codable {
    struct Value: Codable {
        let date: Date
        let value: Double
    }
    let receivedAt: Date
    let complete: Bool
    let heartRates: [Value]
    let rrIntervals: [Value]
    let motionFrames: [MotionFrame]
    let skinTemperatures: [Value]
    var diagnostics: SyncDiagnostics? = nil

    var batch: RawSampleBatch {
        RawSampleBatch(heartRates: heartRates.map { ($0.date, $0.value) },
                       rrIntervals: rrIntervals.map { ($0.date, $0.value) },
                       motionFrames: motionFrames,
                       skinTemperatures: skinTemperatures.map { ($0.date, $0.value) },
                       batteryPercent: nil, isComplete: complete, diagnostics: diagnostics)
    }

    var sampleCount: Int {
        heartRates.count + rrIntervals.count + motionFrames.count + skinTemperatures.count
    }
}

struct RawSyncStore {
    let directory: URL

    init(directory: URL = RawSyncStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawSync", isDirectory: true)
    }

    func save(_ batch: RawSampleBatch, receivedAt: Date = .now) throws -> (url: URL, samples: Int) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = StoredSyncBatch(
            receivedAt: receivedAt, complete: batch.isComplete,
            heartRates: batch.heartRates.map { .init(date: $0.date, value: $0.bpm) },
            rrIntervals: batch.rrIntervals.map { .init(date: $0.date, value: $0.seconds) },
            motionFrames: batch.motionFrames,
            skinTemperatures: batch.skinTemperatures.map { .init(date: $0.date, value: $0.celsius) },
            diagnostics: batch.diagnostics)
        let url = directory.appendingPathComponent("sync-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(stored).write(to: url, options: .atomic)
        // Retention is based on when we received the transfer, so a first
        // sync of old band history remains available for export for 14 days.
        let cutoff = receivedAt.addingTimeInterval(-14 * 86_400)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        for file in files where file.pathExtension == "json" || file.pathExtension == "frames" {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return (url, stored.sampleCount)
    }

    func recoverJournal(_ url: URL) throws -> RawSampleBatch {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let reassembler = Reassembler(family: .whoop5)
        var frames: [ParsedFrame] = []
        while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
            for raw in reassembler.feed(Array(bytes)) {
                let parsed = parseFrame(raw, family: .whoop5)
                if parsed.ok { frames.append(parsed) }
            }
        }
        let now = Int(Date().timeIntervalSince1970)
        let streams = extractHistoricalStreams(frames, deviceClockRef: now, wallClockRef: now, family: .whoop5)
        let steps = Dictionary(streams.steps.map { ($0.ts, $0) }, uniquingKeysWith: { _, newest in newest })
        return RawSampleBatch(
            heartRates: streams.hr.map { (Date(timeIntervalSince1970: Double($0.ts)), Double($0.bpm)) },
            rrIntervals: streams.rr.map { (Date(timeIntervalSince1970: Double($0.ts)), Double($0.rrMs) / 1000) },
            motionFrames: streams.gravity.map { value in
                MotionFrame(date: Date(timeIntervalSince1970: Double(value.ts)), x: value.x, y: value.y, z: value.z,
                            activityClass: steps[value.ts]?.activityClass.map { UInt8(clamping: $0) },
                            stepCount: steps[value.ts].map { UInt32(clamping: $0.counter) })
            },
            skinTemperatures: streams.skinTemp.map { (Date(timeIntervalSince1970: Double($0.ts)), skinTempCelsius(raw: $0.raw, family: .whoop5)) },
            batteryPercent: nil, isComplete: false)
    }
}

/// Journals CRC-checked protocol frames before acknowledging each bank.
/// Even an interrupted process leaves already-acknowledged history on disk.
final class SyncFrameJournal {
    private var handle: FileHandle?
    let url: URL

    init(directory: URL = RawSyncStore.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("history-\(UUID().uuidString).frames")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ frame: Data) throws { try handle?.write(contentsOf: frame) }
    func checkpoint() throws { try handle?.synchronize() }
    func close() {
        try? handle?.close()
        handle = nil
    }
    deinit { close() }
}

import Foundation

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
            skinTemperatures: batch.skinTemperatures.map { .init(date: $0.date, value: $0.celsius) })
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
}

/// Journals CRC-checked protocol frames before acknowledging each bank.
/// Even an interrupted process leaves already-acknowledged history on disk.
final class SyncFrameJournal {
    private var handle: FileHandle?

    init(directory: URL = RawSyncStore.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history-\(UUID().uuidString).frames")
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

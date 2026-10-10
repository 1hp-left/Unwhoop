import Foundation

// MARK: - RawExporter
//
// Raw tier (opt-in): R-R intervals, motion samples, raw streams for a CHOSEN
// date range — can reach gigabytes (PRD §5.7).
//
// Memory discipline (non-negotiable, PRD §7 "stream, don't load"):
// - A date-range picker is REQUIRED — no unbounded raw export.
// - Data streams to disk in fixed-size chunks (default 10k samples); the full
//   range is NEVER held in memory.
// - The caller supplies a RawChunkProvider (backed by paged DB reads once the
//   raw store lands in milestone 1). Chunked import/export, paged reads.

/// Supplies one page of raw samples. Implementations MUST page from disk/DB —
/// never load the whole range.
protocol RawChunkProvider {
    /// R-R intervals in `range`, page `offset ..< offset+limit`, chronological.
    /// Returns fewer than `limit` at the end of data.
    func rrIntervals(in range: ClosedRange<Date>, offset: Int, limit: Int) -> [(date: Date, seconds: Double)]
    /// Motion frames in `range`, page `offset ..< offset+limit`, chronological.
    func motionFrames(in range: ClosedRange<Date>, offset: Int, limit: Int) -> [MotionFrame]
}

enum RawExporter {
    /// Streams raw samples for `range` to `url` as CSV, chunk by chunk.
    /// - Throws: file errors, or provider errors.
    static func export(
        range: ClosedRange<Date>,
        to url: URL,
        provider: RawChunkProvider,
        chunkSize: Int = 10_000
    ) throws {
        // Truncate/create first so a failed export never appends to stale data.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("type,timestamp_iso8601,value\n".utf8))

        // R-R stream.
        var offset = 0
        while true {
            let chunk = provider.rrIntervals(in: range, offset: offset, limit: chunkSize)
            if chunk.isEmpty { break }
            try handle.write(contentsOf: Data(chunk.map {
                "rr,\($0.date.ISO8601Format()),\(String(format: "%.4f", $0.seconds))\n"
            }.joined().utf8))
            offset += chunk.count
            if chunk.count < chunkSize { break }
        }

        // Motion stream.
        offset = 0
        while true {
            let chunk = provider.motionFrames(in: range, offset: offset, limit: chunkSize)
            if chunk.isEmpty { break }
            try handle.write(contentsOf: Data(chunk.map {
                let m = $0
                return "motion,\(m.date.ISO8601Format()),\(String(format: "%.4f,%.4f,%.4f", m.x, m.y, m.z))\n"
            }.joined().utf8))
            offset += chunk.count
            if chunk.count < chunkSize { break }
        }
    }
}

// MARK: - StorageMeter
//
// Live storage meter for the Data tab: "182 MB — raw keeps 14 days" (PRD §5.7).
// Budget: under 500 MB after 12 months; raw auto-prunes after 14 days.

enum StorageMeter {
    /// Total bytes under the app's Application Support directory.
    static func appSupportBytes() -> Int {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return 0
        }
        var total = 0
        if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    /// One-line meter text for the Data tab.
    static func meterLine(rawRetentionDays: Int = 14) -> String {
        let bytes = appSupportBytes()
        let str = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(str) — raw keeps \(rawRetentionDays) days"
    }
}

import Foundation
import SwiftData

@Model
final class SensorMinute {
    @Attribute(.unique) var date: Date
    var payload: Data
    init(date: Date, payload: Data) { self.date = date; self.payload = payload }
}

/// Minute pages preserve raw timestamps and bound the size of database reads.
struct MinuteSignals: Codable {
    var hr: [StoredSyncBatch.Value] = []
    var rr: [StoredSyncBatch.Value] = []
    var motion: [MotionFrame] = []
    var temperature: [StoredSyncBatch.Value] = []

    mutating func merge(_ incoming: MinuteSignals) {
        hr = Self.mergeValues(hr, incoming.hr)
        temperature = Self.mergeValues(temperature, incoming.temperature)
        let dates = Set(incoming.motion.map(\.date))
        motion = (motion.filter { !dates.contains($0.date) } + incoming.motion).sorted { $0.date < $1.date }
        // Multiple ordered intervals share a packet timestamp. Keep the
        // fullest group, including equal values; repeat downloads are idempotent.
        var groups = Dictionary(grouping: rr, by: \.date)
        for (date, values) in Dictionary(grouping: incoming.rr, by: \.date) {
            if values.count >= (groups[date]?.count ?? 0) { groups[date] = values }
        }
        rr = groups.keys.sorted().flatMap { groups[$0] ?? [] }
    }

    private static func mergeValues(_ old: [StoredSyncBatch.Value], _ new: [StoredSyncBatch.Value]) -> [StoredSyncBatch.Value] {
        var values = Dictionary(old.map { ($0.date, $0) }, uniquingKeysWith: { _, next in next })
        for value in new { values[value.date] = value }
        return values.values.sorted { $0.date < $1.date }
    }
}

import Foundation
import SwiftData

#if DEBUG
/// Manual entry of WHOOP's official scores for one date — the benchmark-mode
/// fallback path (PRD §5.6). Three numbers, ten seconds.
/// Compiler-gated: this model, its UI, and BenchmarkStats do not exist in
/// production builds. Retired from prod, not merely hidden.
@Model
final class BenchmarkEntry {
    @Attribute(.unique) var id: UUID

    /// Local calendar day the official scores belong to.
    var entryDate: Date

    var officialRecovery: Double?   // WHOOP Recovery %
    var officialStrain: Double?     // WHOOP Day Strain (0–21)
    var officialSleepMinutes: Double? // WHOOP total sleep, minutes

    // Sleep-score tuning inputs (per night, from the export's own fields).
    // The tuner computes OUR four components from these and fits weights
    // against officialSleepScore — all on-device.
    var officialSleepScore: Double? // WHOOP Sleep Performance 0–100
    var sleepOnset: Date?           // sleep onset (for consistency)
    var wakeTime: Date?             // wake time (for consistency + time in bed)
    var timeInBedMinutes: Double?   // for efficiency
    var rhrBpm: Double?             // for restfulness
    var hrvMs: Double?              // for restfulness (RMSSD, ms)

    init(entryDate: Date, officialRecovery: Double? = nil, officialStrain: Double? = nil, officialSleepMinutes: Double? = nil) {
        self.id = UUID()
        self.entryDate = entryDate
        self.officialRecovery = officialRecovery
        self.officialStrain = officialStrain
        self.officialSleepMinutes = officialSleepMinutes
    }
}
#endif

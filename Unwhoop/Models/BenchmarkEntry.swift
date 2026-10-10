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

    init(entryDate: Date, officialRecovery: Double? = nil, officialStrain: Double? = nil, officialSleepMinutes: Double? = nil) {
        self.id = UUID()
        self.entryDate = entryDate
        self.officialRecovery = officialRecovery
        self.officialStrain = officialStrain
        self.officialSleepMinutes = officialSleepMinutes
    }
}
#endif

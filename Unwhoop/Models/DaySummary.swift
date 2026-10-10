import Foundation
import SwiftData

/// One day of computed strain. Written once per day by the analytics pipeline
/// (exactly once per new data batch, then cached). Kept forever.
@Model
final class DaySummary {
    @Attribute(.unique) var id: UUID

    /// Local calendar day.
    var dayDate: Date

    /// Strain on the 0–21 scale (Borg-anchored saturating exponential, PRD §5.5).
    var strain: Double
    /// Accumulated Banister TRIMP load before the 0–21 mapping.
    var trimpLoad: Double
    /// Per-minute TRIMP aggregates (up to 1440 entries). This is the
    /// "per-minute TRIMP aggregates ref" from the scaffold spec — stored inline
    /// (~11 KB/day, ~4 MB/year, inside the storage budget).
    var minuteTRIMP: [Double]
    /// True while the day is still accumulating (drives the LIVE dot).
    var isLive: Bool

    init(
        dayDate: Date,
        strain: Double = 0,
        trimpLoad: Double = 0,
        minuteTRIMP: [Double] = [],
        isLive: Bool = true
    ) {
        self.id = UUID()
        self.dayDate = dayDate
        self.strain = strain
        self.trimpLoad = trimpLoad
        self.minuteTRIMP = minuteTRIMP
        self.isLive = isLive
    }
}

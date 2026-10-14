import Foundation

// MARK: - Baselines (DOCUMENTED STUB)
//
// Contract (PRD §5.3). Rolling 7-day baselines per metric; nightly values are
// expressed as z-scores against the user's own baseline. The real rolling
// construction is written separately; the z-score definition and the
// completeness rule come straight from the PRD and are implemented here.

/// Rolling statistics for one metric.
struct MetricBaseline: Sendable {
    var mean: Double
    var sd: Double
    /// Nights contributing to this window.
    var n: Int

    /// z = (value − mean) / sd. Guarded: sd == 0 → 0.
    func zScore(for value: Double) -> Double {
        guard sd > 0 else { return 0 }
        return (value - mean) / sd
    }

    /// Smallest-worthwhile-change band = mean ± 0.5 SD (PRD §5.3).
    var worthwhileBand: ClosedRange<Double> {
        (mean - 0.5 * sd)...(mean + 0.5 * sd)
    }
}

/// The user's rolling baselines.
struct Baselines: Sendable {
    var hrv: MetricBaseline            // LnRMSSD
    var restingHR: MetricBaseline       // bpm
    var sleepPerformance: MetricBaseline // 0–1 vs need

    /// Nights currently in the rolling window.
    var nightsUsed: Int

    /// No score until the baseline exists (PRD §5.3: first 7 days show
    /// "Building baseline — N nights to go").
    var isComplete: Bool { nightsUsed >= 7 }

    /// Builds rolling baselines from recent nights (newest last, up to 7 used).
    /// Low-confidence and confounder-flagged nights are EXCLUDED — flags move
    /// the display, never the baseline (PRD §5.3). Matches the Python
    /// reference (population SD, 7-day window).
    static func build(from nights: [NightSummary]) -> Baselines {
        let usable = nights
            .sorted { $0.nightDate < $1.nightDate }
            .filter { !$0.lowConfidence && $0.hrvAvailable && $0.restingHRAvailable && $0.confounderFlags.isEmpty }
            .suffix(7)
        func stats(_ vals: [Double]) -> MetricBaseline {
            guard !vals.isEmpty else {
                return MetricBaseline(mean: 0, sd: 0, n: 0)
            }
            let mean = vals.reduce(0, +) / Double(vals.count)
            let variance = vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                         / Double(vals.count)
            return MetricBaseline(mean: mean, sd: variance.squareRoot(),
                                  n: vals.count)
        }
        return Baselines(
            hrv: stats(usable.map(\.lnRMSSD)),
            restingHR: stats(usable.map(\.restingHR)),
            sleepPerformance: stats(usable.map {
                $0.sleepNeedMinutes > 0
                    ? $0.totalSleepMinutes / $0.sleepNeedMinutes : 1.0
            }),
            nightsUsed: usable.count)
    }
}

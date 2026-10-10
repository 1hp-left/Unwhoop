import Foundation

// MARK: - StrainEngine
//
// Real implementation (ported 1:1 from the tested Python reference
// analytics-py/unwhoop/strain.py — 27/27 tests green).
//
// Contract (PRD §5.5):
// - Per-minute Banister TRIMP from heart-rate reserve:
//   ΔHR-ratio = (HR − HRrest) / (HRmax − HRrest),
//   weighted by Y = 0.64·e^(1.92·x) (male) / 0.86·e^(1.67·x) (female).
// - Accumulated load maps through a saturating exponential onto 0–21
//   (Borg-anchored, "exponentially harder at the top"). Starting point:
//   21·(1−e^(−load/100)); the constant is fitted against paired WHOOP strain
//   data in benchmark mode.
// - Do NOT use Edwards zone-summation (fails to discriminate intensities).
// - Strain comes from the HR trace, period — no workout auto-detection.
// - Deterministic: same input, byte-identical output. No randomness.

/// One day of heart-rate input for strain computation.
struct StrainDayInput: Sendable {
    var date: Date // local calendar day
    /// One entry per minute of the day (nil = no data that minute); index 0 = 00:00.
    var minuteHeartRates: [Double?]
    var restingHR: Double // bpm, from the user's baseline
    var maxHR: Double     // bpm
    var sex: BiologicalSex
}

/// Strain result for a day.
struct DayStrain: Sendable {
    /// 0–21 scale.
    var value: Double
    /// Raw accumulated Banister TRIMP load before the 0–21 mapping.
    var trimpLoad: Double
    /// True while the day is still accumulating (drives the LIVE dot).
    var isLive: Bool
}

enum StrainEngine {
    static let strainMax = 21.0
    /// v1 constant — fit against paired WHOOP strain data in benchmark mode.
    static let loadConstant = 100.0

    private static func weight(x: Double, sex: BiologicalSex) -> Double {
        sex == .female ? 0.86 * exp(1.67 * x) : 0.64 * exp(1.92 * x)
    }

    /// Banister TRIMP for one minute at the given heart rate.
    static func trimpMinute(hr: Double, hrRest: Double, hrMax: Double,
                            sex: BiologicalSex) -> Double {
        guard hrMax > hrRest else { return 0 }
        let x = (hr - hrRest) / (hrMax - hrRest)
        guard x > 0 else { return 0 }
        return x * weight(x: x, sex: sex)
    }

    /// Saturating exponential map onto the 0–21 scale (Borg-anchored).
    static func loadToStrain(_ load: Double) -> Double {
        strainMax * (1 - exp(-load / loadConstant))
    }

    /// Computes strain for one day from its per-minute heart-rate trace.
    /// Minutes with no data contribute nothing (never invented).
    /// - Parameter day: The day's input (see `StrainDayInput`).
    /// - Returns: Strain 0–21 with the underlying TRIMP load.
    static func strain(for day: StrainDayInput) -> DayStrain {
        let load = day.minuteHeartRates.reduce(0.0) { acc, hr in
            guard let hr else { return acc }
            return acc + trimpMinute(hr: hr, hrRest: day.restingHR,
                                     hrMax: day.maxHR, sex: day.sex)
        }
        return DayStrain(value: loadToStrain(load), trimpLoad: load,
                         isLive: Calendar.current.isDateInToday(day.date))
    }
}

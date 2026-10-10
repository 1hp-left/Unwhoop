import Foundation

// MARK: - SleepScore
//
// A single 0–100 nightly sleep score, computed on-device from four components
// mirroring what WHOOP's own docs say Sleep Performance is built from:
// sufficiency (sleep vs need), efficiency (asleep / in bed), consistency
// (timing vs recent norm), and restfulness (overnight vitals vs baseline,
// i.e. low physiological stress during sleep).
//
//   score = 100 * Σ wᵢ·cᵢ,   weights ≥ 0, Σw = 1
//
// Weights ship with sensible priors; the dev-only tuner (SleepScoreTuner,
// #if DEBUG) fits them against the user's imported WHOOP export on-device.
// The tuner never ships in production and no data leaves the phone.

/// Four 0–1 components; higher is always better.
struct SleepComponents: Sendable {
    var sufficiency: Double
    var efficiency: Double
    var consistency: Double
    var restfulness: Double
}

struct SleepWeights: Sendable, Codable {
    var sufficiency: Double
    var efficiency: Double
    var consistency: Double
    var restfulness: Double

    /// Priors: sufficiency dominates (it's the headline number everywhere),
    /// efficiency next, consistency and restfulness share the remainder.
    static let `default` = SleepWeights(
        sufficiency: 0.35, efficiency: 0.25, consistency: 0.20, restfulness: 0.20)

    /// Project onto the simplex (non-negative, sum 1).
    var normalized: SleepWeights {
        let vals = [sufficiency, efficiency, consistency, restfulness]
            .map { max(0, $0) }
        let sum = vals.reduce(0, +)
        guard sum > 0 else { return .default }
        return SleepWeights(sufficiency: vals[0] / sum, efficiency: vals[1] / sum,
                            consistency: vals[2] / sum, restfulness: vals[3] / sum)
    }

    var array: [Double] { [sufficiency, efficiency, consistency, restfulness] }

    static func from(array: [Double]) -> SleepWeights {
        guard array.count == 4 else { return .default }
        return SleepWeights(sufficiency: array[0], efficiency: array[1],
                            consistency: array[2], restfulness: array[3]).normalized
    }
}

func sleepScore(_ c: SleepComponents, weights: SleepWeights = .default) -> Double {
    let w = weights.normalized
    let raw = w.sufficiency * c.sufficiency
        + w.efficiency * c.efficiency
        + w.consistency * c.consistency
        + w.restfulness * c.restfulness
    return min(max(raw, 0), 1) * 100
}

// MARK: Components (pure, testable)

/// Sufficiency: total sleep vs need, capped at 1. Oversleeping past need
/// doesn't earn extra credit.
func sleepSufficiency(totalSleepMin: Double, needMin: Double) -> Double {
    guard needMin > 0, totalSleepMin > 0 else { return 0 }
    return min(totalSleepMin / needMin, 1)
}

/// Efficiency: fraction of time in bed actually asleep.
func sleepEfficiency(totalSleepMin: Double, timeInBedMin: Double) -> Double {
    guard timeInBedMin > 0, totalSleepMin >= 0 else { return 0 }
    return min(totalSleepMin / timeInBedMin, 1)
}

/// Consistency: 1 when tonight's sleep midpoint matches the recent median;
/// decays linearly to 0 at 3+ hours of deviation.
func sleepConsistency(midpoint: Date, medianMidpoint: Date) -> Double {
    let devHours = abs(midpoint.timeIntervalSince(medianMidpoint)) / 3600
    return max(0, 1 - devHours / 3)
}

/// Restfulness: overnight vitals vs personal baselines. Elevated RHR or
/// depressed HRV reads as physiological stress during sleep.
func sleepRestfulness(rhrBpm: Double, rhrBaselineBpm: Double,
                      hrvMs: Double, hrvBaselineMs: Double) -> Double {
    let rhrPart: Double
    if rhrBaselineBpm > 0 {
        rhrPart = min(max(1 - max(0, rhrBpm - rhrBaselineBpm) / 12, 0), 1)
    } else {
        rhrPart = 0.5
    }
    let hrvPart: Double
    if hrvBaselineMs > 0, hrvMs > 0 {
        hrvPart = min(hrvMs / hrvBaselineMs, 1.2) / 1.2
    } else {
        hrvPart = 0.5
    }
    return 0.5 * rhrPart + 0.5 * hrvPart
}

// MARK: Sleep need (our own estimate)

/// Personal sleep need for tonight: baseline (median of recent nights,
/// clamped to a sane 6–10 h window) + a strain bump + partial repayment of
/// recent sleep debt.
func sleepNeedMinutes(baselineMedianMin: Double, dayStrain: Double,
                      sleepDebtMin: Double) -> Double {
    let base = min(max(baselineMedianMin, 360), 600)
    let strainBump = max(0, dayStrain - 12) * 3
    let debtBump = min(max(sleepDebtMin, 0), 120) * 0.25
    return base + strainBump + debtBump
}

/// Sleep debt: trailing 7-night sum of (need − actual) shortfalls, floored at 0.
func sleepDebtMinutes(_ nights: [(needMin: Double, actualMin: Double)]) -> Double {
    max(0, nights.suffix(7).reduce(0) { $0 + max(0, $1.needMin - $1.actualMin) })
}

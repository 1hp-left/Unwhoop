import Foundation

// MARK: - SleepStager
//
// Real implementation (ported 1:1 from the tested Python reference
// analytics-py/unwhoop/sleep.py — 27/27 tests green).
//
// Contract (PRD §5.4): 30-second epochs, Wake/Light/Deep/REM, from the
// Walch et al. (2019) feature set — wrist accelerometry, PPG-derived HR and
// HRV (RMSSD), PPG-derived respiratory rate — plus a circadian time-of-night
// prior. Temporal structure via Viterbi smoothing over epoch posteriors (the
// HMM half of the "temporal model" family named in Ch. 4).
//
// Expected limits, disclosed in the UI per PRD: 4-class kappa ~0.5–0.65 vs
// PSG; light sleep reads high, deep sleep and wake time read low (every wrist
// device, WHOOP included). This v1 is a TRANSPARENT heuristic classifier on
// the literature's feature set — no trained weights, fully auditable.
// Upgrade path: fit the linear weights (and transition matrix) on benchmark
// paired nights.
// Deterministic: same input, byte-identical output. No randomness.

/// Features for one 30-second epoch, in chronological order.
struct EpochFeatures: Sendable {
    var index: Int
    /// Vector magnitude of motion for the epoch (g).
    var motionMagnitude: Double
    var heartRate: Double?       // bpm; nil if the optical signal was unusable
    var hrv: Double?             // ms RMSSD for the epoch, if computable
    var respiratoryRate: Double? // breaths/min, if estimable
    /// Hours since sleep onset; feeds the time-of-night prior.
    var timeOfNightHours: Double
}

/// One staged epoch.
struct SleepEpoch: Sendable {
    var index: Int
    var stage: SleepStage
}

/// Sleep summary derived from a staged night (for the pipeline).
struct StagedNightSummary: Sendable {
    var totalSleepMinutes: Double
    var efficiency: Double // 0–1
    var minutesByStage: [SleepStage: Double]
    var onsetIndex: Int?
    var wakeIndex: Int?
}

enum SleepStager {
    // rows = from-stage [wake, light, deep, rem], cols = to-stage.
    // Sleep architecture is sticky; wake→deep and deep→REM jumps are rare.
    private static let transition: [[Double]] = [
        [0.80, 0.15, 0.01, 0.04],
        [0.06, 0.86, 0.05, 0.03],
        [0.02, 0.06, 0.90, 0.02],
        [0.05, 0.08, 0.02, 0.85],
    ]
    private static let order: [SleepStage] = [.wake, .light, .deep, .rem]

    private static func clip(_ x: Double, _ lo: Double = -1,
                             _ hi: Double = 1) -> Double {
        min(hi, max(lo, x))
    }

    /// Activity index 0–1 from raw vector magnitude (g). The magnitude
    /// includes gravity (~1g at rest), so activity is deviation above 1g.
    /// The pipeline may substitute the 5.0's activity-class frames when
    /// available (PRD §5.4); this keeps the stager honest either way.
    static func activityIndex(fromG g: Double) -> Double {
        clip(g - 1.0, 0, 1)
    }

    private static func scores(motion: Double, hr: Double, medianHR: Double,
                               rmssd: Double, medianRMSSD: Double,
                               hrVar: Double, tHours: Double) -> [Double] {
        let hrElev = clip((hr - medianHR) / 12)
        let hrvHigh = clip((rmssd - medianRMSSD) / 15)
        let hrvVar = clip(hrVar / 6, 0, 1)
        let early = clip(1 - tHours / 4, 0, 1)   // deep-sleep pressure
        let late = clip(tHours / 4, 0, 1)        // REM pressure
        let sWake = 4.0 * motion + 1.5 * hrElev - 1.2
        let sLight = 0.25 - 1.0 * motion
        let sDeep = -3.0 * motion - 1.2 * hrElev + 1.0 * hrvHigh
                  + 1.4 * early - 0.6
        let sREM = -2.0 * motion + 1.2 * hrvVar + 1.4 * late
                 - 0.5 * hrvHigh - 0.4
        return [sWake, sLight, sDeep, sREM]
    }

    private static func softmax(_ xs: [Double]) -> [Double] {
        let m = xs.max() ?? 0
        let ex = xs.map { exp($0 - m) }
        let s = ex.reduce(0, +)
        return ex.map { $0 / s }
    }

    private static func viterbi(_ emissions: [[Double]]) -> [Int] {
        let n = emissions.count
        guard n > 0 else { return [] }
        let logT = transition.map { $0.map { log($0) } }
        var prev = emissions[0].map { log(max($0, 1e-12)) + log(0.25) }
        var back: [[Int]] = []
        for t in 1..<n {
            var cur = [Double](repeating: 0, count: 4)
            var bt = [Int](repeating: 0, count: 4)
            for j in 0..<4 {
                var bestV = -Double.infinity, bestK = 0
                for k in 0..<4 {
                    let v = prev[k] + logT[k][j]
                    if v > bestV { bestV = v; bestK = k }
                }
                cur[j] = bestV + log(max(emissions[t][j], 1e-12))
                bt[j] = bestK
            }
            prev = cur; back.append(bt)
        }
        var path = [prev.firstIndex(of: prev.max()!)!]
        for bt in back.reversed() { path.append(bt[path.last!]) }
        return Array(path.reversed())
    }

    /// Within-epoch HR variability from the HR trace itself (±2 epochs),
    /// so the classifier doesn't need a separate HRV-variability channel.
    private static func hrVarAt(_ hrs: [Double?], _ i: Int) -> Double {
        let lo = max(0, i - 2), hi = min(hrs.count, i + 3)
        let w = hrs[lo..<hi].compactMap { $0 }
        guard w.count >= 2 else { return 0 }
        let m = w.reduce(0, +) / Double(w.count)
        return (w.map { ($0 - m) * ($0 - m) }.reduce(0, +)
                / Double(w.count)).squareRoot()
    }

    private static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2]
                                : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Stages a night of 30-second epochs.
    /// - Parameter epochs: Chronological epoch features for the night.
    /// - Returns: One `SleepEpoch` per input epoch, in the same order.
    static func stage(epochs: [EpochFeatures]) -> [SleepEpoch] {
        let motions = epochs.map { activityIndex(fromG: $0.motionMagnitude) }
        let hrs = epochs.map(\.heartRate)
        let calmHR = zip(motions, hrs).compactMap { m, h -> Double? in
            m < 0.3 ? h : nil
        }
        let calmRMSSD = zip(motions, epochs.map(\.hrv)).compactMap { m, r -> Double? in
            m < 0.3 ? r : nil
        }
        let medHR = median(calmHR) ?? 60
        let medRMSSD = median(calmRMSSD) ?? 40
        let emissions = epochs.indices.map { i -> [Double] in
            let e = epochs[i]
            let hr = e.heartRate ?? medHR
            let rm = e.hrv ?? medRMSSD
            return softmax(scores(motion: motions[i], hr: hr, medianHR: medHR,
                                  rmssd: rm, medianRMSSD: medRMSSD,
                                  hrVar: hrVarAt(hrs, i),
                                  tHours: e.timeOfNightHours))
        }
        let path = viterbi(emissions)
        return zip(epochs, path).map { e, s in
            SleepEpoch(index: e.index, stage: order[s])
        }
    }

    /// Onset = first of ≥3 consecutive sleep epochs; wake = last sleep epoch.
    static func summarize(_ staged: [SleepEpoch]) -> StagedNightSummary {
        let stages = staged.map(\.stage)
        let n = stages.count
        let empty = StagedNightSummary(totalSleepMinutes: 0, efficiency: 0,
                                       minutesByStage: [:],
                                       onsetIndex: nil, wakeIndex: nil)
        guard n >= 3 else { return empty }
        var onset: Int?
        for i in 0..<(n - 2)
            where stages[i] != .wake && stages[i+1] != .wake && stages[i+2] != .wake {
            onset = i; break
        }
        guard let onset else { return empty }
        var wake = onset
        for i in stride(from: n - 1, through: onset, by: -1)
            where stages[i] != .wake { wake = i; break }
        let span = Array(stages[onset...wake])
        let epochMin = 0.5
        var byStage: [SleepStage: Double] = [:]
        var tst = 0.0
        for s in span {
            byStage[s, default: 0] += epochMin
            if s != .wake { tst += epochMin }
        }
        let tib = Double(span.count) * epochMin
        return StagedNightSummary(totalSleepMinutes: tst,
                                  efficiency: tib > 0 ? tst / tib : 0,
                                  minutesByStage: byStage,
                                  onsetIndex: staged[onset].index,
                                  wakeIndex: staged[wake].index)
    }
}

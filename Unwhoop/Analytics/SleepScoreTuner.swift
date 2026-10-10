import Foundation
import SwiftData

#if DEBUG
// MARK: - SleepScoreTuner (DEBUG ONLY)
//
// Fits SleepWeights against the user's imported WHOOP export, entirely
// on-device. For each imported night it recomputes OUR four sleep components
// from the export's own fields (same builders production uses), then
// grid-searches the weight simplex for the combination that best predicts
// WHOOP's official sleep score. Reports weights + RMSE/R²/bias; the UI offers
// "use these weights", which stores them in AppSettings. Nothing leaves the
// phone. Compiler-gated: absent from production builds.

enum SleepScoreTuner {
    struct FitResult: Sendable {
        var weights: SleepWeights
        var rmse: Double
        var r2: Double
        var bias: Double        // mean(predicted − official)
        var nights: Int
        var vitalsCoverage: Double // fraction of nights with real RHR+HRV
        var defaultRmse: Double  // RMSE under default weights, for reference
    }

    static func fit(entries: [BenchmarkEntry]) -> FitResult? {
        let nights = entries
            .filter { $0.officialSleepScore != nil && $0.officialSleepMinutes != nil }
            .sorted { $0.entryDate < $1.entryDate }
        guard nights.count >= 7 else { return nil }

        struct Row {
            let official: Double
            let components: SleepComponents
            let hasVitals: Bool
        }
        var rows: [Row] = []
        var needHist: [(needMin: Double, actualMin: Double)] = []

        for (i, e) in nights.enumerated() {
            let priors = Array(nights.prefix(i))
            guard priors.count >= 3,
                  let total = e.officialSleepMinutes,
                  let onset = e.sleepOnset,
                  let wake = e.wakeTime, wake > onset,
                  let tib = e.timeInBedMinutes, tib > 0,
                  let official = e.officialSleepScore,
                  let medSleep = median(priors.compactMap(\.officialSleepMinutes))
            else { continue }

            let strain = e.officialStrain ?? 12
            let debt = sleepDebtMinutes(needHist.suffix(7).map {
                (needMin: $0.needMin, actualMin: $0.actualMin)
            })
            let need = sleepNeedMinutes(baselineMedianMin: medSleep,
                                        dayStrain: strain, sleepDebtMin: debt)
            needHist.append((needMin: need, actualMin: total))

            let midpoints = priors.compactMap { p -> Date? in
                guard let o = p.sleepOnset, let w = p.wakeTime, w > o else { return nil }
                return o.addingTimeInterval(w.timeIntervalSince(o) / 2)
            }
            let mid = onset.addingTimeInterval(wake.timeIntervalSince(onset) / 2)
            let cons = medianDate(midpoints)
                .map { sleepConsistency(midpoint: mid, medianMidpoint: $0) } ?? 0.5

            let rhrBase = median(priors.compactMap(\.rhrBpm))
            let hrvBase = median(priors.compactMap(\.hrvMs))
            let rest: Double
            let hasVitals: Bool
            if let r = e.rhrBpm, let h = e.hrvMs,
               let rb = rhrBase, let hb = hrvBase {
                rest = sleepRestfulness(rhrBpm: r, rhrBaselineBpm: rb,
                                        hrvMs: h, hrvBaselineMs: hb)
                hasVitals = true
            } else {
                rest = 0.5  // neutral when the export has no vitals
                hasVitals = false
            }

            rows.append(Row(
                official: official,
                components: SleepComponents(
                    sufficiency: sleepSufficiency(totalSleepMin: total, needMin: need),
                    efficiency: sleepEfficiency(totalSleepMin: total, timeInBedMin: tib),
                    consistency: cons,
                    restfulness: rest),
                hasVitals: hasVitals))
        }
        guard rows.count >= 5 else { return nil }

        let vitalsCoverage =
            Double(rows.filter(\.hasVitals).count) / Double(rows.count)

        func rmse(_ w: SleepWeights) -> Double {
            let se = rows.map { r in
                let e = sleepScore(r.components, weights: w) - r.official
                return e * e
            }
            return (se.reduce(0, +) / Double(se.count)).squareRoot()
        }

        // Grid-search the simplex at 0.05 steps (1771 combos for 4 weights;
        // trivial compute). If no night has vitals, restfulness is constant
        // and its weight is unidentifiable — pin it at default and fit the
        // other three.
        let step = 0.05
        let n = Int((1 / step).rounded())
        var bestW = SleepWeights.default
        var bestRmse = Double.infinity
        if vitalsCoverage == 0 {
            let m = Int((0.8 / step).rounded())
            for a in 0...m {
                for b in 0...(m - a) {
                    let c = m - a - b
                    let w = SleepWeights(
                        sufficiency: Double(a) * step,
                        efficiency: Double(b) * step,
                        consistency: Double(c) * step,
                        restfulness: 0.20)
                    let r = rmse(w)
                    if r < bestRmse { bestRmse = r; bestW = w }
                }
            }
        } else {
            for a in 0...n {
                for b in 0...(n - a) {
                    for c in 0...(n - a - b) {
                        let d = n - a - b - c
                        let w = SleepWeights(
                            sufficiency: Double(a) * step,
                            efficiency: Double(b) * step,
                            consistency: Double(c) * step,
                            restfulness: Double(d) * step)
                        let r = rmse(w)
                        if r < bestRmse { bestRmse = r; bestW = w }
                    }
                }
            }
        }

        let preds = rows.map { sleepScore($0.components, weights: bestW) }
        let mean = rows.map(\.official).reduce(0, +) / Double(rows.count)
        let ssRes = zip(preds, rows).map { (p, r) in
            let e = p - r.official; return e * e
        }.reduce(0, +)
        let ssTot = rows.map { r in
            let e = r.official - mean; return e * e
        }.reduce(0, +)
        let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0
        let bias = zip(preds, rows).map { $0 - $1.official }.reduce(0, +)
            / Double(rows.count)

        return FitResult(weights: bestW.normalized, rmse: bestRmse, r2: r2,
                         bias: bias, nights: rows.count,
                         vitalsCoverage: vitalsCoverage,
                         defaultRmse: rmse(.default))
    }

    // MARK: helpers

    private static func median(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        let s = vals.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    private static func medianDate(_ vals: [Date]) -> Date? {
        guard !vals.isEmpty else { return nil }
        let s = vals.sorted()
        let m = s.count / 2
        if s.count % 2 == 1 { return s[m] }
        return Date(timeIntervalSince1970:
            (s[m - 1].timeIntervalSince1970 + s[m].timeIntervalSince1970) / 2)
    }
}
#endif

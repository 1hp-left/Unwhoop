import Foundation

#if DEBUG
// MARK: - BenchmarkStats (DEBUG ONLY)
//
// Real implementation (ported 1:1 from the tested Python reference
// analytics-py/unwhoop/benchmark.py — 27/27 tests green).
//
// Contract (PRD §5.6 / Ch. 8): agreement statistics over paired days
// (Unwhoop-computed vs WHOOP official).
// - Never "validate" with correlation alone: report bias and limits of
//   agreement (Bland–Altman), ICC (absolute agreement), and MAE.
// - Sleep staging agreement uses Cohen's kappa (+ PABAK available).
// - Deterministic: same input, byte-identical output. No randomness.
// - Compiler-gated: none of this exists in production builds.

/// Agreement summary for one metric over N paired days.
struct AgreementStats: Sendable {
    var n: Int
    var bias: Double     // mean(Unwhoop − Official)
    var loaLower: Double // bias − 1.96·SD
    var loaUpper: Double // bias + 1.96·SD
    var icc: Double      // absolute agreement
    var mae: Double

    /// One-line strip text, e.g. "Recovery: bias +3.1 pts, LoA ±9.4 over 28 paired nights."
    var stripLine: String {
        let half = (loaUpper - loaLower) / 2
        return String(format: "bias %+.1f, LoA ±%.1f over %d paired", bias, half, n)
    }
}

enum BenchmarkStats {
    /// Bland–Altman: bias and 95% limits of agreement for paired samples.
    static func blandAltman(unwhoop: [Double], official: [Double])
        -> (bias: Double, loaLower: Double, loaUpper: Double) {
        precondition(unwhoop.count == official.count && unwhoop.count >= 2)
        let d = zip(unwhoop, official).map(-)
        let n = Double(d.count)
        let bias = d.reduce(0, +) / n
        // Sample SD (ddof=1) for n > 2, matching the reference.
        let denom = d.count > 2 ? n - 1 : n
        let variance = d.map { ($0 - bias) * ($0 - bias) }.reduce(0, +) / denom
        let sd = variance.squareRoot()
        return (bias, bias - 1.96 * sd, bias + 1.96 * sd)
    }

    /// Intraclass correlation, absolute agreement, for paired samples.
    /// ICC(A,1), Shrout & Fleiss: two-way random, single measures.
    static func iccAbsoluteAgreement(unwhoop: [Double],
                                     official: [Double]) -> Double {
        let ratings = zip(unwhoop, official).map { [$0, $1] }
        let n = ratings.count, k = 2
        precondition(n >= 2)
        let flat = ratings.flatMap { $0 }
        let grand = flat.reduce(0, +) / Double(flat.count)
        let rowMeans = ratings.map { $0.reduce(0, +) / Double(k) }
        let colMeans = (0..<k).map { j in
            ratings.map { $0[j] }.reduce(0, +) / Double(n)
        }
        let ssr = Double(k) * rowMeans.map { ($0 - grand) * ($0 - grand) }
                                      .reduce(0, +)
        let ssc = Double(n) * colMeans.map { ($0 - grand) * ($0 - grand) }
                                      .reduce(0, +)
        let sst = flat.map { ($0 - grand) * ($0 - grand) }.reduce(0, +)
        let sse = sst - ssr - ssc
        let dfE = Double((n - 1) * (k - 1))
        let msr = ssr / Double(n - 1)
        let msc = ssc / Double(k - 1)
        let mse = dfE > 0 ? sse / dfE : 0
        let denom = msr + Double(k - 1) * mse + (Double(k) / Double(n))
                        * (msc - mse)
        guard denom != 0 else { return mse == 0 ? 1 : 0 }
        return (msr - mse) / denom
    }

    /// Mean absolute error for paired samples.
    static func mae(unwhoop: [Double], official: [Double]) -> Double {
        zip(unwhoop, official).map { abs($0 - $1) }.reduce(0, +)
            / Double(unwhoop.count)
    }

    private static func confusionMatrix(unwhoopStages: [SleepStage],
                                        officialStages: [SleepStage])
        -> [[Int]] {
        let order: [SleepStage] = [.wake, .light, .deep, .rem]
        var cm = [[Int]](repeating: [Int](repeating: 0, count: 4), count: 4)
        for (u, o) in zip(unwhoopStages, officialStages) {
            if let i = order.firstIndex(of: u),
               let j = order.firstIndex(of: o) { cm[i][j] += 1 }
        }
        return cm
    }

    /// Cohen's kappa for paired sleep-stage sequences.
    static func cohensKappa(unwhoopStages: [SleepStage],
                            officialStages: [SleepStage]) -> Double {
        cohenKappa(confusionMatrix(unwhoopStages: unwhoopStages,
                                   officialStages: officialStages))
    }

    /// Cohen's kappa from a square confusion matrix (rows = truth).
    /// Landis & Koch bands: 0.21–0.40 fair, 0.41–0.60 moderate, 0.61–0.80
    /// substantial. Report alongside PABAK (class-imbalance distortion).
    static func cohenKappa(_ confusion: [[Int]]) -> Double {
        let n = Double(confusion.flatMap { $0 }.reduce(0, +))
        guard n > 0 else { return 0 }
        let k = confusion.count
        let po = Double((0..<k).map { confusion[$0][$0] }.reduce(0, +)) / n
        var pe = 0.0
        for i in 0..<k {
            let row = Double(confusion[i].reduce(0, +))
            let col = Double((0..<k).map { confusion[$0][i] }.reduce(0, +))
            pe += row * col / (n * n)
        }
        return pe < 1 ? (po - pe) / (1 - pe) : 0
    }

    /// Prevalence-and-bias-adjusted kappa (as in the Oura Gen3 validation).
    static func pabak(_ confusion: [[Int]]) -> Double {
        let n = Double(confusion.flatMap { $0 }.reduce(0, +))
        guard n > 0 else { return 0 }
        let k = confusion.count
        let po = Double((0..<k).map { confusion[$0][$0] }.reduce(0, +)) / n
        return 2 * po - 1
    }

    /// Convenience: full agreement summary for one metric.
    static func agreement(unwhoop: [Double],
                          official: [Double]) -> AgreementStats {
        let ba = blandAltman(unwhoop: unwhoop, official: official)
        return AgreementStats(
            n: unwhoop.count, bias: ba.bias,
            loaLower: ba.loaLower, loaUpper: ba.loaUpper,
            icc: iccAbsoluteAgreement(unwhoop: unwhoop, official: official),
            mae: mae(unwhoop: unwhoop, official: official))
    }
}
#endif

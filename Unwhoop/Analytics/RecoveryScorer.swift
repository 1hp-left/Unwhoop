import Foundation

// MARK: - RecoveryScorer
//
// Real implementation (ported 1:1 from the tested Python reference
// analytics-py/unwhoop/recovery.py — 27/27 tests green).
//
// Contract (PRD §5.3):
// - LnRMSSD from the deepest-sleep window is the primary input (most
//   autonomically stable window; standardized resting conditions).
// - Each metric is a z-score against the user's own 7-day rolling baseline.
//   Smallest-worthwhile-change band = mean ± 0.5 SD.
// - Fusion: HRV z (primary) + resting-HR deviation + sleep performance vs
//   need. NEVER LF/HF ratio (evidence is against it).
// - Bands: 67–100 Recovered, 34–66 Pay attention, 0–33 Rest.
// - R-R artifact rejection (Malik/Kubios-style) runs BEFORE any HRV math —
//   see RRAnalysis; the pipeline sets NightSummary.lowConfidence.
// - Confounder flags move the display, never the baseline.
// - No score until the baseline exists (first 7 days).
// - Deterministic: same input, byte-identical output. No randomness.

/// Result of scoring one night.
struct RecoveryResult: Sendable {
    /// 0–100.
    var score: Double
    var band: RecoveryBand
    var lowConfidence: Bool
    var confidenceReason: String?
    var flags: [ConfounderFlag]
    /// One-line basis shown on tap, e.g. "LnRMSSD 58ms vs your 54ms baseline".
    /// No black boxes (PRD §6).
    var basisLine: String
}

enum RecoveryScorer {
    // v1 fusion weights — tunable via benchmark fitting (PRD §5.6).
    private static let wHRV = 0.60, wRHR = 0.25, wSleep = 0.15

    /// 50 + 22·(0.6·zHRV − 0.25·zRHR + 0.15·zSleep), clipped to 0–100.
    /// RHR elevation is bad, hence subtracted.
    static func fuse(zHRV: Double, zRHR: Double, zSleep: Double) -> Double {
        let combined = wHRV * zHRV - wRHR * zRHR + wSleep * zSleep
        return min(100, max(0, 50 + 22 * combined))
    }

    /// Display-only flags. Flagged nights must NOT enter the baseline.
    static func confounderFlags(zHRV: Double, zRHR: Double,
                                rhrDeltaBpm: Double) -> [ConfounderFlag] {
        var flags: [ConfounderFlag] = []
        // Alcohol signature: HRV suppressed + RHR elevated the same night.
        if zHRV < -1.0 && zRHR > 1.0 { flags.append(.alcoholSignature) }
        // Illness signature: RHR +2–5 bpm with HRV suppression.
        if rhrDeltaBpm >= 2.0 && zHRV < -0.75 { flags.append(.illnessSignature) }
        return flags
    }

    /// Scores one night against the user's rolling baselines.
    /// - Parameters:
    ///   - night: The night's ingested vitals/sleep. R-R artifact rejection is
    ///     the pipeline's job (see RRAnalysis); `night.lowConfidence` carries
    ///     the quality gate verdict through to the display.
    ///   - baselines: The user's current 7-day rolling baselines.
    /// - Returns: Score 0–100 with band, confidence, flags, and basis line.
    ///   Never interpolates a score: incomplete baseline or failed quality
    ///   gates surface as low-confidence, not a fake number.
    static func score(night: NightSummary, baselines: Baselines) -> RecoveryResult {
        guard baselines.isComplete else {
            let toGo = max(0, 7 - baselines.nightsUsed)
            return RecoveryResult(
                score: 0, band: .rest, lowConfidence: true,
                confidenceReason: "Building baseline — \(toGo) night\(toGo == 1 ? "" : "s") to go",
                flags: [], basisLine: "Baseline building")
        }
        let zH = baselines.hrv.zScore(for: night.lnRMSSD)
        let zR = baselines.restingHR.zScore(for: night.restingHR)
        let perfRatio = night.sleepNeedMinutes > 0
            ? night.totalSleepMinutes / night.sleepNeedMinutes : 1.0
        let zS = baselines.sleepPerformance.zScore(for: perfRatio)

        let score = fuse(zHRV: zH, zRHR: zR, zSleep: zS)
        let flags = confounderFlags(zHRV: zH, zRHR: zR,
                                    rhrDeltaBpm: night.restingHR - baselines.restingHR.mean)
        // Basis line in ms (exp of the log values), per PRD §6 "no black boxes".
        let basis = String(format: "LnRMSSD %.0fms vs your %.0fms baseline",
                           exp(night.lnRMSSD), exp(baselines.hrv.mean))
        let reason = night.lowConfidence ? night.confidenceReason : nil
        return RecoveryResult(score: score,
                              band: RecoveryBand.band(for: score),
                              lowConfidence: night.lowConfidence,
                              confidenceReason: reason,
                              flags: flags, basisLine: basis)
    }
}

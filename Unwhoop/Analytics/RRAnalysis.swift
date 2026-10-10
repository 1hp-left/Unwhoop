import Foundation

// MARK: - RRAnalysis
//
// Real implementation (ported 1:1 from the tested Python reference
// analytics-py/unwhoop/rr.py — 27/27 tests green).
//
// R-R artifact rejection runs BEFORE any HRV math (PRD §5.2):
// Malik/Kubios-style filtering with the Kamath 20%-of-local-median rule plus
// physiologic bounds. A night whose artifact fraction exceeds the gate is
// labeled low-confidence — the pipeline surfaces the badge, never a fake
// score. Also: deepest-sleep-window selection (most autonomically stable
// 5-min window) for the LnRMSSD + resting-HR read.

enum RRAnalysis {
    static let rrMinMs = 300.0
    static let rrMaxMs = 2000.0
    static let ectopicFraction = 0.20
    static let localWindow = 5
    /// Above this artifact fraction the night is flagged low-confidence.
    static let artifactGate = 0.15

    struct CleaningResult: Sendable {
        /// Ectopic/out-of-range beats replaced by the local median, so
        /// downstream math sees a continuous normal-beat series.
        var cleaned: [Double]
        var artifactFraction: Double
        var nRemoved: Int
        var lowConfidence: Bool
    }

    private static func localMedian(_ rr: [Double], _ i: Int) -> Double {
        let lo = max(0, i - localWindow)
        let hi = min(rr.count, i + localWindow + 1)
        var w: [Double] = []
        w.reserveCapacity(hi - lo)
        for j in lo..<hi where j != i { w.append(rr[j]) }
        guard !w.isEmpty else { return rr[i] }
        let s = w.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Artifact-correct an R-R series (ms). Deterministic.
    static func cleanRR(_ rrMs: [Double]) -> CleaningResult {
        let n = rrMs.count
        guard n > 0 else {
            return CleaningResult(cleaned: [], artifactFraction: 1.0,
                                  nRemoved: 0, lowConfidence: true)
        }
        var bad = [Bool](repeating: false, count: n)
        for (i, v) in rrMs.enumerated() {
            if !(rrMinMs...rrMaxMs).contains(v) { bad[i] = true; continue }
            let med = localMedian(rrMs, i)
            if med > 0 && abs(v - med) / med > ectopicFraction {
                bad[i] = true
            }
        }
        var cleaned = rrMs
        for i in 0..<n where bad[i] { cleaned[i] = localMedian(rrMs, i) }
        let nRemoved = bad.filter { $0 }.count
        let frac = Double(nRemoved) / Double(n)
        return CleaningResult(cleaned: cleaned, artifactFraction: frac,
                              nRemoved: nRemoved,
                              lowConfidence: frac > artifactGate)
    }

    /// Root mean square of successive differences (ms). Input: cleaned series.
    static func rmssd(_ rrMs: [Double]) -> Double {
        guard rrMs.count >= 2 else { return 0 }
        var sum = 0.0
        for i in 1..<rrMs.count {
            let d = rrMs[i] - rrMs[i - 1]
            sum += d * d
        }
        return (sum / Double(rrMs.count - 1)).squareRoot()
    }

    /// Natural log of RMSSD — the primary recovery HRV metric.
    static func lnRMSSD(_ rrMs: [Double]) -> Double {
        let r = rmssd(rrMs)
        return r > 0 ? log(r) : -.infinity
    }

    /// Start epoch of the most autonomically stable 5-min window, or nil when
    /// no window qualifies (restless night → no LnRMSSD reading, not a guess).
    static func deepestSleepWindow(epochHR: [Double], epochMotion: [Double],
                                   motionThresh: Double = 0.15,
                                   windowEpochs: Int = 10) -> Int? {
        let n = epochHR.count
        guard n >= windowEpochs else { return nil }
        var best: Int?
        var bestHR = Double.infinity
        for s in 0...(n - windowEpochs) {
            let m = epochMotion[s..<(s + windowEpochs)].reduce(0, +)
                  / Double(windowEpochs)
            guard m <= motionThresh else { continue }
            let h = epochHR[s..<(s + windowEpochs)].reduce(0, +)
                  / Double(windowEpochs)
            if h < bestHR { bestHR = h; best = s }
        }
        return best
    }
}

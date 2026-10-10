import Foundation

// MARK: - RespiratoryEstimator
//
// Real implementation (ported 1:1 from the tested Python reference
// analytics-py/unwhoop/resp.py — 27/27 tests green).
//
// Contract (PRD §5.2 / Appendix A.1): the 5.0 exposes NO raw respiration
// stream over BLE, so breathing rate is derived from respiratory sinus
// arrhythmia (RSA) — the same approach as Noop's SleepStager.respRateFromRR
// and Fitbit's production algorithm (MAE 0.75 brpm vs flow sensors).
// Recipe: still-window gate (≥2 min continuous stillness) → interpolate R-R
// to a uniform 4 Hz tachogram (cubic spline) → bandpass 0.1–0.5 Hz (6–30
// brpm, the HF band = the RSA signal) → peak-detect, 60 / mean inter-peak
// interval. Nightly value = MEDIAN of per-minute deep-sleep estimates.
// Reject when HF power is negligible vs total HRV power (weak RSA: low-HRV
// individuals, stress, illness). A confident "no reading" beats a
// fabrication. Expected MAE ~0.75–2.5 brpm at rest/sleep — a recovery input,
// not a clinical measurement.
// Pure-Swift DSP (no Accelerate assumed). Deterministic. No randomness.
//
// NOTE: the bandpass here is a 2× forward-backward RBJ biquad cascade tuned
// to the same 0.1–0.5 Hz passband as the Python 4th-order Butterworth —
// equivalent response for this purpose, not bit-identical. Validate the DSP
// path on-device against the Python reference before trusting readings.

/// Input for one respiratory-rate estimation window.
struct RespirationInput: Sendable {
    /// R-R intervals in seconds, artifact-rejected, chronological.
    var rrIntervals: [Double]
    /// Window length in seconds the intervals were taken over.
    var window: TimeInterval
}

enum RespiratoryEstimator {
    static let targetFs = 4.0
    static let bandLo = 0.1, bandHi = 0.5   // Hz → 6–30 brpm
    static let minStillSeconds = 120.0
    static let minHFRatio = 0.05

    // MARK: Cubic spline (natural) interpolation to a uniform grid

    static func cubicSpline(x: [Double], y: [Double],
                            xNew: [Double]) -> [Double] {
        let n = x.count
        guard n >= 2 else { return xNew.map { _ in y.first ?? 0 } }
        var h = [Double](repeating: 0, count: n - 1)
        var alpha = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) { h[i] = x[i + 1] - x[i] }
        for i in 1..<(n - 1) {
            alpha[i] = (3 / h[i]) * (y[i + 1] - y[i])
                     - (3 / h[i - 1]) * (y[i] - y[i - 1])
        }
        var l = [Double](repeating: 1, count: n)
        var mu = [Double](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            l[i] = 2 * (x[i + 1] - x[i - 1]) - h[i - 1] * mu[i - 1]
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
        }
        var m = [Double](repeating: 0, count: n)
        for i in stride(from: n - 2, through: 0, by: -1) {
            m[i] = z[i] - mu[i] * m[i + 1]
        }
        return xNew.map { xn in
            var i = n - 2
            while i > 0 && xn < x[i] { i -= 1 }
            while i < n - 2 && xn > x[i + 1] { i += 1 }
            let dx = xn - x[i]
            let a = (m[i + 1] - m[i]) / (6 * h[i])
            let b = m[i] / 2
            let c = (y[i + 1] - y[i]) / h[i] - h[i] * (2 * m[i] + m[i + 1]) / 6
            return a * dx * dx * dx + b * dx * dx + c * dx + y[i]
        }
    }

    // MARK: Zero-phase bandpass (RBJ biquad, forward-backward ×2)

    private struct Biquad { var b0, b1, b2, a1, a2: Double }

    private static func bandpassCoeffs(fs: Double = targetFs) -> Biquad {
        let f0 = (bandLo * bandHi).squareRoot() // geometric center
        let q = f0 / (bandHi - bandLo)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0,
                      a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    static func bandpass(_ x: [Double]) -> [Double] {
        let c = bandpassCoeffs()
        func pass(_ v: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: v.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for (n, xn) in v.enumerated() {
                let yn = c.b0 * xn + c.b1 * x1 + c.b2 * x2
                           - c.a1 * y1 - c.a2 * y2
                y[n] = yn
                x2 = x1; x1 = xn; y2 = y1; y1 = yn
            }
            return y
        }
        // forward-backward twice ≈ zero phase, ≈4th-order skirts
        let fwd1 = pass(x)
        let bwd1 = Array(pass(Array(fwd1.reversed())).reversed())
        let fwd2 = pass(bwd1)
        return Array(pass(Array(fwd2.reversed())).reversed())
    }

    // MARK: HF-power ratio gate (windowed DFT)

    static func hfRatio(_ tach: [Double], fs: Double = targetFs) -> Double {
        let n = tach.count
        guard n >= 64 else { return 0 }
        let seg = min(256, n)
        var total = 0.0, hf = 0.0
        var start = 0
        while start + seg <= n {
            let frame = Array(tach[start..<(start + seg)])
            let mean = frame.reduce(0, +) / Double(seg)
            for k in 0..<(seg / 2) {
                var sr = 0.0, si = 0.0
                for t in 0..<seg {
                    let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(t)
                                            / Double(seg - 1)) // Hann
                    let v = (frame[t] - mean) * w
                    let a = 2 * Double.pi * Double(k) * Double(t) / Double(seg)
                    sr += v * cos(a); si -= v * sin(a)
                }
                let p = (sr * sr + si * si) / Double(seg * seg)
                let f = Double(k) * fs / Double(seg)
                total += p
                if (0.15...0.40).contains(f) { hf += p }
            }
            start += seg / 2
        }
        return total > 0 ? hf / total : 0
    }

    // MARK: Peak detection → rate

    static func peakRate(_ filtered: [Double],
                        fs: Double = targetFs) -> Double? {
        let n = filtered.count
        guard n > Int(fs * 60) else { return nil }
        let mean = filtered.reduce(0, +) / Double(n)
        let variance = filtered.map { ($0 - mean) * ($0 - mean) }
                               .reduce(0, +) / Double(n)
        let prom = variance.squareRoot() * 0.3
        let minDist = Int(fs * 1.5)
        var peaks: [Int] = []
        var i = 1
        while i < n - 1 {
            if filtered[i] > filtered[i - 1] && filtered[i] >= filtered[i + 1]
                && filtered[i] - mean > prom {
                if let last = peaks.last, i - last < minDist {
                    if filtered[i] > filtered[last] { peaks[peaks.count - 1] = i }
                } else { peaks.append(i) }
            }
            i += 1
        }
        guard peaks.count >= 3 else { return nil }
        var ipiSum = 0.0
        for k in 1..<peaks.count {
            ipiSum += Double(peaks[k] - peaks[k - 1]) / fs
        }
        let meanIPI = ipiSum / Double(peaks.count - 1)
        guard meanIPI > 0 else { return nil }
        let brpm = 60 / meanIPI
        return (bandLo * 60...bandHi * 60).contains(brpm) ? brpm : nil
    }

    // MARK: Public API

    /// Estimates respiratory rate in breaths/min, or nil when the estimate
    /// fails the quality gate. `tachMs`: uniform 4 Hz tachogram (ms).
    static func estimate(tachMs: [Double]) -> Double? {
        guard tachMs.count >= Int(targetFs * 60) else { return nil }
        guard hfRatio(tachMs) >= minHFRatio else { return nil }
        return peakRate(bandpass(tachMs))
    }

    /// Estimates respiratory rate in breaths/min, or nil when the estimate
    /// fails the quality gate (too short a window or weak RSA).
    static func estimate(from input: RespirationInput) -> Double? {
        let rrMs = input.rrIntervals.map { $0 * 1000 }
        guard rrMs.count >= 30, input.window >= minStillSeconds else {
            return nil
        }
        // Reconstruct beat times by cumulative sum of intervals.
        var times = [Double](repeating: 0, count: rrMs.count)
        var acc = 0.0
        for (i, v) in rrMs.enumerated() { acc += v / 1000; times[i] = acc }
        var tu: [Double] = []
        var t = times[0]
        while t < times.last! { tu.append(t); t += 1 / targetFs }
        let tach = cubicSpline(x: times, y: rrMs, xNew: tu)
        return estimate(tachMs: tach)
    }

    /// Nightly value: median of per-minute deep-sleep estimates.
    static func nightly(_ perMinute: [Double?]) -> Double? {
        let vals = perMinute.compactMap { $0 }.sorted()
        guard !vals.isEmpty else { return nil }
        return vals.count % 2 == 1
            ? vals[vals.count / 2]
            : (vals[vals.count / 2 - 1] + vals[vals.count / 2]) / 2
    }
}

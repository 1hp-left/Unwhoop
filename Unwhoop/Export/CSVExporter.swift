import Foundation

// MARK: - CSVExporter
//
// Computed tier (default): per-day summaries (recovery, strain, sleep, HRV,
// RHR, respiratory rate, temp deviation) + per-minute TRIMP aggregates.
// Kilobytes per year; exports in seconds (PRD §5.7). The UI shows
// estimatedBytes BEFORE exporting.

enum CSVExporter {
    /// Writes the computed-tier CSV to a temp file and returns its URL.
    static func computedCSV(nights: [NightSummary], days: [DaySummary]) throws -> URL {
        var lines: [String] = []
        lines.append("type,date,ln_rmssd,resting_hr_bpm,resp_rate_bpm,skin_temp_dev_c," +
                     "sleep_onset,wake_time,total_sleep_min,sleep_efficiency_pct," +
                     "light_min,deep_min,rem_min,wake_min,sleep_need_min," +
                     "recovery_score,recovery_band,low_confidence,strain_0_21,trimp_load,sleep_score")
        let iso = ISO8601DateFormatter()
        for night in nights.sorted(by: { $0.nightDate < $1.nightDate }) {
            let day = days.first { Calendar.current.isDate($0.dayDate, inSameDayAs: night.nightDate) }
            lines.append([
                "night",
                iso.string(from: night.nightDate),
                night.hrvAvailable ? num(night.lnRMSSD) : "", night.restingHRAvailable ? num(night.restingHR) : "",
                opt(night.respiratoryRate), opt(night.skinTempDeviation),
                night.sleepOnset.map { iso.string(from: $0) } ?? "",
                night.wakeTime.map { iso.string(from: $0) } ?? "",
                num(night.totalSleepMinutes), num(night.sleepEfficiency * 100),
                num(night.lightMinutes), num(night.deepMinutes),
                num(night.remMinutes), num(night.wakeMinutes),
                num(night.sleepNeedMinutes),
                night.recoveryScore.map(num) ?? "",
                night.recoveryBandRaw ?? "",
                night.lowConfidence ? "1" : "0",
                day.flatMap { $0.strainAvailable ? num($0.strain) : nil } ?? "",
                day.map { num($0.trimpLoad) } ?? "",
                opt(night.sleepScore),
            ].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unwhoop-computed-\(Date().timeIntervalSince1970).csv")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Pre-export size estimate for the UI.
    static func estimatedBytes(nights: Int, days: Int) -> Int {
        // ~220 bytes/row header-inclusive; comfortably an overestimate.
        220 * (nights + days) + 300
    }

    // MARK: - Private

    private static func num(_ v: Double) -> String { String(format: "%.3f", v) }
    private static func opt(_ v: Double?) -> String { v.map(num) ?? "" }
}

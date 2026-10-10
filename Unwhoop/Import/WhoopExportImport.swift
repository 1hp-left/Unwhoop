import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
// MARK: - WHOOP export import (DEV ONLY, on-device)
//
// The primary benchmark ground-truth path (PRD §5.6): the user requests their
// WHOOP member data export (my_whoop_data_*.zip — use-it-or-lose-it while
// subscribed), unzips it in the Files app, and picks physiological_cycles.csv
// (+ optionally sleeps.csv) here. Everything parses and pairs ON THE PHONE.
// No network, no server, no copy sent anywhere — the user's health data never
// leaves the device, and it never passes through the assistant.
//
// Column names follow WHOOP's real export schema (verified against Noop's
// WhoopExportImporter, which handles the same files). Parsing is
// header-name-driven and tolerant: every column is optional, UTF-8 BOMs are
// stripped, localized filenames are recognized.

// MARK: Minimal CSV parser

enum WhoopCSV {
    /// Parses CSV text into (headers, rows). Handles quoted fields, escaped
    /// quotes (""), commas/newlines inside quotes, CRLF, and a UTF-8 BOM.
    static func parse(_ text: String) -> (headers: [String], rows: [[String]]) {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        var rows: [[String]] = []
        var cur: [String] = []
        var field = ""
        var inQuotes = false
        var i = t.startIndex
        func endField() { cur.append(field); field = "" }
        func endRow() { endField(); rows.append(cur); cur = [] }
        while i < t.endIndex {
            let c = t[i]
            if inQuotes {
                if c == "\"" {
                    let n = t.index(after: i)
                    if n < t.endIndex && t[n] == "\"" {
                        field.append("\""); i = n
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                endField()
            } else if c == "\n" {
                endRow()
            } else if c == "\r" {
                // swallow CRLF as one break
                let n = t.index(after: i)
                if n < t.endIndex && t[n] == "\n" { i = n }
                endRow()
            } else {
                field.append(c)
            }
            i = t.index(after: i)
        }
        endRow()
        // drop trailing empty row from a final newline
        if let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        guard let headerRow = rows.first else { return ([], []) }
        return (headerRow, Array(rows.dropFirst()))
    }

    /// Normalizes a header for tolerant matching:
    /// "Recovery score %" / "recovery_score_pct" -> "recovery_score_pct".
    static func norm(_ h: String) -> String {
        h.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "pct")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "_")
    }
}

// MARK: Row access

struct CSVRow {
    let map: [String: String]
    init(headers: [String], values: [String]) {
        var m: [String: String] = [:]
        for (i, h) in headers.enumerated() {
            m[WhoopCSV.norm(h)] = i < values.count ? values[i] : ""
        }
        self.map = m
    }
    func double(_ keys: String...) -> Double? {
        for k in keys {
            if let s = map[k]?.trimmingCharacters(in: .whitespaces),
               !s.isEmpty, let v = Double(s) { return v }
        }
        return nil
    }
    func string(_ keys: String...) -> String? {
        for k in keys {
            if let s = map[k]?.trimmingCharacters(in: .whitespaces),
               !s.isEmpty { return s }
        }
        return nil
    }
}

// MARK: WHOOP time

enum WhoopTime {
    /// Parses "2024-01-15T07:30:00.000" style timestamps. The export's
    /// cycle_timezone column ("+HH:MM") anchors them; without it we assume
    /// the phone's local zone (documented approximation).
    static func parse(_ s: String?, offsetMinutes: Int) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty
        else { return nil }
        let fmts = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd HH:mm:ss"]
        let tz = TimeZone(secondsFromGMT: offsetMinutes * 60)
            ?? TimeZone.current
        for f in fmts {
            let df = DateFormatter()
            df.dateFormat = f
            df.timeZone = tz
            df.locale = Locale(identifier: "en_US_POSIX")
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// "+01:00" -> 60, "-05:00" -> -300.
    static func offsetMinutes(_ s: String?) -> Int {
        guard let s = s?.trimmingCharacters(in: .whitespaces),
              s.count >= 6 else { return 0 }
        let sign = s.hasPrefix("-") ? -1 : 1
        let parts = s.dropFirst().split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return 0 }
        return sign * (h * 60 + m)
    }
}

// MARK: Importer

/// One imported day of official WHOOP scores.
struct ImportedOfficialDay: Sendable {
    var day: Date          // local calendar day (startOfDay)
    var recovery: Double?  // Recovery %
    var strain: Double?    // Day Strain 0–21
    var sleepMinutes: Double?
}

enum WhoopExportImporter {
    struct Result: Sendable {
        var paired: Int      // new entries created
        var updated: Int     // existing entries filled in
        var skipped: Int     // rows with no usable date
        var days: Int { paired + updated }
        var sleepColumns: [String] = []  // normalized headers seen (debug aid)
        var cyclesColumns: [String] = []
        var sleepScoresFound: Int = 0    // nights with an official sleep score
    }

    /// Parses picked CSV files (route by filename; header-sniffed fallback)
    /// and upserts BenchmarkEntry rows matched by local calendar day.
    /// Everything happens on-device; nothing is uploaded anywhere.
    static func importFiles(urls: [URL],
                            context: ModelContext) -> Result {
        var cycles: [[String: String]] = []  // normalized-header row maps
        var sleeps: [[String: String]] = []
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let (headers, rows) = WhoopCSV.parse(text)
            let maps = rows.map { CSVRow(headers: headers, values: $0).map }
            let normHeaders = Set(headers.map(WhoopCSV.norm))
            if name.contains("physiological_cycles")
                || normHeaders.contains("recovery_score_pct") {
                cycles = maps
            } else if name.contains("sleep") {
                sleeps = maps
            }
            // Unrecognized files are ignored.
        }

        // Index full sleep rows by local day (naps skipped). Column names
        // vary across export versions, so every field below tries several
        // candidate keys — see the tuner for which ones actually hit.
        var sleepByDay: [Date: [String: String]] = [:]
        var sleepCols: [String] = []
        for m in sleeps {
            if m["nap"]?.lowercased() == "true" { continue } // skip naps
            if sleepCols.isEmpty { sleepCols = m.keys.sorted() }
            let tz = WhoopTime.offsetMinutes(m["cycle_timezone"])
            let onset = WhoopTime.parse(m["sleep_onset"], offsetMinutes: tz)
                ?? WhoopTime.parse(m["sleep_start"], offsetMinutes: tz)
                ?? WhoopTime.parse(m["cycle_start_time"], offsetMinutes: tz)
            guard let onset else { continue }
            let day = Calendar.current.startOfDay(for: onset)
            if sleepByDay[day] == nil { sleepByDay[day] = m }
        }
        let sleepMinByDay: [Date: Double] = sleepByDay.compactMapValues {
            double($0, "asleep_duration_min")
        }

        var paired = 0, updated = 0, skipped = 0, scoresFound = 0
        var cyclesCols: [String] = []
        for m in cycles {
            if cyclesCols.isEmpty { cyclesCols = m.keys.sorted() }
            let tz = WhoopTime.offsetMinutes(m["cycle_timezone"])
            guard let start = WhoopTime.parse(m["cycle_start_time"],
                                              offsetMinutes: tz)
                    ?? WhoopTime.parse(m["cycle_end_time"], offsetMinutes: tz)
            else { skipped += 1; continue }
            let day = Calendar.current.startOfDay(for: start)
            let rec = double(m, "recovery_score_pct")
            let str = double(m, "day_strain")
            let slp = double(m, "asleep_duration_min") ?? sleepMinByDay[day]
            let rhr = double(m, "resting_hr", "rhr", "resting_heart_rate",
                             "avg_resting_hr_bpm")
            let hrv = double(m, "hrv_rmssd_ms", "hrv", "rmssd",
                             "avg_hrv_rmssd_ms", "hrv_rmssd")
            // Sleep-row fields for the same day.
            let s = sleepByDay[day]
            let score = s.flatMap {
                double($0, "score", "sleep_score", "sleep_performance",
                       "sleep_performance_pct", "sleep_score_pct")
            }
            let onset: Date? = s.flatMap {
                let tz = WhoopTime.offsetMinutes($0["cycle_timezone"])
                return WhoopTime.parse($0["sleep_onset"], offsetMinutes: tz)
                    ?? WhoopTime.parse($0["sleep_start"], offsetMinutes: tz)
            }
            let wake: Date? = s.flatMap {
                let tz = WhoopTime.offsetMinutes($0["cycle_timezone"])
                return WhoopTime.parse($0["wake_onset"], offsetMinutes: tz)
                    ?? WhoopTime.parse($0["sleep_end"], offsetMinutes: tz)
                    ?? WhoopTime.parse($0["wake_time"], offsetMinutes: tz)
                    ?? WhoopTime.parse($0["wake"], offsetMinutes: tz)
            }
            var tib = s.flatMap {
                double($0, "in_bed_duration_min", "time_in_bed_min",
                       "inbed_duration_min")
            }
            if tib == nil, let o = onset, let w = wake, w > o {
                tib = w.timeIntervalSince(o) / 60
            }
            guard rec != nil || str != nil || slp != nil || score != nil else {
                skipped += 1; continue  // row had a date but no usable scores
            }
            let (entry, isNew) = fetchOrCreate(day: day, context: context)
            var touched = false
            if let v = rec, entry.officialRecovery == nil {
                entry.officialRecovery = v; touched = true
            }
            if let v = str, entry.officialStrain == nil {
                entry.officialStrain = v; touched = true
            }
            if let v = slp, entry.officialSleepMinutes == nil {
                entry.officialSleepMinutes = v; touched = true
            }
            if let v = score, entry.officialSleepScore == nil {
                entry.officialSleepScore = v; touched = true; scoresFound += 1
            }
            if let o = onset, entry.sleepOnset == nil {
                entry.sleepOnset = o; touched = true
            }
            if let w = wake, entry.wakeTime == nil {
                entry.wakeTime = w; touched = true
            }
            if let v = tib, entry.timeInBedMinutes == nil {
                entry.timeInBedMinutes = v; touched = true
            }
            if let v = rhr, entry.rhrBpm == nil {
                entry.rhrBpm = v; touched = true
            }
            if let v = hrv, entry.hrvMs == nil {
                entry.hrvMs = v; touched = true
            }
            if isNew { paired += 1 } else if touched { updated += 1 }
        }
        try? context.save()
        var result = Result(paired: paired, updated: updated, skipped: skipped)
        result.sleepColumns = sleepCols
        result.cyclesColumns = cyclesCols
        result.sleepScoresFound = scoresFound
        return result
    }

    // MARK: helpers

    private static func double(_ m: [String: String],
                               _ keys: String...) -> Double? {
        for k in keys {
            if let s = m[k]?.trimmingCharacters(in: .whitespaces),
               !s.isEmpty, let v = Double(s) { return v }
        }
        return nil
    }

    private static func fetchOrCreate(day: Date,
                                      context: ModelContext)
        -> (BenchmarkEntry, Bool) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let desc = FetchDescriptor<BenchmarkEntry>(
            predicate: #Predicate {
                $0.entryDate >= start && $0.entryDate < end
            })
        if let found = try? context.fetch(desc).first {
            return (found, false)
        }
        let entry = BenchmarkEntry(entryDate: start)
        context.insert(entry)
        return (entry, true)
    }
}

// MARK: - SwiftUI: import button (DEBUG only)

/// Document-picker flow for the WHOOP export. The user unzips
/// my_whoop_data_*.zip in the Files app first, then picks the CSVs here.
struct WhoopImportView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var picking = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bulk import (WHOOP export)")
                .font(.headline)
            Text("Request your data export in the WHOOP app, unzip " +
                 "my_whoop_data_*.zip in Files, then pick " +
                 "physiological_cycles.csv (and sleeps.csv) here. " +
                 "Pairs every night automatically — nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Import WHOOP export…") { picking = true }
                .buttonStyle(.borderedProminent)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.commaSeparatedText],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var local: [URL] = []
                for url in urls where url.startAccessingSecurityScopedResource() {
                    local.append(url)
                }
                let r = WhoopExportImporter.importFiles(urls: local,
                                                        context: modelContext)
                for url in urls { url.stopAccessingSecurityScopedResource() }
                status = "Paired \(r.days) day\(r.days == 1 ? "" : "s")" +
                    (r.sleepScoresFound > 0 ? ", \(r.sleepScoresFound) with sleep scores" : "") +
                    (r.skipped > 0 ? " (\(r.skipped) rows skipped)" : "") + "."
            case .failure:
                status = "Import cancelled."
            }
        }
    }
}
#endif

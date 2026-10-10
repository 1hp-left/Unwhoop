import SwiftUI
import SwiftData
import Charts

// MARK: - TrendsView (PRD §6)
//
// Segmented 7D / 30D / 90D. Four charts, FIXED order:
// HRV with baseline band, Resting HR, Sleep duration (bars), Strain (bars).
// Charts are monochrome + one accent. Benchmark strip: DEV only, and only
// when paired data actually exists (PRD §5.6 — no dev UI in prod, no pleading).

private enum TrendRange: String, CaseIterable {
    case d7 = "7D"
    case d30 = "30D"
    case d90 = "90D"

    var days: Int {
        switch self {
        case .d7: 7
        case .d30: 30
        case .d90: 90
        }
    }
}

struct TrendsView: View {
    @Query(sort: \NightSummary.nightDate, order: .reverse) private var nights: [NightSummary]
    @Query(sort: \DaySummary.dayDate, order: .reverse) private var days: [DaySummary]
    #if DEBUG
    @Query(sort: \BenchmarkEntry.entryDate, order: .reverse) private var entries: [BenchmarkEntry]
    #endif

    @State private var range: TrendRange = .d30

    private var nightsInRange: [NightSummary] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: .now) ?? .distantPast
        return nights.filter { $0.nightDate >= cutoff }.sorted { $0.nightDate < $1.nightDate }
    }

    private var daysInRange: [DaySummary] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: .now) ?? .distantPast
        return days.filter { $0.dayDate >= cutoff }.sorted { $0.dayDate < $1.dayDate }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    #if DEBUG
                    BenchmarkStrip(nights: nights, days: days, entries: entries)
                    #endif

                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases, id: \.self) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)

                    if nightsInRange.isEmpty && daysInRange.isEmpty {
                        Text("Not enough data yet — check back after a few synced nights.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        HRVChart(nights: nightsInRange)
                        RHRChart(nights: nightsInRange)
                        SleepChart(nights: nightsInRange)
                        StrainChart(days: daysInRange)
                    }
                }
                .padding()
            }
            .navigationTitle("Trends")
        }
    }
}

// MARK: - HRV with baseline band

/// LnRMSSD line + the smallest-worthwhile-change band (mean ± 0.5 SD,
/// PRD §5.3). Display-only statistics over the visible window.
private struct HRVChart: View {
    let nights: [NightSummary]

    private var band: (mean: Double, lo: Double, hi: Double)? {
        let xs = nights.map(\.lnRMSSD)
        guard xs.count >= 2 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let variance = xs.map { pow($0 - mean, 2) }.reduce(0, +) / Double(xs.count)
        let sd = sqrt(variance)
        return (mean, mean - 0.5 * sd, mean + 0.5 * sd)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("HRV (LnRMSSD)")
                    .font(.headline)
                Chart {
                    if let band, let first = nights.first, let last = nights.last {
                        // Smallest-worthwhile-change band as a rectangle spanning
                        // the visible date range.
                        RectangleMark(
                            xStart: .value("Start", first.nightDate),
                            xEnd: .value("End", last.nightDate),
                            yStart: .value("Band low", band.lo),
                            yEnd: .value("Band high", band.hi)
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                    }
                    ForEach(nights, id: \.id) { night in
                        LineMark(
                            x: .value("Date", night.nightDate),
                            y: .value("LnRMSSD", night.lnRMSSD)
                        )
                        .foregroundStyle(.primary)
                        PointMark(
                            x: .value("Date", night.nightDate),
                            y: .value("LnRMSSD", night.lnRMSSD)
                        )
                        .foregroundStyle(.primary)
                    }
                }
                .frame(height: 180)
                .chartXAxis(.hidden)
            }
        }
    }
}

// MARK: - Resting HR

private struct RHRChart: View {
    let nights: [NightSummary]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Resting HR")
                    .font(.headline)
                Chart(nights, id: \.id) { night in
                    LineMark(
                        x: .value("Date", night.nightDate),
                        y: .value("BPM", night.restingHR)
                    )
                    .foregroundStyle(.primary)
                }
                .frame(height: 140)
                .chartXAxis(.hidden)
            }
        }
    }
}

// MARK: - Sleep duration bars

private struct SleepChart: View {
    let nights: [NightSummary]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sleep")
                    .font(.headline)
                Chart(nights, id: \.id) { night in
                    BarMark(
                        x: .value("Date", night.nightDate),
                        y: .value("Hours", night.totalSleepMinutes / 60)
                    )
                    .foregroundStyle(.primary.opacity(0.8))
                }
                .frame(height: 140)
                .chartXAxis(.hidden)
            }
        }
    }
}

// MARK: - Strain bars

private struct StrainChart: View {
    let days: [DaySummary]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Strain")
                    .font(.headline)
                Chart(days, id: \.id) { day in
                    BarMark(
                        x: .value("Date", day.dayDate),
                        y: .value("Strain", day.strain)
                    )
                    .foregroundStyle(.primary.opacity(0.8))
                }
                .frame(height: 140)
                .chartXAxis(.hidden)
                .chartYScale(domain: 0...21)
            }
        }
    }
}

// MARK: - Benchmark strip (DEBUG only)

#if DEBUG
/// Rendered only when paired data actually exists. Calls the real
/// BenchmarkStats API — implemented by the analytics workstream.
private struct BenchmarkStrip: View {
    let nights: [NightSummary]
    let days: [DaySummary]
    let entries: [BenchmarkEntry]

    private var recoveryPairs: [(Double, Double)] {
        entries.compactMap { entry in
            guard let official = entry.officialRecovery,
                  let night = nights.first(where: { Calendar.current.isDate($0.nightDate, inSameDayAs: entry.entryDate) }),
                  let score = night.recoveryScore
            else { return nil }
            return (score, official)
        }
    }

    var body: some View {
        if !recoveryPairs.isEmpty {
            let stats = BenchmarkStats.agreement(
                unwhoop: recoveryPairs.map(\.0),
                official: recoveryPairs.map(\.1)
            )
            HStack(spacing: 8) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Recovery: \(stats.stripLine)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
#endif

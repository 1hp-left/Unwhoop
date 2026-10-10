import SwiftUI
import SwiftData

// MARK: - TodayView (the morning glance, PRD §6)
//
// One primary number (recovery), then vitals, sleep, strain — glanceable in
// 5 seconds. Honest empty states before there's data; never a fake score.

struct TodayView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \NightSummary.nightDate, order: .reverse) private var nights: [NightSummary]
    @Query(sort: \DaySummary.dayDate, order: .reverse) private var days: [DaySummary]
    @Query private var syncRows: [SyncState]
    @Query private var settingsRows: [AppSettings]

    private var latestNight: NightSummary? { nights.first }
    private var today: DaySummary? { days.first }
    private var lastSync: Date? { syncRows.first?.lastSync }
    private var unit: TemperatureUnit { settingsRows.first?.temperatureUnit ?? .fahrenheit }

    /// Display-only rolling means for the delta arrows. The authoritative
    /// baselines live in the analytics pipeline (Baselines); this is a cheap
    /// O(7) display convenience, never a score input.
    private func recentMean(_ keyPath: KeyPath<NightSummary, Double>) -> Double? {
        let recent = nights.prefix(7)
        guard recent.count >= 2 else { return nil }
        return recent.map { $0[keyPath: keyPath] }.reduce(0, +) / Double(recent.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StaleBanner(lastSync: lastSync)

                    if nights.count < 7 {
                        BaselineCountdown(nightsSoFar: nights.count)
                    } else if let night = latestNight {
                        RecoveryCard(night: night)
                        VitalsRow(night: night, unit: unit,
                                  hrvBaseline: recentMean(\.lnRMSSD),
                                  rhrBaseline: recentMean(\.restingHR))
                        SleepCard(night: night)
                    }

                    if let today {
                        StrainCard(day: today)
                    }

                    if nights.isEmpty && days.isEmpty {
                        EmptyToday(onSync: { appState.sync.requestSync() })
                    }
                }
                .padding()
            }
            .navigationTitle(Date.now.formatted(date: .abbreviated, time: .omitted))
        }
    }
}

// MARK: - Baseline countdown

/// First 7 days: "Building baseline — N nights to go." No score until the
/// baseline exists (PRD §5.3).
private struct BaselineCountdown: View {
    let nightsSoFar: Int

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Building baseline")
                    .font(.headline)
                Text("\(nightsSoFar)/7 nights — your recovery score unlocks once the baseline exists.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(nightsSoFar), total: 7)
            }
        }
    }
}

// MARK: - Recovery card

private struct RecoveryCard: View {
    let night: NightSummary
    @State private var showBasis = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let score = night.recoveryScore, let band = night.recoveryBand {
                            Text(Format.percent(score))
                                .font(.system(size: 64, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.recoveryBand(band))
                            Text(band.label)
                                .font(.headline)
                                .foregroundStyle(Color.recoveryBand(band))
                        } else {
                            Text("—")
                                .font(.system(size: 64, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text("No score")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if night.lowConfidence {
                        LowConfidenceBadge(reason: night.confidenceReason)
                    }
                }

                if let basis = night.recoveryBasis {
                    Button {
                        showBasis = true
                    } label: {
                        Text(basis)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showBasis) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(night.recoveryBasis ?? "No basis recorded.")
                    if !night.confounderFlags.isEmpty {
                        Text("Flags tonight:")
                            .font(.headline)
                        ForEach(night.confounderFlags, id: \.rawValue) { flag in
                            Text("• \(flag.label)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if night.lowConfidence, let reason = night.confidenceReason {
                        Text("Low confidence: \(reason)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .navigationTitle("Why this score")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Overnight vitals row (exactly 4 tiles, PRD §6)

private struct VitalsRow: View {
    let night: NightSummary
    let unit: TemperatureUnit
    let hrvBaseline: Double?
    let rhrBaseline: Double?

    var body: some View {
        HStack(spacing: 8) {
            VitalTile(icon: "heart.fill", title: "HRV",
                      value: String(format: "%.0f ms", exp(night.lnRMSSD)),
                      delta: hrvBaseline.map { exp(night.lnRMSSD) - exp($0) }, deltaUnit: " ms")
            VitalTile(icon: "heart.pulse", title: "Resting HR",
                      value: String(format: "%.0f bpm", night.restingHR),
                      delta: rhrBaseline.map { night.restingHR - $0 }, deltaUnit: " bpm")
            VitalTile(icon: "lungs.fill", title: "Resp. rate",
                      value: night.respiratoryRate.map { String(format: "%.1f /min", $0) } ?? "—",
                      delta: nil, deltaUnit: "")
            VitalTile(icon: "thermometer", title: "Skin temp",
                      value: night.skinTempDeviation.map { unit.format(celsius: $0) } ?? "—",
                      delta: nil, deltaUnit: "")
        }
    }
}

// MARK: - Sleep card

private struct SleepCard: View {
    let night: NightSummary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(.secondary)
                    Text("Sleep")
                        .font(.headline)
                    Spacer()
                    Text("\(Format.hoursMinutes(night.totalSleepMinutes)) · \(Format.percent(night.sleepEfficiency * 100)) efficiency")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                StageBar(light: night.lightMinutes, deep: night.deepMinutes,
                         rem: night.remMinutes, wake: night.wakeMinutes)
                HStack {
                    Text("need: \(Format.hoursMinutes(night.sleepNeedMinutes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let onset = night.sleepOnset, let wake = night.wakeTime {
                        Text("\(onset.formatted(date: .omitted, time: .shortened)) – \(wake.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Known-bias disclosure (footnote, not a popup — PRD §5.4).
                Text("Wrist staging tends to read light sleep high, and deep sleep and awake time low — true of every wrist device.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Strain card

private struct StrainCard: View {
    let day: DaySummary
    @State private var pulse = false

    var body: some View {
        Card {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(.quaternary, lineWidth: 8)
                        .rotationEffect(.degrees(135))
                        .frame(width: 72, height: 72)
                    Circle()
                        .trim(from: 0, to: 0.75 * min(day.strain / 21, 1))
                        .stroke(.primary, lineWidth: 8)
                        .rotationEffect(.degrees(135))
                        .frame(width: 72, height: 72)
                    Text(String(format: "%.1f", day.strain))
                        .font(.title2.bold())
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Strain")
                            .font(.headline)
                        if day.isLive {
                            // LIVE dot — accent, never green/red (reserved for recovery).
                            Circle()
                                .fill(.accent)
                                .frame(width: 8, height: 8)
                                .opacity(pulse ? 0.4 : 1)
                                .onAppear {
                                    withAnimation(.easeInOut(duration: 1).repeatForever()) {
                                        pulse = true
                                    }
                                }
                            Text("LIVE")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("of 21 · updates through the day")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Empty state

private struct EmptyToday: View {
    let onSync: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "applewatch")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No data yet")
                    .font(.headline)
                Text("Sync your band and your first night will appear here in the morning.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sync now", action: onSync)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

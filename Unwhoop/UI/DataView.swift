import SwiftUI
import SwiftData
import Combine

// MARK: - DataView (PRD §6)
//
// Band card, benchmark entry (DEV only), export, and the ENTIRE settings
// surface: units, HealthKit toggle, reset baseline, about. Nothing else.

struct DataView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \NightSummary.nightDate, order: .reverse) private var nights: [NightSummary]
    @Query(sort: \DaySummary.dayDate, order: .reverse) private var days: [DaySummary]
    @Query private var syncRows: [SyncState]
    @Query private var settingsRows: [AppSettings]
    #if DEBUG
    @Query(sort: \BenchmarkEntry.entryDate, order: .reverse) private var entries: [BenchmarkEntry]
    #endif

    @State private var connection: ConnectionState = .disconnected
    @State private var cancellables = Set<AnyCancellable>()

    private var settings: AppSettings? { settingsRows.first }
    private var sync: SyncState? { syncRows.first }

    var body: some View {
        NavigationStack {
            List {
                Section("Band") {
                    BandCard(connection: connection,
                             battery: sync?.batteryPercent,
                             lastSync: sync?.lastSync,
                             deviceName: sync?.deviceName,
                             progress: appState.syncStatus,
                             lastMessage: sync?.lastSyncMessage,
                             onSync: { appState.requestSync() })
                }

                Section("Sync diagnostics") {
                    Text(sync?.historyMessage ?? "Waiting for a transfer to verify older history.")
                    Text(sync?.rrMessage ?? "No R-R diagnostic data yet.")
                    Text(sync?.scoringMessage ?? "Scores need sufficient overnight sensor coverage.")
                }
                .font(.caption)
                .foregroundStyle(AppTheme.muted)

                #if DEBUG
                Section("Benchmark entry (dev)") {
                    WhoopImportView()
                    Divider()
                    BenchmarkEntryForm()
                    BenchmarkHistory(entries: entries)
                    Divider()
                    SleepScoreTunerPanel(entries: entries, settings: settings)
                }
                #endif

                Section("Export") {
                    if let url = appState.latestRawExport {
                        ShareLink(item: url) {
                            Label("Export latest raw sync", systemImage: "square.and.arrow.up")
                        }
                    }
                    ExportRow(nights: nights, days: days)
                }

                Section("Settings") {
                    SettingsForm()
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unwhoop \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                            .font(.subheadline)
                        Text("Not a medical device. Scores are estimates from published methods, not clinical measurements.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Data")
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .toolbarBackground(AppTheme.background, for: .navigationBar)
            .onAppear {
                guard cancellables.isEmpty else { return }
                appState.sync.connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { connection = $0 }
                    .store(in: &cancellables)
            }
            .onDisappear { cancellables.removeAll() }
        }
    }
}

// MARK: - Band card

private struct BandCard: View {
    let connection: ConnectionState
    let battery: Int?
    let lastSync: Date?
    let deviceName: String?
    let progress: SyncProgress
    let lastMessage: String?
    let onSync: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "applewatch")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(deviceName ?? "WHOOP 5.0")
                        .font(.headline)
                    Text(connection.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let battery {
                    Label("\(battery)%", systemImage: "battery.75")
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            HStack {
                Text(lastSyncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Automatic", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(AppTheme.strain)
            }
            if let message = progress.label ?? lastMessage {
                HStack(alignment: .top, spacing: 8) {
                    if progress.isBusy { ProgressView().controlSize(.small) }
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            // Reinstall honesty (PRD §9): baseline rebuilds from zero; export first.
            Text("If you delete the app, the baseline rebuilds from zero. Export before deleting.")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
        }
        .padding(.vertical, 4)
    }

    private var lastSyncText: String {
        guard let lastSync else { return "Never synced" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Last sync \(f.localizedString(for: lastSync, relativeTo: Date()))"
    }
}

// MARK: - Benchmark entry (DEBUG only)

#if DEBUG
/// Manual fallback: three numbers, ten seconds (PRD §5.6).
private struct BenchmarkEntryForm: View {
    @Environment(\.modelContext) private var modelContext
    @State private var date: Date = .now
    @State private var recovery = ""
    @State private var strain = ""
    @State private var sleepMinutes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Date", selection: $date, displayedComponents: .date)
            HStack {
                TextField("Recovery %", text: $recovery)
                TextField("Strain", text: $strain)
                TextField("Sleep min", text: $sleepMinutes)
            }
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
            Button("Save official scores") {
                let entry = BenchmarkEntry(
                    entryDate: date,
                    officialRecovery: Double(recovery),
                    officialStrain: Double(strain),
                    officialSleepMinutes: Double(sleepMinutes)
                )
                modelContext.insert(entry)
                recovery = ""; strain = ""; sleepMinutes = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(Double(recovery) == nil && Double(strain) == nil && Double(sleepMinutes) == nil)
        }
        .padding(.vertical, 4)
    }
}

private struct BenchmarkHistory: View {
    let entries: [BenchmarkEntry]

    var body: some View {
        if entries.isEmpty {
            Text("No official scores entered yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries, id: \.id) { entry in
                HStack {
                    Text(entry.entryDate.formatted(date: .abbreviated, time: .omitted))
                    Spacer()
                    Text([
                        entry.officialRecovery.map { "R \($0, specifier: "%.0f")" },
                        entry.officialStrain.map { "S \($0, specifier: "%.1f")" },
                        entry.officialSleepMinutes.map { "Sl \($0, specifier: "%.0f")m" },
                    ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        }
    }
}
#endif

// MARK: - Export

/// Computed tier (default): per-day summaries + per-minute aggregates as
/// CSV/JSON. Kilobytes per year; exports in seconds. The app shows the
/// estimated size BEFORE exporting (PRD §5.7).
private struct ExportRow: View {
    let nights: [NightSummary]
    let days: [DaySummary]

    @State private var shareURL: URL?
    @State private var showShare = false

    private var csvBytes: Int { CSVExporter.estimatedBytes(nights: nights.count, days: days.count) }
    private var jsonBytes: Int { JSONExporter.estimatedBytes(nights: nights.count, days: days.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nights.isEmpty && days.isEmpty ? "No daily summaries to export yet. Downloaded sensor data is available through Export latest raw sync above." : "Export your daily summaries. Downloaded sensor data is available through Export latest raw sync above.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button { exportCSV() } label: {
                    Text("Export CSV").lineLimit(1).frame(maxWidth: .infinity)
                }
                    .buttonStyle(.bordered)
                Button { exportJSON() } label: {
                    Text("Export JSON").lineLimit(1).frame(maxWidth: .infinity)
                }
                    .buttonStyle(.bordered)
            }
            .disabled(nights.isEmpty && days.isEmpty)
            if !nights.isEmpty || !days.isEmpty {
                Text("≈ \(ByteCountFormatter.string(fromByteCount: Int64(max(csvBytes, jsonBytes)), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareSheet(url: shareURL)
            }
        }
    }

    private func exportCSV() {
        do {
            shareURL = try CSVExporter.computedCSV(nights: nights, days: days)
            showShare = true
        } catch {
            // TODO(ui): surface export errors with an alert once error UX is specced.
        }
    }

    private func exportJSON() {
        do {
            shareURL = try JSONExporter.computedJSON(nights: nights, days: days)
            showShare = true
        } catch {
            // TODO(ui): surface export errors with an alert once error UX is specced.
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Settings (the entire settings surface)

private struct SettingsForm: View {
    @Environment(AppState.self) private var appState
    @Query private var settingsRows: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @Query private var nights: [NightSummary]
    @Query private var days: [DaySummary]

    @State private var showResetConfirm = false
    @State private var healthKitDenied = false
    @State private var maxHRText = ""
    @State private var profileError: String?

    private var settings: AppSettings? { settingsRows.first }

    var body: some View {
        Group {
            if let settings {
                LabeledContent("Maximum heart rate") {
                    TextField("Not set", text: $maxHRText)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .accessibilityLabel("Maximum heart rate in beats per minute")
                }
                Picker("Physiology for strain", selection: Binding(
                    get: { settings.trainingSexRaw ?? "unset" },
                    set: { settings.trainingSexRaw = $0 == "unset" ? nil : $0; saveProfile() }
                )) {
                    Text("Not set").tag("unset")
                    Text("Male").tag(BiologicalSex.male.rawValue)
                    Text("Female").tag(BiologicalSex.female.rawValue)
                }
                Text("Set your maximum HR and physiology to enable strain. Resting HR is measured from quiet overnight data.")
                    .font(.caption).foregroundStyle(AppTheme.muted)
                Stepper(value: Binding(
                    get: { settings.sleepGoalMinutes / 60 },
                    set: { settings.sleepGoalMinutes = $0 * 60; saveProfile() }
                ), in: 6...10, step: 0.5) {
                    Text("Sleep target: \(settings.sleepGoalMinutes / 60, specifier: "%.1f") hours")
                }
                Picker("Units", selection: Binding(
                    get: { settings.temperatureUnit },
                    set: { settings.temperatureUnit = $0 }
                )) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                        Text(unit == .fahrenheit ? "Fahrenheit" : "Celsius").tag(unit)
                    }
                }

                Toggle("Write to Apple Health", isOn: Binding(
                    get: { settings.healthKitEnabled },
                    set: { newValue in
                        if newValue {
                            Task { await enableHealthKit(settings: settings) }
                        } else {
                            settings.healthKitEnabled = false
                        }
                    }
                ))
                if healthKitDenied {
                    Text("HealthKit access was denied — enable it in Settings → Health → Data Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reset baseline", role: .destructive) {
                    showResetConfirm = true
                }
                .confirmationDialog(
                    "Reset baseline?",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset — rebuilds from zero over 7 days", role: .destructive) {
                        for night in nights { modelContext.delete(night) }
                        for day in days { modelContext.delete(day) }
                        settings.baselineStartDate = .now
                        saveProfile()
                    }
                } message: {
                    Text("Deletes all nights and days. The 7-day baseline rebuilds from zero.")
                }
            }
        }
        .onAppear { maxHRText = settings?.maximumHeartRate.map { String(Int($0)) } ?? "" }
        .onChange(of: maxHRText) { _, value in
            guard let settings else { return }
            if value.isEmpty, settings.maximumHeartRate != nil { settings.maximumHeartRate = nil; saveProfile() }
            else if let number = Double(value), (80...240).contains(number) {
                guard settings.maximumHeartRate != number else { return }
                settings.maximumHeartRate = number; saveProfile()
            }
        }
        .alert("Could not save settings", isPresented: Binding(get: { profileError != nil }, set: { if !$0 { profileError = nil } })) {
            Button("OK") { profileError = nil }
        } message: { Text(profileError ?? "Please try again.") }
    }

    private func saveProfile() {
        do { try modelContext.save(); appState.refreshScores() }
        catch { modelContext.rollback(); profileError = error.localizedDescription }
    }

    private func enableHealthKit(settings: AppSettings) async {
        do {
            try await HealthKitWriter.shared.requestAuthorization()
            await MainActor.run { settings.healthKitEnabled = true }
        } catch {
            await MainActor.run { healthKitDenied = true }
        }
    }
}

// MARK: - Sleep score tuner (DEBUG only)

#if DEBUG
/// Fits SleepWeights against the imported WHOOP nights, on-device.
/// Shows the winning weights + fit quality; "Use these weights" stores them
/// in AppSettings for the production sleep score.
private struct SleepScoreTunerPanel: View {
    let entries: [BenchmarkEntry]
    var settings: AppSettings?
    @Environment(\.modelContext) private var modelContext
    @State private var result: SleepScoreTuner.FitResult?
    @State private var didRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sleep score tuner")
                .font(.headline)
            Text("Fits the sleep-score weights against your imported WHOOP nights, on this phone. Needs 7+ imported nights with sleep scores.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Fit weights") {
                result = SleepScoreTuner.fit(entries: entries)
                didRun = true
            }
            .buttonStyle(.bordered)
            if didRun {
                if let r = result {
                    let w = r.weights
                    Text("suff \(w.sufficiency, specifier: "%.2f") · eff \(w.efficiency, specifier: "%.2f") · con \(w.consistency, specifier: "%.2f") · rest \(w.restfulness, specifier: "%.2f")")
                        .font(.caption)
                        .monospacedDigit()
                    Text("RMSE \(r.rmse, specifier: "%.1f") (defaults \(r.defaultRmse, specifier: "%.1f")) · R² \(r.r2, specifier: "%.2f") · bias \(r.bias, specifier: "%+.1f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("\(r.nights) nights · vitals on \(Int((r.vitalsCoverage * 100).rounded()))% of nights")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if r.vitalsCoverage == 0 {
                        Text("No RHR/HRV in the export — restfulness weight pinned at default.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let s = settings {
                        Button("Use these weights") {
                            s.sleepScoreWeights = r.weights
                            try? modelContext.save()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("Not enough usable nights yet — import the WHOOP export first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
#endif

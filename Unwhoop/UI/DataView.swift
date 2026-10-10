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
                             onSync: { appState.sync.requestSync() })
                }

                #if DEBUG
                Section("Benchmark entry (dev)") {
                    WhoopImportView()
                    Divider()
                    BenchmarkEntryForm()
                    BenchmarkHistory(entries: entries)
                }
                #endif

                Section("Export") {
                    ExportRow(nights: nights, days: days)
                }

                Section("Settings") {
                    SettingsForm()
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unwhoop 1.0 (1)")
                            .font(.subheadline)
                        Text("Not a medical device. Scores are estimates from published methods, not clinical measurements.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Data")
            .onAppear {
                appState.sync.connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { connection = $0 }
                    .store(in: &cancellables)
            }
        }
    }
}

// MARK: - Band card

private struct BandCard: View {
    let connection: ConnectionState
    let battery: Int?
    let lastSync: Date?
    let deviceName: String?
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
                Button {
                    onSync()
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(connection == .syncing)
            }
            // Reinstall honesty (PRD §9): baseline rebuilds from zero; export first.
            Text("If you delete the app, the baseline rebuilds from zero. Export before deleting.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
            Text("Computed tier — daily summaries + per-minute aggregates. Raw tier (R-R, motion) is date-ranged and streams to disk; see Export in code.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Export CSV") { exportCSV() }
                    .buttonStyle(.bordered)
                Button("Export JSON") { exportJSON() }
                    .buttonStyle(.bordered)
                Spacer()
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
    @Query private var settingsRows: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @Query private var nights: [NightSummary]
    @Query private var days: [DaySummary]

    @State private var showResetConfirm = false
    @State private var healthKitDenied = false

    private var settings: AppSettings? { settingsRows.first }

    var body: some View {
        Group {
            if let settings {
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
                    }
                } message: {
                    Text("Deletes all nights and days. The 7-day baseline rebuilds from zero.")
                }
            }
        }
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

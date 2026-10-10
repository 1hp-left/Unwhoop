import SwiftUI
import SwiftData

// MARK: - UnwhoopApp

@main
struct UnwhoopApp: App {
    @State private var appState = AppState()
    let container: ModelContainer

    init() {
        // Schema: benchmark model exists in DEBUG only — the production
        // release contains no benchmark UI, entry screens, or comparison code.
        var types: [any PersistentModel.Type] = [
            NightSummary.self,
            DaySummary.self,
            SyncState.self,
            AppSettings.self,
        ]
        #if DEBUG
        types.append(BenchmarkEntry.self)
        #endif
        let schema = Schema(types)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("UnwhoopApp: could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .modelContainer(container)
                .preferredColorScheme(.dark) // dark-first (PRD §6)
        }
    }
}

// MARK: - RootView

/// First-run flow (PRD §6): one screen explaining the app + medical disclaimer
/// (must accept) + "Pair your WHOOP 5.0" button. After pairing, the three tabs.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Query private var settingsRows: [AppSettings]
    @Environment(\.modelContext) private var modelContext

    private var settings: AppSettings? { settingsRows.first }

    var body: some View {
        Group {
            if let settings, settings.onboardingComplete {
                MainTabs()
            } else {
                OnboardingView()
            }
        }
        .onAppear {
            if settingsRows.isEmpty {
                modelContext.insert(AppSettings())
            }
        }
    }
}

// MARK: - MainTabs

/// Exactly three tabs. No feed, no coach, no clutter (PRD §4/§6).
struct MainTabs: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
            DataView()
                .tabItem { Label("Data", systemImage: "externaldrive.fill") }
        }
    }
}

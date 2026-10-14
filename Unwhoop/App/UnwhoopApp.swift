import SwiftUI
import SwiftData

// MARK: - UnwhoopApp

@main
@MainActor
struct UnwhoopApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState
    let container: ModelContainer
    let backgroundSync: BackgroundSyncController

    init() {
        // Schema: benchmark model exists in DEBUG only — the production
        // release contains no benchmark UI, entry screens, or comparison code.
        var types: [any PersistentModel.Type] = [
            NightSummary.self,
            DaySummary.self,
            SyncState.self,
            AppSettings.self,
            SensorMinute.self,
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
        let state = AppState()
        state.configurePersistence(container.mainContext)
        _appState = State(initialValue: state)
        backgroundSync = BackgroundSyncController(state: state)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .modelContainer(container)
                .preferredColorScheme(.dark) // dark-first (PRD §6)
                .tint(AppTheme.strain)
                .onAppear { backgroundSync.becameActive() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { backgroundSync.becameActive() }
                    if phase == .background { backgroundSync.schedule() }
                }
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
            appState.configurePersistence(modelContext)
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
                .tabItem { Label("Home", systemImage: "house.fill") }
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
            DataView()
                .tabItem { Label("Data", systemImage: "externaldrive.fill") }
        }
        .toolbarBackground(AppTheme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

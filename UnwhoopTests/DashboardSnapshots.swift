import XCTest
import SwiftUI
import SwiftData
import Combine
@testable import Unwhoop

private final class SnapshotBand: BandSyncProtocol {
    let connectionState = CurrentValueSubject<ConnectionState, Never>(.connected)
    let discoveredBands = CurrentValueSubject<[BandDevice], Never>([])
    let syncProgress = CurrentValueSubject<SyncProgress, Never>(.idle)
    var onBatch: ((RawSampleBatch) -> Void)?
    func startScan() {}
    func stopScan() {}
    func connect(to device: BandDevice) {}
    func disconnect() {}
    func requestSync() {}
}

final class DashboardSnapshots: XCTestCase {
    @MainActor
    func testDashboardSnapshots() throws {
        let schema = Schema([AppSettings.self, SyncState.self, NightSummary.self, DaySummary.self, SensorMinute.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let state = AppState(sync: SnapshotBand())
        state.configurePersistence(container.mainContext)
        let link = SyncState(deviceName: "WHOOP 5.0", batteryPercent: 72)
        container.mainContext.insert(link)
        let settings = AppSettings()
        settings.disclaimerAccepted = true
        settings.pairedDeviceUUID = UUID().uuidString
        container.mainContext.insert(settings)
        try container.mainContext.save()
        try capture(TodayView().environment(state).modelContainer(container), name: "Home-empty", size: CGSize(width: 393, height: 852))
        state.requestSync()
        try capture(TodayView().environment(state).modelContainer(container), name: "Home-syncing-small", size: CGSize(width: 375, height: 667))
        try capture(DataView().environment(state).modelContainer(container), name: "Data-syncing", size: CGSize(width: 393, height: 852))
        // Illustrative fixtures are confined to tests; production never
        // creates scores to fill a ring or a screenshot.
        for offset in 0..<7 {
            let night = NightSummary(nightDate: Date().addingTimeInterval(Double(-offset) * 86_400),
                                     lnRMSSD: log(58), restingHR: 54, respiratoryRate: 14.8,
                                     totalSleepMinutes: 435, sleepEfficiency: 0.9,
                                     recoveryScore: 85, sleepScore: 74)
            night.recoveryBand = .recovered
            container.mainContext.insert(night)
        }
        container.mainContext.insert(DaySummary(dayDate: .now, strain: 14.2))
        try container.mainContext.save()
        try capture(TodayView().environment(state).modelContainer(container), name: "Home-illustrative-scores", size: CGSize(width: 393, height: 852))
    }

    @MainActor
    private func capture<V: View>(_ view: V, name: String, size: CGSize) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark).tint(AppTheme.strain))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
    }
}

import XCTest
import SwiftData
import Combine
@testable import Unwhoop

private final class FakeBandSync: BandSyncProtocol {
    let syncProgress = CurrentValueSubject<SyncProgress, Never>(.idle)
    let connectionState = CurrentValueSubject<ConnectionState, Never>(.connected)
    let discoveredBands = CurrentValueSubject<[BandDevice], Never>([])
    var onBatch: ((RawSampleBatch) -> Void)?
    var selected: BandDevice?
    var disconnects = 0
    func startScan() {}
    func stopScan() {}
    func connect(to device: BandDevice) { selected = device }
    func disconnect() { disconnects += 1 }
    func requestSync() {}
}

final class PairingTests: XCTestCase {
    private let band = BandDevice(id: UUID(), name: "WHOOP", rssi: -40)

    @MainActor
    func testReplayedConnectedStateDoesNotCompleteNewScreen() {
        let state = AppState(sync: FakeBandSync())
        XCTAssertEqual(state.sync.connectionState.value, .connected)
        XCTAssertFalse(state.acceptPairingConnection())
        XCTAssertFalse(state.pairingHandshakeComplete)
    }

    @MainActor
    func testSuccessRequiresSelectionAndIsHandledOnce() {
        let sync = FakeBandSync()
        let state = AppState(sync: sync)
        state.beginPairing(to: band)
        XCTAssertEqual(sync.selected, band)
        XCTAssertTrue(state.acceptPairingConnection())
        XCTAssertFalse(state.acceptPairingConnection())
    }

    @MainActor
    func testCancelledAttemptCannotCompleteAndRetryWorks() {
        let sync = FakeBandSync()
        let state = AppState(sync: sync)
        state.beginPairing(to: band)
        state.cancelPairing()
        XCTAssertEqual(sync.disconnects, 1)
        XCTAssertFalse(state.acceptPairingConnection())
        state.beginPairing(to: band)
        XCTAssertTrue(state.acceptPairingConnection())
    }

    @MainActor
    func testPairingPersistsBeforeOnboardingCompletes() throws {
        let schema = Schema([AppSettings.self, SyncState.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
        let context = ModelContext(container)
        let settings = AppSettings()
        settings.disclaimerAccepted = true
        context.insert(settings)
        try context.save()
        let state = AppState(sync: FakeBandSync())
        state.beginPairing(to: band)
        // Merely selecting a band cannot mark onboarding complete.
        try state.completePairing(settings: settings, context: context)
        XCTAssertFalse(settings.onboardingComplete)
        XCTAssertTrue(state.acceptPairingConnection())
        // Handshake alone must not remove the warning screen.
        XCTAssertFalse(settings.onboardingComplete)
        XCTAssertFalse(settings.pairingWarningShown)
        try state.completePairing(settings: settings, context: context)
        let reloaded = ModelContext(container)
        let saved = try XCTUnwrap(reloaded.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertTrue(saved.onboardingComplete)
        XCTAssertTrue(saved.pairingWarningShown)
        XCTAssertEqual(saved.pairedDeviceUUID, band.id.uuidString)
        let link = try XCTUnwrap(reloaded.fetch(FetchDescriptor<SyncState>()).first)
        XCTAssertEqual(link.deviceUUID, band.id.uuidString)
        XCTAssertEqual(link.deviceName, band.name)
        XCTAssertFalse(state.acceptPairingConnection())
    }
}

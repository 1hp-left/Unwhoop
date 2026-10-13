import Foundation
import Combine

// MARK: - Connection state
//
// Shown honestly in the UI: Connected / Syncing / Out of range / Band battery
// low / Last sync 14h ago (PRD §5.1). Never display a score computed from stale
// data without a visible stale banner — TodayView enforces that.

enum ConnectionState: String, Sendable {
    case disconnected
    case scanning
    case connecting
    case pairing
    case needsPairingMode
    case connected
    case syncing
    case outOfRange
    case lowBattery
    case invalidInstallation

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .pairing: "Pairing…"
        case .needsPairingMode: "Pairing mode needed"
        case .connected: "Connected"
        case .syncing: "Syncing…"
        case .outOfRange: "Out of range"
        case .lowBattery: "Band battery low"
        case .invalidInstallation: "Reinstall required: Bluetooth permission text missing"
        }
    }
}

// MARK: - Data types

struct BandDevice: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// One 5.0 motion frame. The 5.0 sends richer motion frames than the 4.0 —
/// activity class + step counter ride along (PRD §5.2) and feed sleep staging.
struct MotionFrame: Sendable, Codable {
    let date: Date
    let x: Double
    let y: Double
    let z: Double
    let activityClass: UInt8?
    let stepCount: UInt32?
}

/// One opportunistic sync delivery: everything the band offloaded since the
/// last sync. The pipeline ingests this exactly once per batch and caches
/// results — it never recomputes history (PRD §7).
struct RawSampleBatch: Sendable {
    let heartRates: [(date: Date, bpm: Double)]
    let rrIntervals: [(date: Date, seconds: Double)]
    let motionFrames: [MotionFrame]
    let skinTemperatures: [(date: Date, celsius: Double)]
    let batteryPercent: Int?
    /// True when this batch completes a sync session (drives "last sync" time).
    let isComplete: Bool
}

// MARK: - Narrow protocol

/// The ONLY interface the rest of the app programs against for band I/O
/// (PRD §5.1: wrap Noop's BLE layer behind a narrow Swift protocol so the sync
/// engine can be swapped without touching analytics or UI).
///
/// Zero network calls. Everything here is CoreBluetooth-local.
protocol BandSyncProtocol: AnyObject {
    var syncProgress: CurrentValueSubject<SyncProgress, Never> { get }
    /// Current connection state; UI subscribes directly.
    var connectionState: CurrentValueSubject<ConnectionState, Never> { get }
    /// Bands seen during the current scan (pairing flow).
    var discoveredBands: CurrentValueSubject<[BandDevice], Never> { get }
    /// Called on a background queue with each offloaded batch.
    var onBatch: ((RawSampleBatch) -> Void)? { get set }

    func startScan()
    func stopScan()
    func connect(to device: BandDevice)
    func disconnect()
    /// Opportunistic sync: connect (if needed), burst-download everything new,
    /// disconnect. No continuous foreground BLE — connect, burst, disconnect
    /// (PRD §7 battery budget).
    func requestSync()
}

enum SyncProgress: Equatable, Sendable {
    case idle
    case connecting
    case receiving(records: Int)
    case saving
    case completed(samples: Int, complete: Bool)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .receiving, .saving: true
        default: false
        }
    }

    var label: String? {
        switch self {
        case .idle: nil
        case .connecting: "Connecting to your band…"
        case .receiving(let records): "Receiving history: \(records) records…"
        case .saving: "Saving received data…"
        case .completed(let samples, let complete):
            samples == 0
                ? (complete ? "Sync complete — no new samples on the band." : "No samples received. Sync was interrupted; try again.")
                : (complete ? "Sync complete — \(samples) samples saved." : "Sync interrupted — \(samples) samples saved. Tap Sync now to continue.")
        case .failed(let reason): reason
        }
    }
}

/// Only the first command write is the hello. Later write acknowledgements
/// must not restart the handshake or issue another battery request.
struct BandSessionReadiness {
    let requiredNotifications: Set<String>
    private(set) var helloAccepted = false
    private var subscribed: Set<String> = []
    private var announced = false

    var isReady: Bool { helloAccepted && requiredNotifications.isSubset(of: subscribed) }

    mutating func acceptHello() -> Bool {
        guard !helloAccepted else { return false }
        helloAccepted = true
        return true
    }

    mutating func notificationChanged(_ id: String, enabled: Bool) {
        if enabled { subscribed.insert(id) } else { subscribed.remove(id) }
    }

    mutating func takeReadyTransition() -> Bool {
        guard isReady, !announced else { return false }
        announced = true
        return true
    }
}

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
    var diagnostics: SyncDiagnostics? = nil
}

struct SyncDiagnostics: Codable, Sendable {
    var startedAt: Date
    var historyCommandSent: Bool
    var historyStartMarkers: Int
    var historyCompleteSeen: Bool
    var historicalRecords: Int
    var realtimeRecords: Int
    var lastRRNotificationAt: Date?
    var lastRRSampleAt: Date?
    var rrValuesReceived: Int
    var notificationStates: [String: Bool]
    var lastNotificationAt: [String: Date]
    var journalFile: String? = nil
    var rrLastNotificationByChannel: [String: Date] = [:]
    var stopReason: SyncStopReason? = nil
    var recordBudget: Int? = nil
}

enum SyncStopReason: String, Codable, Sendable {
    case complete, recordBudget, timeBudget, quietTimeout, disconnected, requestedStop, lowBattery, storageFailure, commandFailure

    var isBudgetPause: Bool { self == .recordBudget || self == .timeBudget }
    var explanation: String {
        switch self {
        case .complete: "The band finished its history transfer."
        case .recordBudget: "The battery record budget was reached. Charging with Low Power Mode off allows full offload."
        case .timeBudget: "The transfer time budget was reached."
        case .quietTimeout: "The band stopped sending data for 60 seconds."
        case .disconnected: "The Bluetooth connection dropped."
        case .requestedStop: "The transfer was stopped by the app or its background time expired."
        case .lowBattery: "Band battery is below 10%."
        case .storageFailure: "Received history could not be written to storage."
        case .commandFailure: "The band rejected a history command or acknowledgement."
        }
    }
}

/// A bounded transfer must finish its current bank and receive the ACK write
/// confirmation before another history request can start on the same link.
struct HistoryTransferBoundary {
    private(set) var hasOpenBank = false
    private(set) var pauseRequested = false
    private(set) var pendingAcknowledgements = 0
    private(set) var completeReceived = false
    private var pauseAtAcknowledgement = false

    mutating func requestPause(hasOpenBank: Bool) -> Bool {
        pauseRequested = true
        if pendingAcknowledgements > 0 { pauseAtAcknowledgement = true }
        return !hasOpenBank && pendingAcknowledgements == 0
    }
    mutating func bankStarted() { hasOpenBank = true }
    mutating func bankEnded() {
        hasOpenBank = false
        pendingAcknowledgements += 1
        if pauseRequested { pauseAtAcknowledgement = true }
    }
    mutating func acknowledged() -> Bool {
        pendingAcknowledgements = max(0, pendingAcknowledgements - 1)
        return pendingAcknowledgements == 0 && (pauseAtAcknowledgement || completeReceived)
    }
    mutating func completed() -> Bool {
        completeReceived = true
        return pendingAcknowledgements == 0
    }
}

// MARK: - Narrow protocol

/// The ONLY interface the rest of the app programs against for band I/O
/// (PRD §5.1: wrap Noop's BLE layer behind a narrow Swift protocol so the sync
/// engine can be swapped without touching analytics or UI).
///
/// Zero network calls. Everything here is CoreBluetooth-local.
protocol BandSyncProtocol: AnyObject {
    func configureAutomaticSync(enabled: Bool, maximumRecords: Int)
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
    /// Connect if needed and request a bounded history transfer. A normal
    /// completion preserves the bonded link for subsequent automatic work.
    func requestSync()
}

enum SyncProgress: Equatable, Sendable {
    case idle
    case connecting
    case receiving(records: Int)
    case saving
    case completed(samples: Int, complete: Bool)
    case failed(String)
    case waitingForData
    case deferred(String)
    case paused(samples: Int, reason: String)

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
        case .receiving(let records): "Receiving sensor data: \(records) records…"
        case .saving: "Saving received data…"
        case .completed(let samples, let complete):
            samples == 0
                ? (complete ? "Waiting for sensor data — nothing was received." : "No samples received. Sync was interrupted; try again.")
                : (complete ? "Sync complete — \(samples) samples saved." : "Sync interrupted — \(samples) samples saved. Automatic sync will continue later.")
        case .failed(let reason): reason
        case .waitingForData: "Waiting for sensor data — nothing was received."
        case .deferred(let reason): reason
        case .paused(let samples, let reason): "Sync paused — \(samples) samples saved. \(reason)"
        }
    }
}

extension BandSyncProtocol {
    func configureAutomaticSync(enabled: Bool, maximumRecords: Int) {}
}

/// Only the first command write is the hello. Later write acknowledgements
/// must not restart the handshake or issue another battery request.
struct BandSessionReadiness {
    let requiredNotifications: Set<String>
    private(set) var helloAccepted = false
    private var subscribed: Set<String> = []
    private var announced = false

    init(requiredNotifications: Set<String>) {
        self.requiredNotifications = requiredNotifications
    }

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

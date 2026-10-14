import Foundation
import UIKit
import BackgroundTasks
import Combine
import OSLog

struct AutomaticSyncPolicy {
    static func recordBudget(charging: Bool, lowPower: Bool) -> Int {
        charging && !lowPower ? Int.max : 300
    }
    static func retryInterval(charging: Bool, lowPower: Bool) -> TimeInterval {
        lowPower ? 4 * 3600 : (charging ? 30 * 60 : 60 * 60)
    }
}

/// iOS decides launch timing. Charging processing requests complement the
/// CoreBluetooth restoration path; neither is an exact overnight alarm.
@MainActor
final class BackgroundSyncController {
    static let identifier = "com.unwhoop.offload"
    private let state: AppState
    private var activeTask: BGProcessingTask?
    private var subscriptions = Set<AnyCancellable>()
    private var retryTimer: Timer?
    private let logger = Logger(subsystem: "com.unwhoop.app", category: "BackgroundSync")
    private let lastAttemptKey = "com.unwhoop.auto.lastAttempt"
    private var previousCharging = false
    private var configuredBudget: Int?

    init(state: AppState) {
        self.state = state
        UIDevice.current.isBatteryMonitoringEnabled = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { [weak self] task in
            DispatchQueue.main.async {
                guard let self, let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                self.handle(processing)
            }
        }
        state.sync.syncProgress.receive(on: DispatchQueue.main).sink { [weak self] progress in
            if case .receiving(let records) = progress, records == 0 {
                if let self { UserDefaults.standard.set(Date(), forKey: self.lastAttemptKey) }
            }
            if case .failed = progress { self?.finishActive(success: false) }
            if case .deferred = progress { self?.finishActive(success: false) }
        }.store(in: &subscriptions)
        state.onSyncFinished = { [weak self] success in self?.finishActive(success: success) }
        NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.becameActive() }.store(in: &subscriptions)
        // AppState's persisted completion is observed rather than treating
        // the end of the BLE stream as completion before analytics saves.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        configurePower()
        previousCharging = charging
        schedule()
    }

    private var charging: Bool { UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full }
    private var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || (UIDevice.current.batteryLevel >= 0 && UIDevice.current.batteryLevel < 0.2) }

    private func configurePower() {
        let budget = AutomaticSyncPolicy.recordBudget(charging: charging, lowPower: lowPower)
        guard configuredBudget != budget else { return }
        configuredBudget = budget
        state.sync.configureAutomaticSync(enabled: true, maximumRecords: budget)
    }

    func becameActive(foregroundActivation: Bool = true) {
        configurePower()
        if foregroundActivation { schedule() }
        guard state.hasPairedBand, !state.syncStatus.isBusy else { return }
        let last = UserDefaults.standard.object(forKey: lastAttemptKey) as? Date ?? .distantPast
        let escalation = charging && !previousCharging && !lowPower
        previousCharging = charging
        let interval = foregroundActivation && !lowPower ? 5 * 60 : AutomaticSyncPolicy.retryInterval(charging: charging, lowPower: lowPower)
        guard escalation || Date().timeIntervalSince(last) >= interval else { return }
        UserDefaults.standard.set(Date(), forKey: lastAttemptKey)
        state.requestSync()
    }

    private func tick() {
        if activeTask != nil {
            switch state.syncStatus {
            case .completed(_, let complete): finishActive(success: complete)
            case .waitingForData, .failed, .deferred: finishActive(success: false)
            default: break
            }
        }
        if UIApplication.shared.applicationState == .active { becameActive(foregroundActivation: false) }
    }

    func schedule() {
        guard state.hasPairedBand else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date().addingTimeInterval(lowPower ? 4 * 3600 : 30 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { logger.info("Background request unavailable: \(error.localizedDescription, privacy: .public)") }
    }

    private func handle(_ task: BGProcessingTask) {
        activeTask = task
        schedule()
        guard state.hasPairedBand, !lowPower else { finishActive(success: false); return }
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.state.sync.disconnect()
                self?.finishActive(success: false)
            }
        }
        // The scheduler grants this request only while external power exists.
        configuredBudget = Int.max
        state.sync.configureAutomaticSync(enabled: true, maximumRecords: Int.max)
        UserDefaults.standard.set(Date(), forKey: lastAttemptKey)
        state.requestSync()
    }

    private func finishActive(success: Bool) {
        guard let task = activeTask else { return }
        activeTask = nil
        task.setTaskCompleted(success: success)
    }
}

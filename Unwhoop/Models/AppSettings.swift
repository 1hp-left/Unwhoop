import Foundation
import SwiftData

/// Singleton app settings. The app keeps exactly one row, created on first launch.
@Model
final class AppSettings {
    @Attribute(.unique) var id: UUID

    var temperatureUnitRaw: String // TemperatureUnit raw value
    var healthKitEnabled: Bool     // off by default (PRD §5.7)

    // First-run flow
    var disclaimerAccepted: Bool
    var pairedDeviceUUID: String?
    /// The "never open the official WHOOP app against the same band" warning
    /// is shown ONCE at pairing, then never again (PRD §7).
    var pairingWarningShown: Bool

    // Baseline bookkeeping
    var baselineStartDate: Date?

    // Sleep-score weights, fitted on-device by the dev-only tuner against the
    // user's WHOOP export (or the shipped defaults until then).
    var sleepScoreWeightsRaw: [Double]

    var sleepScoreWeights: SleepWeights {
        get { SleepWeights.from(array: sleepScoreWeightsRaw) }
        set { sleepScoreWeightsRaw = newValue.normalized.array }
    }

    var temperatureUnit: TemperatureUnit {
        get { TemperatureUnit(rawValue: temperatureUnitRaw) ?? .fahrenheit }
        set { temperatureUnitRaw = newValue.rawValue }
    }

    var isPaired: Bool { pairedDeviceUUID != nil }
    var onboardingComplete: Bool { disclaimerAccepted && isPaired }

    init() {
        self.id = UUID()
        self.temperatureUnitRaw = TemperatureUnit.fahrenheit.rawValue
        self.healthKitEnabled = false
        self.disclaimerAccepted = false
        self.pairedDeviceUUID = nil
        self.pairingWarningShown = false
        self.baselineStartDate = nil
        self.sleepScoreWeightsRaw = SleepWeights.default.array
    }
}

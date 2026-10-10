import Foundation

// Shared value types used by the SwiftData models and the analytics API.
// Kept free of SwiftUI so models and analytics stay UI-independent.

/// Recovery band thresholds per PRD §5.3: 67–100 green, 34–66 yellow, 0–33 red.
enum RecoveryBand: String, Codable, CaseIterable, Sendable {
    case recovered
    case payAttention
    case rest

    var label: String {
        switch self {
        case .recovered: "Recovered"
        case .payAttention: "Pay attention"
        case .rest: "Rest"
        }
    }

    static func band(for score: Double) -> RecoveryBand {
        switch score {
        case 67...100: .recovered
        case 34...66: .payAttention
        default: .rest
        }
    }
}

/// Confounder flags per PRD §5.3. These move the *display*, never the baseline.
enum ConfounderFlag: String, Codable, CaseIterable, Sendable {
    case alcoholSignature
    case illnessSignature
    case lutealPattern

    var label: String {
        switch self {
        case .alcoholSignature: "Possible alcohol effect (HRV down, RHR up)"
        case .illnessSignature: "Possible illness (RHR elevated, HRV suppressed)"
        case .lutealPattern: "Possible luteal-phase pattern"
        }
    }
}

/// 30-second sleep epoch stages per PRD §5.4.
enum SleepStage: String, Codable, CaseIterable, Sendable {
    case wake
    case light
    case deep
    case rem

    var label: String {
        switch self {
        case .wake: "Awake"
        case .light: "Light"
        case .deep: "Deep"
        case .rem: "REM"
        }
    }
}

/// Biological sex selects the Banister TRIMP weighting constant (PRD §5.5):
/// Y = 0.64·e^(1.92·x) male / 0.86·e^(1.67·x) female.
/// OPEN: the PRD does not say where this comes from — the v1 settings surface
/// is fixed (units, HealthKit toggle, reset baseline, about), so the pipeline
/// carries it on the input until the source is decided. See BUILD_NOTES.md.
enum BiologicalSex: String, Codable, Sendable {
    case male
    case female
}

enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case fahrenheit
    case celsius

    var label: String {
        switch self {
        case .fahrenheit: "°F"
        case .celsius: "°C"
        }
    }

    func format(celsius: Double) -> String {
        switch self {
        case .fahrenheit: String(format: "%.1f°F", celsius * 9 / 5 + 32)
        case .celsius: String(format: "%.1f°C", celsius)
        }
    }
}

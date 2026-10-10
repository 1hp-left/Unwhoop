import Foundation
import SwiftData

/// One night of computed results. Written once per night by the analytics
/// pipeline (exactly once per new data batch, then cached — never recomputed
/// on launch or per screen, per PRD §7). Kept forever.
@Model
final class NightSummary {
    @Attribute(.unique) var id: UUID

    /// Local calendar day the night belongs to (the morning you wake up).
    var nightDate: Date

    // Overnight vitals (from the deepest-sleep window, per PRD §5.3)
    var lnRMSSD: Double          // ms, natural log of RMSSD
    var restingHR: Double        // bpm
    var respiratoryRate: Double? // breaths/min, estimated from R-R/RSA (no raw stream on 5.0)
    var skinTempDeviation: Double? // °C vs personal baseline; nil until baseline exists

    // Sleep (30-second epochs staged by SleepStager)
    var sleepOnset: Date?
    var wakeTime: Date?
    var totalSleepMinutes: Double
    var sleepEfficiency: Double  // 0–1
    var lightMinutes: Double
    var deepMinutes: Double
    var remMinutes: Double
    var wakeMinutes: Double
    var sleepNeedMinutes: Double // computed sleep need; pipeline-owned (see BUILD_NOTES)

    // Recovery
    var recoveryScore: Double?   // 0–100; nil until the 7-day baseline exists
    var recoveryBandRaw: String? // RecoveryBand raw value
    var recoveryBasis: String?   // one-line basis, e.g. "LnRMSSD 58ms vs your 54ms baseline"

    // Quality
    var lowConfidence: Bool
    var confidenceReason: String?
    var confounderFlagsRaw: [String] // ConfounderFlag raw values

    var recoveryBand: RecoveryBand? {
        get { recoveryBandRaw.flatMap(RecoveryBand.init(rawValue:)) }
        set { recoveryBandRaw = newValue?.rawValue }
    }

    var confounderFlags: [ConfounderFlag] {
        get { confounderFlagsRaw.compactMap(ConfounderFlag.init(rawValue:)) }
        set { confounderFlagsRaw = newValue.map(\.rawValue) }
    }

    init(
        nightDate: Date,
        lnRMSSD: Double,
        restingHR: Double,
        respiratoryRate: Double? = nil,
        skinTempDeviation: Double? = nil,
        sleepOnset: Date? = nil,
        wakeTime: Date? = nil,
        totalSleepMinutes: Double = 0,
        sleepEfficiency: Double = 0,
        lightMinutes: Double = 0,
        deepMinutes: Double = 0,
        remMinutes: Double = 0,
        wakeMinutes: Double = 0,
        sleepNeedMinutes: Double = 0,
        recoveryScore: Double? = nil,
        recoveryBasis: String? = nil,
        lowConfidence: Bool = false,
        confidenceReason: String? = nil
    ) {
        self.id = UUID()
        self.nightDate = nightDate
        self.lnRMSSD = lnRMSSD
        self.restingHR = restingHR
        self.respiratoryRate = respiratoryRate
        self.skinTempDeviation = skinTempDeviation
        self.sleepOnset = sleepOnset
        self.wakeTime = wakeTime
        self.totalSleepMinutes = totalSleepMinutes
        self.sleepEfficiency = sleepEfficiency
        self.lightMinutes = lightMinutes
        self.deepMinutes = deepMinutes
        self.remMinutes = remMinutes
        self.wakeMinutes = wakeMinutes
        self.sleepNeedMinutes = sleepNeedMinutes
        self.recoveryScore = recoveryScore
        if let recoveryScore { self.recoveryBandRaw = RecoveryBand.band(for: recoveryScore).rawValue }
        self.recoveryBasis = recoveryBasis
        self.lowConfidence = lowConfidence
        self.confidenceReason = confidenceReason
        self.confounderFlagsRaw = []
    }
}

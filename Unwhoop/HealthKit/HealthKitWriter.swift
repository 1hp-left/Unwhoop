import Foundation
import HealthKit

// MARK: - HealthKitWriter
//
// Optional, OFF by default (PRD §5.7). Writes heart rate, HRV, sleep analysis,
// and respiratory rate. READS NOTHING — the read set passed to HealthKit is
// empty, by design.
//
// HRV note: HealthKit defines an SDNN quantity type
// (heartRateVariabilitySDNN) but NO RMSSD type. Unwhoop's pipeline works in
// LnRMSSD, so v1 does not write HRV unless an SDNN value is explicitly
// supplied — writing RMSSD numbers under an SDNN label would be mislabeled
// data, and we don't ship numbers we can't stand behind.

final class HealthKitWriter {
    static let shared = HealthKitWriter()

    private let store = HKHealthStore()

    private init() {}

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Requests write-only authorization. Throws if HealthKit is unavailable
    /// or the user denies access.
    func requestAuthorization() async throws {
        guard isAvailable else {
            throw HealthKitError.unavailable
        }
        let toShare: Set<HKSampleType> = Set([
            HKQuantityType(.heartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.respiratoryRate),
            HKCategoryType(.sleepAnalysis),
        ].compactMap { $0 })
        // READ NOTHING: empty read set is deliberate.
        try await store.requestAuthorization(toShare: toShare, read: [])
    }

    /// Writes heart-rate samples (bpm).
    func saveHeartRate(_ samples: [(date: Date, bpm: Double)]) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let hkSamples = samples.map { (date, bpm) in
            HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: bpm),
                             start: date, end: date)
        }
        try await store.save(hkSamples)
    }

    /// Writes SDNN HRV samples (ms). See the header note: RMSSD is never
    /// written under this label.
    func saveHRVSDNN(_ samples: [(date: Date, sdnnMilliseconds: Double)]) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return }
        let unit = HKUnit.secondUnit(with: .milli)
        let hkSamples = samples.map { (date, ms) in
            HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: ms),
                             start: date, end: date)
        }
        try await store.save(hkSamples)
    }

    /// Writes respiratory-rate samples (breaths/min).
    func saveRespiratoryRate(_ samples: [(date: Date, breathsPerMinute: Double)]) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let hkSamples = samples.map { (date, bpm) in
            HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: bpm),
                             start: date, end: date)
        }
        try await store.save(hkSamples)
    }

    /// Writes sleep analysis: one asleep sample per contiguous staged-sleep
    /// block, plus in-bed time.
    func saveSleep(asleepIntervals: [DateInterval], inBed: DateInterval) async throws {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        var hkSamples: [HKCategorySample] = [
            HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                             start: inBed.start, end: inBed.end)
        ]
        hkSamples += asleepIntervals.map {
            HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                             start: $0.start, end: $0.end)
        }
        try await store.save(hkSamples)
    }
}

enum HealthKitError: Error {
    case unavailable
    case denied
}

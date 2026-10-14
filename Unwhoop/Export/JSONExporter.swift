import Foundation

// MARK: - JSONExporter
//
// Computed tier as JSON: same content as the CSV tier, structured for
// research agents and scripts (PRD §5.7). Deterministic key order and
// formatting — same input produces byte-identical output every run.

enum JSONExporter {
    struct NightJSON: Codable {
        var date: Date
        var lnRMSSD: Double?
        var restingHR: Double?
        var sleepScore: Double?
        var rrArtifactFraction: Double
        var rrCoverage: Double
        var respiratoryRate: Double?
        var skinTempDeviationC: Double?
        var sleepOnset: Date?
        var wakeTime: Date?
        var totalSleepMinutes: Double
        var sleepEfficiency: Double
        var lightMinutes: Double
        var deepMinutes: Double
        var remMinutes: Double
        var wakeMinutes: Double
        var sleepNeedMinutes: Double
        var recoveryScore: Double?
        var recoveryBand: String?
        var recoveryBasis: String?
        var lowConfidence: Bool
        var confidenceReason: String?
        var confounderFlags: [String]
    }

    struct DayJSON: Codable {
        var date: Date
        var strain: Double?
        var trimpLoad: Double
        var minuteTRIMP: [Double]
        var isLive: Bool
    }

    struct ExportJSON: Codable {
        var exportedAt: Date
        var app: String = "Unwhoop"
        var tier: String = "computed"
        var nights: [NightJSON]
        var days: [DayJSON]
    }

    /// Writes the computed-tier JSON to a temp file and returns its URL.
    static func computedJSON(nights: [NightSummary], days: [DaySummary]) throws -> URL {
        let payload = ExportJSON(
            exportedAt: Date(),
            nights: nights.sorted { $0.nightDate < $1.nightDate }.map(nightJSON),
            days: days.sorted { $0.dayDate < $1.dayDate }.map(dayJSON)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unwhoop-computed-\(Date().timeIntervalSince1970).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Pre-export size estimate for the UI.
    static func estimatedBytes(nights: Int, days: Int) -> Int {
        // ~700 bytes/night (incl. basis strings) + ~12 KB/day of minute TRIMP.
        700 * nights + 12_500 * days + 200
    }

    // MARK: - Private

    private static func nightJSON(_ n: NightSummary) -> NightJSON {
        NightJSON(
            date: n.nightDate, lnRMSSD: n.hrvAvailable ? n.lnRMSSD : nil, restingHR: n.restingHRAvailable ? n.restingHR : nil,
            sleepScore: n.sleepScore, rrArtifactFraction: n.rrArtifactFraction, rrCoverage: n.rrCoverage,
            respiratoryRate: n.respiratoryRate, skinTempDeviationC: n.skinTempDeviation,
            sleepOnset: n.sleepOnset, wakeTime: n.wakeTime,
            totalSleepMinutes: n.totalSleepMinutes, sleepEfficiency: n.sleepEfficiency,
            lightMinutes: n.lightMinutes, deepMinutes: n.deepMinutes,
            remMinutes: n.remMinutes, wakeMinutes: n.wakeMinutes,
            sleepNeedMinutes: n.sleepNeedMinutes,
            recoveryScore: n.recoveryScore, recoveryBand: n.recoveryBandRaw,
            recoveryBasis: n.recoveryBasis,
            lowConfidence: n.lowConfidence, confidenceReason: n.confidenceReason,
            confounderFlags: n.confounderFlagsRaw
        )
    }

    private static func dayJSON(_ d: DaySummary) -> DayJSON {
        DayJSON(date: d.dayDate, strain: d.strainAvailable ? d.strain : nil, trimpLoad: d.trimpLoad,
                minuteTRIMP: d.minuteTRIMP, isLive: d.isLive)
    }
}

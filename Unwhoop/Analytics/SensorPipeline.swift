import Foundation
import SwiftData

struct RRWindowQuality {
    let clean: [Double]
    let cleanCount: Int
    let coverage: Double
    let artifactFraction: Double
    let reason: String?
    var isUsable: Bool { reason == nil }

    static func evaluate(_ values: [StoredSyncBatch.Value], window: DateInterval, minimumClean: Int = 120) -> RRWindowQuality {
        let ordered = values.filter { $0.date >= window.start && $0.date < window.end }.sorted { $0.date < $1.date }
        let result = RRAnalysis.cleanRR(ordered.map { $0.value * 1000 })
        let count = result.cleaned.count - result.nRemoved
        let coveredDuration = result.cleaned.filter { $0.isFinite && $0 > 0 }.reduce(0, +) / 1000 / max(window.duration, 1)
        let coverage = min(1, coveredDuration)
        let dates = Array(Set(ordered.map(\.date))).sorted()
        let between = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? window.duration
        let edge = max(dates.first?.timeIntervalSince(window.start) ?? window.duration,
                       window.end.timeIntervalSince(dates.last ?? window.start))
        let gap = max(between, edge)
        let reason: String?
        if ordered.isEmpty { reason = "No R-R intervals received for this window." }
        else if result.lowConfidence { reason = String(format: "R-R artifacts %.0f%% exceed the 15%% limit.", result.artifactFraction * 100) }
        else if count < minimumClean { reason = "Only \(count) clean R-R intervals; at least \(minimumClean) required." }
        else if coveredDuration > 1.2 { reason = "R-R timing exceeds the window duration; possible duplicated packets." }
        else if coverage < 0.8 || gap > 10 { reason = "R-R coverage is incomplete or has gaps longer than 10 seconds." }
        else { reason = nil }
        return RRWindowQuality(clean: result.cleaned, cleanCount: count, coverage: coverage,
                               artifactFraction: result.artifactFraction, reason: reason)
    }

    var lnRMSSD: Double? {
        guard isUsable else { return nil }
        let value = RRAnalysis.lnRMSSD(clean)
        return value.isFinite ? value : nil
    }
}

struct ScoringReport {
    var acceptedSamples: Int
    var message: String
    var history: String
    var rr: String
}

/// Invoked on AppState's serial processing queue; its ModelContext never
/// crosses queues. Raw pages are persisted before summary calculations.
final class SensorPipeline {
    private let container: ModelContainer
    private let calendar: Calendar
    init(container: ModelContainer, calendar: Calendar = .current) {
        self.container = container
        self.calendar = calendar
    }

    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    func ingest(_ batch: RawSampleBatch, now: Date = .now) throws -> ScoringReport {
        let context = ModelContext(container)
        var pages: [Date: MinuteSignals] = [:]
        let oldestAllowed = now.addingTimeInterval(-14 * 86_400)
        func validDate(_ date: Date) -> Bool { date >= oldestAllowed && date <= now.addingTimeInterval(60) }
        for value in batch.heartRates where validDate(value.date) && value.bpm.isFinite && (30...240).contains(value.bpm) {
            pages[Self.minute(value.date), default: MinuteSignals()].hr.append(.init(date: value.date, value: value.bpm))
        }
        for value in batch.rrIntervals where validDate(value.date) && value.seconds.isFinite && value.seconds >= 0 {
            // Keep artifacts for cleaning/quality assessment, not silent deletion.
            pages[Self.minute(value.date), default: MinuteSignals()].rr.append(.init(date: value.date, value: value.seconds))
        }
        for value in batch.motionFrames where validDate(value.date) && value.x.isFinite && value.y.isFinite && value.z.isFinite {
            pages[Self.minute(value.date), default: MinuteSignals()].motion.append(value)
        }
        for value in batch.skinTemperatures where validDate(value.date) && value.celsius.isFinite && (5...45).contains(value.celsius) {
            pages[Self.minute(value.date), default: MinuteSignals()].temperature.append(.init(date: value.date, value: value.celsius))
        }
        let count = pages.values.reduce(0) { $0 + $1.hr.count + $1.rr.count + $1.motion.count + $1.temperature.count }
        let dates = pages.keys.sorted()
        let history = historyMessage(batch, dates: dates)
        let rrResult = RRAnalysis.cleanRR(batch.rrIntervals.map { $0.seconds * 1000 })
        var rrMessage = "R-R: \(batch.rrIntervals.count) intervals, \(rrResult.nRemoved) artifacts."
        if let diag = batch.diagnostics {
            let gap = diag.lastRRNotificationAt.map { Int(now.timeIntervalSince($0)) }
            let allOn = !diag.notificationStates.isEmpty && diag.notificationStates.values.allSatisfy { $0 }
            rrMessage += allOn ? " Notifications remain subscribed." : " A notification subscription is inactive."
            if let gap { rrMessage += " Last R-R-bearing packet \(max(0, gap))s ago." }
            else { rrMessage += " No R-R-bearing packets received." }
            for (channel, lastRR) in diag.rrLastNotificationByChannel {
                if diag.notificationStates[channel] == false { rrMessage += " R-R source subscription stopped." }
                else if let lastAny = diag.lastNotificationAt[channel], lastAny > lastRR.addingTimeInterval(2) {
                    rrMessage += " R-R source still sends notifications, but its R-R fields are quiet."
                } else { rrMessage += " R-R source remains subscribed but has no newer notifications." }
            }
        }
        guard let first = dates.first, let last = dates.last else {
            return ScoringReport(acceptedSamples: 0, message: "Waiting for data; no scores or successful sync recorded.", history: history, rr: rrMessage)
        }
        let end = last.addingTimeInterval(60)
        let existing = try context.fetch(FetchDescriptor<SensorMinute>(predicate: #Predicate { $0.date >= first && $0.date < end }))
        let byDate = Dictionary(existing.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        for date in dates {
            guard let incoming = pages[date] else { continue }
            if let row = byDate[date] {
                var merged = try decoder.decode(MinuteSignals.self, from: row.payload)
                merged.merge(incoming)
                row.payload = try encoder.encode(merged)
            } else {
                var normalized = MinuteSignals(); normalized.merge(incoming)
                context.insert(SensorMinute(date: date, payload: try encoder.encode(normalized)))
            }
        }
        try context.save()
        let message = try rebuild(context: context, affectedDates: dates, now: now)
        return ScoringReport(acceptedSamples: count, message: message, history: history, rr: rrMessage)
    }

    func refresh(now: Date = .now) throws -> String {
        let context = ModelContext(container)
        let cutoff = now.addingTimeInterval(-14 * 86_400)
        let rows = try context.fetch(FetchDescriptor<SensorMinute>(predicate: #Predicate { $0.date >= cutoff }))
        return try rebuild(context: context, affectedDates: rows.map(\.date), now: now)
    }

    private func historyMessage(_ batch: RawSampleBatch, dates: [Date]) -> String {
        guard let diag = batch.diagnostics else { return "Backfill timing unavailable for this older archive." }
        let timestamps = batch.heartRates.map(\.date) + batch.rrIntervals.map(\.date) + batch.motionFrames.map(\.date) + batch.skinTemperatures.map(\.date)
        if let oldest = timestamps.min(), oldest < diag.startedAt.addingTimeInterval(-120) {
            return "Older history received: earliest \(oldest.formatted(date: .abbreviated, time: .shortened))."
        }
        if dates.isEmpty { return "History requested: \(diag.historyCommandSent ? "yes" : "no"); no sensor data returned yet." }
        return "Live-window data only; no timestamps older than this session. History start markers: \(diag.historyStartMarkers)."
    }

    private func read(_ context: ModelContext, start: Date, end: Date) throws -> MinuteSignals {
        let rows = try context.fetch(FetchDescriptor<SensorMinute>(predicate: #Predicate { $0.date >= start && $0.date < end }, sortBy: [SortDescriptor(\.date)]))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var result = MinuteSignals()
        for row in rows {
            let page = try decoder.decode(MinuteSignals.self, from: row.payload)
            result.hr += page.hr; result.rr += page.rr
            result.motion += page.motion; result.temperature += page.temperature
        }
        return result
    }

    private func rebuild(context: ModelContext, affectedDates: [Date], now: Date) throws -> String {
        guard !affectedDates.isEmpty else { return "Waiting for stored sensor data." }
        let settings = try context.fetch(FetchDescriptor<AppSettings>()).first
        let resetDate = settings?.baselineStartDate ?? .distantPast
        var nights = try context.fetch(FetchDescriptor<NightSummary>())
        var days = try context.fetch(FetchDescriptor<DaySummary>())
        let dayDates = Set(affectedDates.map { calendar.startOfDay(for: $0) }).sorted()
        // Sleep windows run from 18:00 to noon; both sides of midnight map
        // to the same morning. Daytime gaps cannot become invented sleep.
        var morningDates = Set<Date>()
        for date in affectedDates {
            let hour = calendar.component(.hour, from: date)
            let day = calendar.startOfDay(for: date)
            if hour >= 18 { morningDates.insert(calendar.date(byAdding: .day, value: 1, to: day) ?? day) }
            else if hour < 12 { morningDates.insert(day) }
        }
        for morning in morningDates.sorted() where morning <= now {
            let priorDay = calendar.date(byAdding: .day, value: -1, to: morning) ?? morning
            let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: priorDay) ?? priorDay
            let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: morning) ?? morning
            guard end > resetDate else { continue }
            let signals = try read(context, start: max(start, resetDate), end: min(end, now))
            if let calculated = calculateNight(signals, morning: morning, past: nights.filter { $0.nightDate < morning && $0.nightDate >= calendar.startOfDay(for: resetDate) }, settings: settings, previousStrain: days.first(where: { calendar.isDate($0.dayDate, inSameDayAs: priorDay) && $0.strainAvailable })?.strain ?? 0) {
                if let old = nights.first(where: { calendar.isDate($0.nightDate, inSameDayAs: morning) }) {
                    copyNight(calculated, into: old)
                } else { context.insert(calculated); nights.append(calculated) }
            }
        }
        var strainReady = false
        for date in dayDates {
            let end = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
            guard end > resetDate else { continue }
            let signals = try read(context, start: max(date, resetDate), end: end)
            guard signals.hr.count >= 60 else { continue }
            let row = days.first(where: { calendar.isDate($0.dayDate, inSameDayAs: date) }) ?? DaySummary(dayDate: date)
            if row.modelContext == nil { context.insert(row); days.append(row) }
            let observed = Set(signals.hr.map { Int($0.date.timeIntervalSince1970) }).count
            row.hrCoverage = min(1, Double(observed) / max(1, min(end, now).timeIntervalSince(date)))
            row.isLive = calendar.isDate(date, inSameDayAs: now)
            row.strainAvailable = false
            guard row.hrCoverage >= 0.8 else {
                row.qualityReason = "Heart-rate coverage is below 80%; strain withheld."
                continue
            }
            guard let maxHR = settings?.maximumHeartRate, let sexRaw = settings?.trainingSexRaw,
                  let sex = BiologicalSex(rawValue: sexRaw), (80...240).contains(maxHR) else {
                row.qualityReason = "Configure maximum HR and physiology in Data to enable strain."
                continue
            }
            let rest = nights.filter { $0.restingHRAvailable && $0.restingHR > 0 }.sorted { $0.nightDate > $1.nightDate }.first?.restingHR
            guard let rest, maxHR > rest else {
                row.qualityReason = "Waiting for an observed quiet overnight resting heart rate."
                continue
            }
            let grouped = Dictionary(grouping: signals.hr, by: { Self.minute($0.date) })
            var load = 0.0
            var aggregates = [Double](repeating: 0, count: 1440)
            for (minute, values) in grouped {
                let hr = mean(values.map(\.value))
                // Partial minutes contribute only their observed seconds.
                let fraction = min(1, Double(Set(values.map { Int($0.date.timeIntervalSince1970) }).count) / 60)
                let trimp = StrainEngine.trimpMinute(hr: min(hr, maxHR), hrRest: rest, hrMax: maxHR, sex: sex) * fraction
                let index = calendar.component(.hour, from: minute) * 60 + calendar.component(.minute, from: minute)
                aggregates[index] += trimp; load += trimp
            }
            row.strain = StrainEngine.loadToStrain(load); row.trimpLoad = load
            row.minuteTRIMP = aggregates; row.isLive = calendar.isDate(date, inSameDayAs: now)
            row.strainAvailable = true; row.qualityReason = nil
            strainReady = true
        }
        try context.save()
        let retention = now.addingTimeInterval(-14 * 86_400)
        let expired = try context.fetch(FetchDescriptor<SensorMinute>(predicate: #Predicate { $0.date < retention }))
        for row in expired { context.delete(row) }
        if !expired.isEmpty { try context.save() }
        let latest = nights.sorted { $0.nightDate > $1.nightDate }.first
        var message = latest.map { $0.confidenceReason ?? "Sleep and overnight vitals calculated. Recovery needs seven prior usable baseline nights." }
            ?? "Need at least three hours of overnight heart-rate and motion coverage to estimate sleep."
        if latest?.recoveryScore != nil { message = "Sleep, recovery and overnight vitals calculated." }
        if !strainReady { message += " Strain needs maximum HR, physiology setting, and an observed resting HR." }
        return message
    }

    private func calculateNight(_ signals: MinuteSignals, morning: Date, past: [NightSummary], settings: AppSettings?, previousStrain: Double) -> NightSummary? {
        guard let first = signals.hr.first?.date, let last = signals.hr.last?.date,
              last.timeIntervalSince(first) >= 3 * 3600, !signals.motion.isEmpty else { return nil }
        let start = Date(timeIntervalSince1970: floor(first.timeIntervalSince1970 / 30) * 30)
        let n = Int(last.timeIntervalSince(start) / 30) + 1
        func bucket(_ date: Date) -> Int { Int(date.timeIntervalSince(start) / 30) }
        let hrs = Dictionary(grouping: signals.hr, by: { bucket($0.date) })
        let motions = Dictionary(grouping: signals.motion, by: { bucket($0.date) })
        let rr = signals.rr
        var features: [EpochFeatures] = []
        var known: [Bool] = []
        for i in 0..<n {
            let h = hrs[i] ?? [], m = (motions[i] ?? []).sorted { $0.date < $1.date }
            let usable = Set(h.map { Int($0.date.timeIntervalSince1970) }).count >= 24
                && Set(m.map { Int($0.date.timeIntervalSince1970) }).count >= 24
            known.append(usable)
            let movement = zip(m, m.dropFirst()).map { a, b in sqrt(pow(a.x-b.x, 2) + pow(a.y-b.y, 2) + pow(a.z-b.z, 2)) }
            let epochStart = start.addingTimeInterval(Double(i) * 30)
            let quality = RRWindowQuality.evaluate(rr, window: DateInterval(start: epochStart, duration: 30), minimumClean: 20)
            features.append(EpochFeatures(index: i, motionMagnitude: 1 + min(1, mean(movement)),
                                          heartRate: usable ? mean(h.map(\.value)) : nil,
                                          hrv: quality.lnRMSSD.map(exp), respiratoryRate: nil,
                                          timeOfNightHours: Double(i) / 120))
        }
        let coverage = Double(known.filter { $0 }.count) / Double(n)
        guard known.filter({ $0 }).count >= 3 * 120 else { return nil }
        if let onsetEstimate = (0...max(0, n - 10)).first(where: { i in
            known[i..<(i+10)].allSatisfy { $0 } && features[i..<(i+10)].allSatisfy { SleepStager.activityIndex(fromG: $0.motionMagnitude) < 0.15 }
        }) {
            for i in features.indices { features[i].timeOfNightHours = Double(max(0, i - onsetEstimate)) / 120 }
        }
        var staged = SleepStager.stage(epochs: features)
        for i in staged.indices where !known[i] { staged[i].stage = .wake }
        let sleep = SleepStager.summarize(staged)
        guard let onset = sleep.onsetIndex, let wake = sleep.wakeIndex, sleep.totalSleepMinutes >= 90 else { return nil }
        let globalCleaning = RRAnalysis.cleanRR(rr.map { $0.value * 1000 })
        var selected: (quality: RRWindowQuality, hr: Double)?
        var respiratoryEstimates: [Double?] = []
        var failure = "No five-minute quiet window has sufficient clean R-R coverage."
        if n >= 10 {
            for i in stride(from: 0, through: n - 10, by: 10) {
                guard i >= onset, i + 10 <= wake + 1, known[i..<(i+10)].allSatisfy({ $0 }),
                      features[i..<(i+10)].allSatisfy({ SleepStager.activityIndex(fromG: $0.motionMagnitude) < 0.15 }) else { continue }
                let interval = DateInterval(start: start.addingTimeInterval(Double(i) * 30), duration: 300)
                let quality = RRWindowQuality.evaluate(rr, window: interval)
                let hr = mean(features[i..<(i+10)].compactMap(\.heartRate))
                if quality.isUsable {
                    respiratoryEstimates.append(RespiratoryEstimator.estimate(from: RespirationInput(rrIntervals: quality.clean.map { $0 / 1000 }, window: 300)))
                }
                if quality.isUsable, quality.lnRMSSD != nil, selected == nil || hr < selected!.hr { selected = (quality, hr) }
                else if !quality.isUsable { failure = quality.reason ?? failure }
            }
        }
        let observedWakeAtEnd = (max(0, n - 30)..<n).filter { known[$0] && staged[$0].stage == .wake }.count
        let closed = wake < n - 20 && observedWakeAtEnd >= 20
        let onsetCovered = onset >= 10 && (0..<onset).filter { known[$0] && staged[$0].stage == .wake }.count >= 10
        var longestGap = 0, run = 0
        for available in known { run = available ? 0 : run + 1; longestGap = max(longestGap, run) }
        let hrvOK = selected != nil && !globalCleaning.lowConfidence
        let low = coverage < 0.8 || longestGap >= 20 || !closed || !onsetCovered || !hrvOK
        let reason: String?
        if !onsetCovered { reason = "Sleep onset is not covered by observed wakefulness; scores withheld." }
        else if !closed { reason = "Sleep window is still open; waiting for at least ten minutes of observed wakefulness." }
        else if coverage < 0.8 || longestGap >= 20 { reason = "Overnight coverage is incomplete; scores withheld." }
        else if rr.isEmpty { reason = "No R-R data; HRV-based scores withheld." }
        else if globalCleaning.lowConfidence { reason = String(format: "R-R artifacts %.0f%% exceed the 15%% gate; HRV-based scores withheld.", globalCleaning.artifactFraction * 100) }
        else if !hrvOK { reason = failure }
        else { reason = nil }
        let quietHRs = zip(features, known).compactMap { feature, valid in
            valid && SleepStager.activityIndex(fromG: feature.motionMagnitude) < 0.15 ? feature.heartRate : nil
        }
        let rest = selected?.hr ?? quietHRs.sorted().prefix(10).reduce(0, +) / Double(max(1, min(10, quietHRs.count)))
        let night = NightSummary(nightDate: morning, lnRMSSD: hrvOK ? selected!.quality.lnRMSSD! : 0,
                                 restingHR: rest, totalSleepMinutes: sleep.totalSleepMinutes,
                                 sleepEfficiency: sleep.efficiency,
                                 lightMinutes: sleep.minutesByStage[.light] ?? 0,
                                 deepMinutes: sleep.minutesByStage[.deep] ?? 0,
                                 remMinutes: sleep.minutesByStage[.rem] ?? 0,
                                 wakeMinutes: sleep.minutesByStage[.wake] ?? 0,
                                 lowConfidence: low, confidenceReason: reason)
        night.hrvAvailable = hrvOK; night.restingHRAvailable = quietHRs.count >= 10
        night.sleepCoverage = coverage; night.rrCoverage = selected?.quality.coverage ?? 0
        night.rrArtifactFraction = rr.isEmpty ? 0 : globalCleaning.artifactFraction
        night.sleepOnset = start.addingTimeInterval(Double(onset) * 30)
        night.wakeTime = start.addingTimeInterval(Double(wake + 1) * 30)
        night.meanSkinTemperature = signals.temperature.isEmpty ? nil : mean(signals.temperature.map(\.value))
        let usable = past.filter { !$0.lowConfidence && $0.hrvAvailable && $0.restingHRAvailable && $0.confounderFlags.isEmpty }
            .sorted { $0.nightDate < $1.nightDate }
        let debt = sleepDebtMinutes(usable.sorted { $0.nightDate < $1.nightDate }.map { ($0.sleepNeedMinutes, $0.totalSleepMinutes) })
        night.sleepNeedMinutes = sleepNeedMinutes(baselineMedianMin: settings?.sleepGoalMinutes ?? 480, dayStrain: previousStrain, sleepDebtMin: debt)
        if hrvOK {
            night.respiratoryRate = RespiratoryEstimator.nightly(respiratoryEstimates)
        }
        if !low {
            var weights = settings?.sleepScoreWeights ?? .default
            if usable.count < 3 { weights.consistency = 0; weights.restfulness = 0 }
            let midpoint = night.sleepOnset!.addingTimeInterval(night.wakeTime!.timeIntervalSince(night.sleepOnset!) / 2)
            let currentMinutes = Double(calendar.component(.hour, from: midpoint) * 60 + calendar.component(.minute, from: midpoint))
            let phaseOffsets = usable.suffix(7).compactMap { old -> Double? in
                guard let from = old.sleepOnset, let to = old.wakeTime else { return nil }
                let mid = from.addingTimeInterval(to.timeIntervalSince(from) / 2)
                let minutes = Double(calendar.component(.hour, from: mid) * 60 + calendar.component(.minute, from: mid))
                return (minutes - currentMinutes + 2160).truncatingRemainder(dividingBy: 1440) - 720
            }.sorted()
            let medianOffset = phaseOffsets.isEmpty ? 0 : phaseOffsets[phaseOffsets.count / 2]
            let components = SleepComponents(
                sufficiency: sleepSufficiency(totalSleepMin: night.totalSleepMinutes, needMin: night.sleepNeedMinutes),
                efficiency: night.sleepEfficiency,
                consistency: sleepConsistency(midpoint: midpoint, medianMidpoint: midpoint.addingTimeInterval(medianOffset * 60)),
                restfulness: sleepRestfulness(rhrBpm: rest, rhrBaselineBpm: mean(usable.map(\.restingHR)),
                                              hrvMs: exp(night.lnRMSSD), hrvBaselineMs: mean(usable.map { exp($0.lnRMSSD) })))
            night.sleepScore = sleepScore(components, weights: weights)
            night.sleepScoreBasis = usable.count < 3 ? "Estimated from sleep sufficiency and efficiency; baseline components are still building." : "Estimated from sufficiency, efficiency, timing consistency and overnight restfulness."
            let baselines = Baselines.build(from: usable)
            if baselines.isComplete {
                let result = RecoveryScorer.score(night: night, baselines: baselines)
                night.recoveryScore = result.score; night.recoveryBand = result.band
                night.recoveryBasis = result.basisLine; night.confounderFlags = result.flags
            }
            let temps = usable.suffix(7).compactMap(\.meanSkinTemperature)
            if temps.count >= 3, let temperature = night.meanSkinTemperature { night.skinTempDeviation = temperature - mean(temps) }
        }
        return night
    }

    private func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    private func copyNight(_ source: NightSummary, into target: NightSummary) {
        target.lnRMSSD = source.lnRMSSD; target.restingHR = source.restingHR
        target.hrvAvailable = source.hrvAvailable; target.restingHRAvailable = source.restingHRAvailable
        target.respiratoryRate = source.respiratoryRate; target.skinTempDeviation = source.skinTempDeviation
        target.sleepOnset = source.sleepOnset; target.wakeTime = source.wakeTime
        target.totalSleepMinutes = source.totalSleepMinutes; target.sleepEfficiency = source.sleepEfficiency
        target.lightMinutes = source.lightMinutes; target.deepMinutes = source.deepMinutes
        target.remMinutes = source.remMinutes; target.wakeMinutes = source.wakeMinutes
        target.sleepNeedMinutes = source.sleepNeedMinutes; target.recoveryScore = source.recoveryScore
        target.recoveryBand = source.recoveryBand; target.recoveryBasis = source.recoveryBasis
        target.sleepScore = source.sleepScore; target.lowConfidence = source.lowConfidence
        target.confidenceReason = source.confidenceReason; target.confounderFlags = source.confounderFlags
        target.sleepCoverage = source.sleepCoverage; target.rrCoverage = source.rrCoverage
        target.rrArtifactFraction = source.rrArtifactFraction; target.meanSkinTemperature = source.meanSkinTemperature
        target.sleepScoreBasis = source.sleepScoreBasis
    }
}

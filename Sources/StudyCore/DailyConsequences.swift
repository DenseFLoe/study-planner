import Foundation

public struct DailyConsequenceOutcome: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case scheduled, heavy, pending, shortage }
    public var kind: Kind
    public var peakMinutes: Int
    public var heavyDays: Int
    public var unplacedMinutes: Int
    public var provenDeficit: Int?
    public var continuousMinutes: Int?
    public var courseNames: [String]
}

public struct DailyConsequenceForecast: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { fraction }
    public var fraction: Int
    public var todayMinutes: Int
    public var firstDay: DailyConsequenceOutcome?
    public var pressureAfterDays: Int?
    public var provenLimitAfterDays: Int?
    public var uncertainFromDay: Int?
    public var evaluatedDays: Int
    public var unavailableTodayMinutes: Int? = nil
}

public struct DailyConsequenceDay: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var capturedAt: Date
    public var revision: UUID
    public var warningMinutes: Int
    public var goalMinutes: Int
    public var confirmedAtCapture: Int
    public var capturedRecords: [CompletionRecord]
    public var plannedToday: [ScheduledTask]
    /// Minimal simulation state: progress becomes remaining manual lessons;
    /// no website URLs, pairing information or source notes are copied here.
    public var baseline: PlannerState
    public var forecasts: [DailyConsequenceForecast] = []
    public var celebrated: Set<Int> = []
    public var reviewedAt: Date?

    public var fractions: [Int] {
        var seen: Set<Int> = []
        return [0, 250, 500, 750, 1000].filter { fraction in
            fraction == 1000 || seen.insert(target(for: fraction)).inserted
        }
    }
    public func target(for fraction: Int) -> Int { goalMinutes * fraction / 1000 }
    public func threshold(for fraction: Int) -> Int { fraction == 1000 ? goalMinutes : target(for: fraction) + 1 }
    public func achieved(_ fraction: Int, confirmed: Int) -> Bool { goalMinutes > 0 && confirmed >= threshold(for: fraction) }
}

public struct DailyConsequenceJournal: Codable, Equatable, Sendable {
    public var version = 1
    public var days: [DailyConsequenceDay] = []
    public init() {}
}

public struct DailyConsequenceReality: Sendable {
    public var date: Date
    public var confirmedMinutes: Int
    public var goalMinutes: Int
    public var isReviewed: Bool
    public var ambiguousRecords: Int
    public var usesLegacyDates: Bool
    public var outcome: DailyConsequenceOutcome?
    public var achievedFractions: [Int]
}

public struct DailyConsequenceAnalyzer: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    public func revision(state: PlannerState, warningMinutes: Int) -> UUID {
        struct Lesson: Codable { var id: String; var duration: Int }
        struct CourseConfig: Codable {
            var id: UUID; var type: String; var total: Int
            var start: Date; var deadline: Date; var block: Int; var priority: Int
            var weight: Double; var enabled: Bool; var archived: Bool; var lessons: [Lesson]
        }
        struct EventConfig: Codable {
            var id: UUID; var start: Int; var end: Int; var from: Date; var to: Date
            var weekdays: [Int]; var excluded: [Date]; var floating: Int?
        }
        struct Window: Codable { var weekday: Int; var start: Int; var end: Int }
        struct Config: Codable { var courses: [CourseConfig]; var events: [EventConfig]; var windows: [Window]; var unit: Int; var warning: Int; var schedulingRuleLevels: [String: Int] }
        let courses = state.courses.sorted { $0.id.uuidString < $1.id.uuidString }.map { course in
            CourseConfig(id: course.id, type: course.type.rawValue, total: course.totalMinutes,
                start: course.startDate, deadline: course.deadline, block: course.minimumBlockMinutes, priority: course.priority,
                weight: course.dailyWeight, enabled: course.autoScheduleEnabled, archived: course.isArchived,
                lessons: state.lessonWorkItems(for: course).map { Lesson(id: $0.id, duration: $0.durationMinutes) })
        }
        let events = state.fixedEvents.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            EventConfig(id: $0.id, start: $0.startMinute, end: $0.endMinute, from: $0.startDate, to: $0.endDate,
                weekdays: $0.weekdays.sorted(), excluded: $0.excludedDates.sorted(), floating: $0.floatingDurationMinutes)
        }
        let windows = state.settings.availability.sorted {
            if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            return $0.endMinute < $1.endMinute
        }.map { Window(weekday: $0.weekday, start: $0.startMinute, end: $0.endMinute) }
        let configuration = Config(courses: courses, events: events, windows: windows, unit: state.settings.minimumScheduleUnit, warning: warningMinutes,
                                   schedulingRuleLevels: state.settings.schedulePriorities.levels)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(configuration)) ?? Data()
        return stablePlannerID("daily-consequences|" + String(decoding: encoded, as: UTF8.self))
    }

    public func effectiveDay(_ record: CompletionRecord, state: PlannerState) -> (date: Date, legacy: Bool)? {
        if let date = record.studyDate { return (calendar.startOfDay(for: date), false) }
        if let task = state.tasks.first(where: { $0.id == record.taskID }), calendar.isDate(task.start, inSameDayAs: record.recordedAt) {
            return (calendar.startOfDay(for: record.recordedAt), true)
        }
        return nil
    }

    public func confirmed(on day: Date, state: PlannerState) -> Int {
        state.completions.reduce(0) { sum, record in
            sum + (effectiveDay(record, state: state).map { calendar.isDate($0.date, inSameDayAs: day) } == true ? record.minutes : 0)
        }
    }

    public func capturedEvidenceIsValid(_ day: DailyConsequenceDay, state: PlannerState) -> Bool {
        let records = Dictionary(uniqueKeysWithValues: state.completions.map { ($0.id, $0) })
        guard day.capturedRecords.allSatisfy({ records[$0.id] == $0 }) else { return false }
        let captured = Set(day.capturedRecords.map(\.id))
        if state.completions.contains(where: { record in
            !captured.contains(record.id) && effectiveDay(record, state: state).map { $0.date < day.date } == true
        }) { return false }
        for baselineCourse in day.baseline.courses {
            guard let current = state.courses.first(where: { $0.id == baselineCourse.id }) else { return false }
            let extra = state.completions.filter { $0.courseID == current.id && !captured.contains($0.id) }.reduce(0) { $0 + $1.minutes }
            let expected = max(0, day.baseline.remainingMinutes(for: baselineCourse) - extra)
            if state.remainingMinutes(for: current) != expected { return false }
        }
        return true
    }

    public func capture(state: PlannerState, result: ScheduleResult, now: Date, warningMinutes: Int) -> DailyConsequenceDay {
        let today = calendar.startOfDay(for: now)
        let credited = confirmed(on: today, state: state)
        let tasks = result.tasks.filter { calendar.isDate($0.start, inSameDayAs: today) }
        var simulation = state
        simulation.completions = []
        for index in simulation.courses.indices {
            let source = state.courses[index]
            let items = state.lessonWorkItems(for: source).filter { $0.remainingMinutes > 0 }
            simulation.courses[index].totalMinutes = state.remainingMinutes(for: source)
            simulation.courses[index].initialCompletedMinutes = 0
            simulation.courses[index].webCourse = nil
            simulation.courses[index].mergedSources = nil
            simulation.courses[index].netdisk = nil
            simulation.courses[index].netdiskLessons = nil
            simulation.courses[index].webCompletionOverlaps = nil
            simulation.courses[index].notes = ""
            simulation.courses[index].manualLessons = items.isEmpty ? nil : items.map { .init(id: $0.id, name: $0.name, durationMinutes: $0.remainingMinutes) }
            if items.isEmpty { simulation.courses[index].type = .recorded }
        }
        for index in simulation.fixedEvents.indices { simulation.fixedEvents[index].notes = "" }
        var entry = DailyConsequenceDay(date: today, capturedAt: now, revision: revision(state: state, warningMinutes: warningMinutes),
            warningMinutes: warningMinutes, goalMinutes: credited + tasks.reduce(0) { $0 + $1.durationMinutes },
            confirmedAtCapture: credited, capturedRecords: state.completions, plannedToday: tasks, baseline: simulation)
        entry.celebrated = Set(entry.fractions.filter { entry.achieved($0, confirmed: credited) })
        return entry
    }

    private func outcome(state: PlannerState, result: ScheduleResult, now: Date, warning: Int) -> DailyConsequenceOutcome {
        let health = ScheduleHealthAnalyzer(calendar: calendar).assess(state: state, result: result, now: now, heavyDayMinutes: warning)
        let kind: DailyConsequenceOutcome.Kind
        switch health?.status {
        case .heavy: kind = .heavy
        case .pending: kind = .pending
        case .shortage: kind = .shortage
        default: kind = .scheduled
        }
        let proof = result.conflicts.max { ($0.provenDeficit ?? 0) < ($1.provenDeficit ?? 0) }
        return .init(kind: kind, peakMinutes: health?.peakMinutes ?? 0, heavyDays: health?.heavyDays ?? 0,
                     unplacedMinutes: health?.unscheduledMinutes ?? 0, provenDeficit: proof?.provenDeficit,
                     continuousMinutes: proof?.minimumContinuousMinutes, courseNames: proof?.courseNames ?? [])
    }

    private func credit(_ minutes: Int, courseID: UUID, lessonID: String?, state: inout PlannerState) {
        guard minutes > 0, let c = state.courses.firstIndex(where: { $0.id == courseID }) else { return }
        if var lessons = state.courses[c].manualLessons {
            if let index = lessons.firstIndex(where: { $0.id == lessonID }) {
                lessons[index].durationMinutes = max(0, lessons[index].durationMinutes - minutes)
            } else {
                var remaining = minutes
                for index in lessons.indices where remaining > 0 {
                    let used = min(remaining, lessons[index].durationMinutes)
                    lessons[index].durationMinutes -= used; remaining -= used
                }
            }
            lessons.removeAll { $0.durationMinutes == 0 }
            state.courses[c].manualLessons = lessons
            state.courses[c].totalMinutes = lessons.reduce(0) { $0 + $1.durationMinutes }
        } else { state.courses[c].totalMinutes = max(0, state.courses[c].totalMinutes - minutes) }
    }

    /// Repeatedly complete the specified fraction of each day's newly planned work.
    /// One-day effects and continued-pattern effects are separate; search uncertainty
    /// is preserved instead of being turned into an exact hard-limit countdown.
    public func forecast(_ entry: DailyConsequenceDay, fraction: Int, horizon: Int = 90) -> DailyConsequenceForecast? {
        let target = entry.target(for: fraction)
        if target < entry.confirmedAtCapture { return .init(fraction: fraction, todayMinutes: target, evaluatedDays: 0) }
        var state = entry.baseline
        let engine = ScheduleEngine(calendar: calendar)
        var now = entry.capturedAt, plan = engine.generate(state: state, now: now)
        let availableToday = plan.tasks.filter { calendar.isDate($0.start, inSameDayAs: entry.date) }.reduce(0) { $0 + $1.durationMinutes }
        let requested = max(0, target - entry.confirmedAtCapture)
        if requested > availableToday {
            return .init(fraction: fraction, todayMinutes: target, evaluatedDays: 0, unavailableTodayMinutes: requested - availableToday)
        }
        let initial = outcome(state: state, result: plan, now: now, warning: entry.warningMinutes)
        var forecast = DailyConsequenceForecast(fraction: fraction, todayMinutes: target,
            pressureAfterDays: initial.heavyDays > 0 ? 0 : nil,
            provenLimitAfterDays: initial.kind == .shortage ? 0 : nil,
            uncertainFromDay: initial.kind == .pending ? 0 : nil, evaluatedDays: 0)
        let last = state.courses.filter { !$0.isArchived && $0.autoScheduleEnabled }.map(\.deadline).max() ?? now
        let count = min(max(1, horizon), max(1, (calendar.dateComponents([.day], from: entry.date, to: calendar.startOfDay(for: last)).day ?? 0) + 1))
        for index in 0..<count {
            if Task.isCancelled { return nil }
            let day = calendar.startOfDay(for: now)
            let tasks = plan.tasks.filter { calendar.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
            var budget = index == 0 ? max(0, target - entry.confirmedAtCapture) : tasks.reduce(0) { $0 + $1.durationMinutes } * fraction / 1000
            var history = state.tasks.filter { !$0.isUnconfirmed && $0.planningEnd >= day }
            for task in tasks {
                let actual = min(task.durationMinutes, budget); budget -= actual
                credit(actual, courseID: task.courseID, lessonID: task.lessonID, state: &state)
                if actual > 0 {
                    var retained = task
                    retained.completedMinutes = actual; retained.status = .completed
                    retained.confirmedAt = task.start.addingTimeInterval(Double(actual * 60))
                    history.append(retained)
                }
            }
            state.tasks = history
            state.settings.actualStudyStart = nil
            now = calendar.date(byAdding: .day, value: 1, to: day)!
            plan = engine.generate(state: state, now: now)
            let result = outcome(state: state, result: plan, now: now, warning: entry.warningMinutes)
            forecast.evaluatedDays = index + 1
            if index == 0 { forecast.firstDay = result }
            if result.heavyDays > 0 && forecast.pressureAfterDays == nil { forecast.pressureAfterDays = index + 1 }
            if result.kind == .pending && forecast.uncertainFromDay == nil { forecast.uncertainFromDay = index + 1 }
            if result.kind == .shortage && forecast.provenLimitAfterDays == nil { forecast.provenLimitAfterDays = index + 1 }
            if forecast.provenLimitAfterDays != nil { break }
            if state.courses.allSatisfy({ state.remainingMinutes(for: $0) == 0 || $0.isArchived || !$0.autoScheduleEnabled }) { break }
        }
        return forecast
    }

    public func reality(_ entry: DailyConsequenceDay, state: PlannerState) -> DailyConsequenceReality {
        let actual = confirmed(on: entry.date, state: state)
        let captured = Set(entry.capturedRecords.map(\.id))
        let newRecords = state.completions.filter { !captured.contains($0.id) }
        let tasks = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0) })
        let relevant = state.completions.filter { record in
            calendar.isDate(record.recordedAt, inSameDayAs: entry.date) || tasks[record.taskID].map { calendar.isDate($0.start, inSameDayAs: entry.date) } == true
        }
        let ambiguous = relevant.filter { effectiveDay($0, state: state) == nil }.count
        let legacy = state.completions.contains { record in
            effectiveDay(record, state: state).map { $0.legacy && calendar.isDate($0.date, inSameDayAs: entry.date) } == true
        }
        struct Key: Hashable { var course: UUID; var lesson: String? }
        var targets: [Key: Int] = [:], reviewed: [Key: Int] = [:]
        for task in entry.plannedToday { targets[.init(course: task.courseID, lesson: task.lessonID), default: 0] += task.durationMinutes }
        var projection = entry.baseline
        for record in newRecords {
            let task = tasks[record.taskID]
            let key = Key(course: record.courseID, lesson: task?.lessonID)
            if let task, calendar.isDate(task.start, inSameDayAs: entry.date) {
                if task.lessonID != nil { reviewed[key] = max(reviewed[key, default: 0], task.durationMinutes) }
                else { reviewed[key, default: 0] += task.durationMinutes }
            }
            if effectiveDay(record, state: state).map({ calendar.isDate($0.date, inSameDayAs: entry.date) }) == true {
                credit(record.minutes, courseID: record.courseID, lessonID: task?.lessonID, state: &projection)
            }
        }
        let pending = state.tasks.contains { $0.isUnconfirmed && calendar.isDate($0.start, inSameDayAs: entry.date) }
        let covered = targets.allSatisfy { reviewed[$0.key, default: 0] >= $0.value }
        let valid = capturedEvidenceIsValid(entry, state: state) && revision(state: state, warningMinutes: entry.warningMinutes) == entry.revision
        let complete = ambiguous == 0 && !pending && (entry.reviewedAt != nil || covered || actual >= entry.goalMinutes)
        let next = calendar.date(byAdding: .day, value: 1, to: entry.date)!
        // Preserve real known end-of-study buffers; late backfills do not invent
        // a study time on their recording date.
        projection.tasks = state.tasks.filter { task in
            task.confirmedAt.map { calendar.isDate($0, inSameDayAs: entry.date) } == true && task.completedMinutes > 0
        }
        let result = valid ? outcome(state: projection, result: ScheduleEngine(calendar: calendar).generate(state: projection, now: next), now: next, warning: entry.warningMinutes) : nil
        return .init(date: entry.date, confirmedMinutes: actual, goalMinutes: entry.goalMinutes,
                     isReviewed: complete, ambiguousRecords: ambiguous, usesLegacyDates: legacy,
                     outcome: result, achievedFractions: entry.fractions.filter { entry.achieved($0, confirmed: actual) })
    }
}

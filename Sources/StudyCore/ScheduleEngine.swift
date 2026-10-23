import Foundation

public struct ScheduleRisk: Identifiable, Equatable, Sendable {
    public var id: Date { deadline }
    public var deadline: Date
    public var requiredMinutes: Int
    public var availableMinutes: Int
    public var unscheduledMinutes: Int
    public var courseNames: [String]
    public var capacityDeficit: Int { max(0, requiredMinutes - availableMinutes) }
}
public struct CourseDemand: Sendable {
    public var remainingMinutes: Int
    public var learnableDays: Int
    public var averageMinutesPerDay: Double {
        learnableDays > 0 ? Double(remainingMinutes) / Double(learnableDays) : 0
    }
}
public struct ScheduleResult: Sendable {
    public var tasks: [ScheduledTask]
    public var risks: [ScheduleRisk]
    public var demands: [UUID: CourseDemand]
    public var diagnostics: [String]
    public var conflicts: [ScheduleConstraintConflict] = []
    public var dayPlans: [ScheduleDayPlan] = []
    public var adjustments: [String] = []
}

/// Pure, minute-based local scheduling. No persistence, UI, system Calendar, or EventKit dependencies.
/// Calendar below is Foundation date arithmetic only.
public struct ScheduleEngine: Sendable {
    public static let breakMinutes = 15
    private var breakSeconds: TimeInterval { Double(Self.breakMinutes * 60) }
    // Reserve both sides because repair and balancing can insert a task before an existing one.
    private func buffered(start: Date, end: Date) -> Span {
        .init(start: start.addingTimeInterval(-breakSeconds), end: end.addingTimeInterval(breakSeconds))
    }
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }
    private struct Span {
        var start: Date
        var end: Date
        var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    }
    private struct Day {
        var date: Date
        var free: [Span]
    }
    public func instant(day: Date, minute: Int) -> Date {
        if minute >= 1440 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))! }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)!
    }
    private func merged(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else { result.append(span) }
        }
        return result
    }
    private func subtract(_ blocks: [Span], from available: [Span]) -> [Span] {
        var result = merged(available)
        for block in merged(blocks) {
            result = result.flatMap { span -> [Span] in
                guard block.start < span.end, block.end > span.start else { return [span] }
                var parts: [Span] = []
                if span.start < block.start { parts.append(.init(start: span.start, end: block.start)) }
                if block.end < span.end { parts.append(.init(start: block.end, end: span.end)) }
                return parts
            }
        }
        return result
    }
    public func generate(state: PlannerState, now: Date) -> ScheduleResult {
        let today = calendar.startOfDay(for: now)
        let actualStart = state.settings.actualStudyStart(on: now, calendar: calendar)
        // A daily anchor must not send remaining work back before a saved review,
        // including zero-minute confirmations. Derive the floor from persisted
        // history so reopening and syncing keep the same scheduling boundary.
        let lastConfirmation = state.tasks.compactMap(\.confirmedAt)
            .filter { calendar.isDate($0, inSameDayAs: now) }.max()
        let scheduleStart = max(actualStart ?? now, lastConfirmation ?? today)
        let nextMinute = Date(timeIntervalSince1970: ceil(scheduleStart.timeIntervalSince1970 / 60) * 60)
        let courses = state.courses.filter { !$0.isArchived && $0.autoScheduleEnabled && state.remainingMinutes(for: $0) > 0 }
        let priorities = state.settings.schedulePriorities
        let defaultOrder = priorities.usesDefaultOrder
        var diagnostics: [String] = []
        let validEvents = state.fixedEvents.filter {
            let valid = $0.validDuration && $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.endMinute > $0.startMinute && $0.endDate >= calendar.startOfDay(for: $0.startDate)
            if !valid { diagnostics.append("固定事项「\($0.title)」的时间无效，请修改。") }
            return valid
        }
        let availability = state.settings.availability.filter {
            let valid = (1...7).contains($0.weekday) && $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.endMinute > $0.startMinute
            if !valid { diagnostics.append("部分可学习时间设置无效，已忽略。") }
            return valid
        }
        var days: [Day] = []
        var hardDays: [Day] = []
        var eventWindows: [ScheduleFeasibilitySearch.Window] = []
        var floatingJobs: [ScheduleFeasibilitySearch.Floating] = []
        var jointSearchSupported = true
        var adjustments: [String] = []
        func minute(_ date: Date) -> Int { Int(ceil(date.timeIntervalSinceReferenceDate / 60)) }
        var floatingRegions: [Span] = []
        let lastDay = max(today, courses.map { calendar.startOfDay(for: $0.deadline) }.max() ?? today)
        // A bounded horizon protects the UI from accidentally entered dates thousands of years away.
        let limit = calendar.date(byAdding: .year, value: 10, to: today)!
        let horizon = min(lastDay, limit)
        if lastDay > limit { diagnostics.append("计划只生成未来十年；请检查课程截止日期。超出范围的学习量会保留并提示。") }
        var day = today
        while day <= horizon {
            let weekday = calendar.component(.weekday, from: day)
            let windows = availability.filter { $0.weekday == weekday }.map {
                Span(start: max(nextMinute, instant(day: day, minute: $0.startMinute)), end: instant(day: day, minute: $0.endMinute))
            }
            let events = validEvents.filter { $0.occurs(on: day, calendar: calendar) }
            let exact = events.filter { !$0.isFloating }.map {
                Span(start: instant(day: day, minute: $0.startMinute), end: instant(day: day, minute: $0.endMinute))
            }
            let regions = merged(events.filter(\.isFloating).map {
                Span(start: instant(day: day, minute: $0.startMinute), end: instant(day: day, minute: $0.endMinute))
            })
            // Clip uncertainty to contiguous learnable intervals; exact appointments remain pinned.
            for span in subtract(exact, from: windows) {
                for region in regions {
                    let clipped = Span(start: max(span.start, region.start), end: min(span.end, region.end))
                    if clipped.minutes > 0 { floatingRegions.append(clipped) }
                }
            }
            var blocks = exact
            let studyMinutes = Set(availability.filter { $0.weekday == weekday }.flatMap { Array($0.startMinute..<$0.endMinute) })
            if let placements = FloatingPlacement.reserve(events, studyMinutes: studyMinutes) {
                for event in events where event.isFloating {
                    let start = placements[event.id]!
                    blocks.append(.init(start: instant(day: day, minute: start), end: instant(day: day, minute: start + event.occupiedMinutes)))
                }
            } else {
                diagnostics.append("浮动事项的连续时长无法排入，或组合过于复杂；请调整时段。")
                blocks += regions
            }
            // Only retained history reserves time; a planned start is not evidence of actual study.
            let history = state.tasks.filter {
                let replacingToday = actualStart != nil && calendar.isDate($0.start, inSameDayAs: now)
                return $0.planningStart < now && (($0.isUnconfirmed && $0.planningEnd <= now && !replacingToday) || $0.completedMinutes > 0)
            }
                .map { buffered(start: $0.retainedHistoryInterval.start,
                                end: $0.retainedHistoryInterval.end) }
            blocks += history
            hardDays.append(.init(date: day, free: subtract(exact + history, from: windows)))
            eventWindows += subtract(exact + history, from: [.init(start: day, end: instant(day: day, minute: 1440))])
                .map { .init(start: minute($0.start), end: Int(floor($0.end.timeIntervalSinceReferenceDate / 60))) }
            let floating = events.filter(\.isFloating)
            if floating.count > 1 { jointSearchSupported = false }
            for event in floating {
                floatingJobs.append(.init(key: day, start: minute(instant(day: day, minute: event.startMinute)),
                                          end: minute(instant(day: day, minute: event.endMinute)), minutes: event.occupiedMinutes))
            }
            days.append(.init(date: day, free: subtract(blocks, from: windows)))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        var originalDays = days
        var demands: [UUID: CourseDemand] = [:]
        var required: [UUID: Int] = [:]
        struct Work {
            var minutes: Int
            var lessonID: String? = nil
            var lessonName: String? = nil
        }
        var pending: [UUID: [Work]] = [:]
        func unit(_ course: Course) -> Int { max(1, course.minimumBlockMinutes > 0 ? course.minimumBlockMinutes : state.settings.minimumScheduleUnit) }
        func eligible(_ course: Course, _ day: Date) -> Bool {
            day >= calendar.startOfDay(for: course.startDate) && day <= calendar.startOfDay(for: course.deadline)
        }
        for course in courses {
            let remaining = state.remainingMinutes(for: course)
            var work: [Work] = []
            let lessons = state.lessonWorkItems(for: course)
            if !lessons.isEmpty {
                let lessonWork = lessons.map { Work(minutes: $0.remainingMinutes, lessonID: $0.id, lessonName: $0.name) }
                work = lessonWork.filter { $0.minutes > 0 }
                if work.reduce(0, { $0 + $1.minutes }) != remaining {
                    diagnostics.append("「\(course.name)」的课节进度与课程总进度不一致，暂按普通时间块排程；请重新抓取。")
                    work = []
                }
            }
            if work.isEmpty && remaining > 0 {
                var left = remaining
                while left > 0 {
                    let size = min(unit(course), left)
                    work.append(.init(minutes: size))
                    left -= size
                }
            }
            pending[course.id] = work
            required[course.id] = remaining
            let shortest = work.map(\.minutes).min() ?? 0
            let count = days.filter { eligible(course, $0.date) && $0.free.contains(where: { shortest > 0 && $0.minutes >= shortest }) }.count
            demands[course.id] = .init(remainingMinutes: remaining, learnableDays: count)
        }
        let allWork = pending
        let hasDailyBoost = courses.contains { $0.dailyWeight > 1 }
        // A boost concentrates learning into earlier learnable days. These are soft
        // targets: the original deadline remains available when capacity is tight.
        var preferredDays: [UUID: Set<Date>] = [:]
        for course in courses where course.dailyWeight > 1 {
            let shortest = pending[course.id]?.map(\.minutes).min() ?? 1
            let learnable = days.filter { eligible(course, $0.date) && $0.free.contains { $0.minutes >= shortest } }
            let count = max(1, Int(ceil(Double(learnable.count) / course.dailyWeight)))
            preferredDays[course.id] = Set(learnable.prefix(count).map(\.date))
        }
        let ordered = courses.sorted {
            let a = calendar.startOfDay(for: $0.deadline), b = calendar.startOfDay(for: $1.deadline)
            if a != b { return a < b }
            let da = demands[$0.id]!.averageMinutesPerDay, db = demands[$1.id]!.averageMinutesPerDay
            if da != db { return da > db }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if unit($0) != unit($1) { return unit($0) > unit($1) }
            return $0.id.uuidString < $1.id.uuidString
        }
        var tasks: [ScheduledTask] = []
        var missing: [UUID: Int] = [:]
        func take(_ minutes: Int, on index: Int, earliest: Date = .distantPast) -> Date? {
            guard let span = days[index].free.first(where: {
                $0.end.timeIntervalSince(max($0.start, earliest)) >= Double(minutes * 60)
            }) else { return nil }
            let start = max(span.start, earliest)
            let occupied = buffered(start: start, end: start.addingTimeInterval(Double(minutes) * 60))
            for d in days.indices { days[d].free = subtract([occupied], from: days[d].free) }
            return start
        }
        // Feasibility first: allocate earliest deadlines before distributing load across later days.
        for course in ordered {
            var lessonStart = Date.distantPast
            for index in days.indices where eligible(course, days[index].date) {
                while let work = pending[course.id]?.first {
                    guard let start = take(work.minutes, on: index, earliest: work.lessonID == nil ? .distantPast : lessonStart) else { break }
                    tasks.append(.init(courseID: course.id, start: start, durationMinutes: work.minutes,
                                       lessonID: work.lessonID, lessonName: work.lessonName))
                    if work.lessonID != nil { lessonStart = start.addingTimeInterval(Double(work.minutes * 60) + breakSeconds) }
                    pending[course.id]!.removeFirst()
                }
            }
            missing[course.id] = pending[course.id]!.reduce(0) { $0 + $1.minutes }
        }
        // Repair fragmented capacity: evacuate blocking small chunks to other free intervals
        // before declaring a larger chunk unplaceable. A failed attempt rolls back completely.
        let lessonRanks = Dictionary(uniqueKeysWithValues: courses.map { course in
            (course.id, Dictionary(uniqueKeysWithValues: state.lessonWorkItems(for: course).enumerated().map { ($0.element.id, $0.offset) }))
        })
        func preservesLessonOrder(_ booked: [ScheduledTask]) -> Bool {
            for course in courses {
                let lessons = booked.filter { $0.courseID == course.id && $0.lessonID != nil }.sorted { $0.start < $1.start }
                for (a, b) in zip(lessons, lessons.dropFirst()) {
                    guard let first = lessonRanks[course.id]?[a.lessonID!], let next = lessonRanks[course.id]?[b.lessonID!],
                          first < next, a.end.addingTimeInterval(breakSeconds) <= b.start else { return false }
                }
            }
            return true
        }
        var repairAttempts = 0
        for course in ordered {
            while let work = pending[course.id]?.first, repairAttempts < 200 {
                let size = work.minutes
                var repaired = false
                search: for dayIndex in originalDays.indices where eligible(course, originalDays[dayIndex].date) {
                    for span in originalDays[dayIndex].free where span.minutes >= size {
                        let starts = ([span.start] + tasks.filter { $0.start >= span.start && $0.end < span.end }.map { $0.end.addingTimeInterval(breakSeconds) }).sorted()
                        for start in starts {
                            if work.lessonID != nil,
                               let last = tasks.filter({ $0.courseID == course.id }).map(\.end).max(),
                               start < last.addingTimeInterval(breakSeconds) { continue }
                            repairAttempts += 1
                            if repairAttempts > 200 { break search }
                            let reserved = Span(start: start, end: start.addingTimeInterval(Double(size) * 60))
                            guard reserved.end <= span.end else { continue }
                            let reservation = buffered(start: reserved.start, end: reserved.end)
                            let blockers = tasks.indices.filter { tasks[$0].start < reservation.end && tasks[$0].end > reservation.start }
                            // If an existing block has no alternate destination, rebuilding all
                            // free intervals cannot evacuate it. Skip this expensive failed search.
                            let immovable = blockers.contains { index in
                                let blocked = tasks[index]
                                let owner = courses.first { $0.id == blocked.courseID }!
                                return !days.contains { eligible(owner, $0.date) && $0.free.contains { $0.minutes >= blocked.durationMinutes } }
                            }
                            if immovable { continue }
                            let oldDays = days, oldTasks = tasks
                            let blockerIDs = Set(blockers.map { tasks[$0].id })
                            let untouched = tasks.filter { !blockerIDs.contains($0.id) }
                            for d in days.indices {
                                let occupied = untouched.map { buffered(start: $0.start, end: $0.end) }
                                days[d].free = subtract(occupied + [reservation], from: originalDays[d].free)
                            }
                            var canMove = true
                            for index in blockers.sorted(by: { tasks[$0].durationMinutes > tasks[$1].durationMinutes }) {
                                let blocked = tasks[index]
                                let owner = courses.first { $0.id == blocked.courseID }!
                                var replacement: Date?
                                for d in days.indices where eligible(owner, days[d].date) {
                                    if let start = take(blocked.durationMinutes, on: d) { replacement = start; break }
                                }
                                guard let replacement else { canMove = false; break }
                                tasks[index].start = replacement
                            }
                            if canMove {
                                let added = ScheduledTask(courseID: course.id, start: start, durationMinutes: size,
                                                          lessonID: work.lessonID, lessonName: work.lessonName)
                                if preservesLessonOrder(tasks + [added]) {
                                    tasks.append(added)
                                    pending[course.id]!.removeFirst(); repaired = true
                                    break search
                                }
                            }
                            days = oldDays; tasks = oldTasks
                        }
                    }
                }
                if !repaired { break }
            }
            missing[course.id] = pending[course.id]!.reduce(0) { $0 + $1.minutes }
        }
        let feasibleTasks = tasks, feasibleMissing = missing
        // Daily diversity is a preference; it must not lose an earlier deadline.
        // Rebuild from ALL unfinished work, including blocks the deadline-first pass
        // could not book; otherwise a monopolizing course can hide the other courses.
        if courses.count >= 3 && (defaultOrder || priorities.orderedRules.first == .diversity) {
            tasks = []
            days = originalDays
            var positions = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, 0) })
            var lastEnds: [UUID: Date] = [:]
            func nextWork(_ course: Course) -> Work? {
                let position = positions[course.id]!
                return position < allWork[course.id]!.count ? allWork[course.id]![position] : nil
            }
            func placement(_ course: Course, in free: [Span]) -> ScheduledTask? {
                guard let work = nextWork(course) else { return nil }
                let earliest = lastEnds[course.id]?.addingTimeInterval(breakSeconds) ?? .distantPast
                guard let span = free.first(where: {
                    $0.end.timeIntervalSince(max($0.start, earliest)) >= Double(work.minutes * 60)
                }) else { return nil }
                return .init(courseID: course.id, start: max(span.start, earliest), durationMinutes: work.minutes,
                             lessonID: work.lessonID, lessonName: work.lessonName)
            }
            // Try different course orders: a short lesson must not consume the only
            // window that can hold a long lesson. At most three distinct blocks deep.
            func seed(_ candidates: [Course], free: [Span], count: Int) -> [ScheduledTask]? {
                if count == 0 { return [] }
                guard candidates.count >= count else { return nil }
                for course in candidates {
                    guard let task = placement(course, in: free) else { continue }
                    let rest = subtract([buffered(start: task.start, end: task.end)], from: free)
                    if let tail = seed(candidates.filter { $0.id != course.id }, free: rest, count: count - 1) {
                        return [task] + tail
                    }
                }
                return nil
            }
            func book(_ task: ScheduledTask) {
                tasks.append(task)
                positions[task.courseID]! += 1
                lastEnds[task.courseID] = task.end
                let occupied = buffered(start: task.start, end: task.end)
                for index in days.indices { days[index].free = subtract([occupied], from: days[index].free) }
            }
            for index in days.indices {
                let active = ordered.filter { eligible($0, days[index].date) && nextWork($0) != nil }
                // The exception is local to a day actually containing a 3x course.
                // A future, finished, paused or non-fitting 3x course grants no exemption.
                let triple = defaultOrder ? active.first { $0.dailyWeight == 3 && placement($0, in: days[index].free) != nil } : nil
                let initial: [ScheduledTask]
                if let triple, let task = placement(triple, in: days[index].free) {
                    initial = [task]
                } else {
                    initial = seed(active, free: days[index].free, count: 3)
                        ?? seed(active, free: days[index].free, count: 2)
                        ?? seed(active, free: days[index].free, count: 1) ?? []
                }
                var daily: [UUID: Int] = [:]
                for task in initial.sorted(by: { $0.start < $1.start }) {
                    book(task); daily[task.courseID, default: 0] += task.durationMinutes
                }
                // Reserve variety only for future days that can actually fit three
                // distinct next lessons AND their breaks after fixed events. Counting
                // individually fitting courses would reserve work for impossible days.
                let futureDiverseIndices = originalDays.indices.filter { future in
                    guard future > index else { return false }
                    let participants = ordered.filter { eligible($0, originalDays[future].date) && nextWork($0) != nil }
                    return seed(participants, free: originalDays[future].free, count: 3) != nil
                }
                var reserves: [UUID: Int] = [:]
                for course in active where !defaultOrder || course.dailyWeight < 3 {
                    let remainingWork = allWork[course.id]!.dropFirst(positions[course.id]!)
                    guard let shortest = remainingWork.map(\.minutes).min() else { continue }
                    reserves[course.id] = futureDiverseIndices.filter { future in
                        eligible(course, originalDays[future].date)
                            && originalDays[future].free.contains { $0.minutes >= shortest }
                    }.count
                }
                while true {
                    let remainingBlocks = ordered.reduce(0) { $0 + allWork[$1.id]!.count - positions[$1.id]! }
                    // Keep future variety when feasible, but do not strand work due
                    // today or ration a day that can only fit one or two subjects.
                    let preserveFuture = triple == nil && initial.count >= 3
                        && remainingBlocks <= 3 * futureDiverseIndices.count
                    let candidates = active.filter { course in
                        guard nextWork(course) != nil, placement(course, in: days[index].free) != nil else { return false }
                        if calendar.startOfDay(for: course.deadline) == days[index].date || (triple == nil && initial.count < 3) { return true }
                        if preserveFuture { return false }
                        return daily[course.id] == nil || allWork[course.id]!.count - positions[course.id]! > reserves[course.id, default: 0]
                    }
                    let selected = candidates.min { a, b in
                        if !defaultOrder {
                            let urgentA = calendar.startOfDay(for: a.deadline) == days[index].date
                            let urgentB = calendar.startOfDay(for: b.deadline) == days[index].date
                            if urgentA != urgentB { return urgentA }
                            for rule in priorities.orderedRules {
                                switch rule {
                                case .diversity:
                                    if (daily[a.id] == nil) != (daily[b.id] == nil) { return daily[a.id] == nil }
                                case .dailyWeight:
                                    if hasDailyBoost {
                                        let loadA = Double(daily[a.id, default: 0]) / max(1, demands[a.id]!.averageMinutesPerDay * a.dailyWeight)
                                        let loadB = Double(daily[b.id, default: 0]) / max(1, demands[b.id]!.averageMinutesPerDay * b.dailyWeight)
                                        if loadA != loadB { return loadA < loadB }
                                    }
                                case .coursePriority:
                                    if a.priority != b.priority { return a.priority > b.priority }
                                case .balancedLoad:
                                    if daily[a.id, default: 0] != daily[b.id, default: 0] { return daily[a.id, default: 0] < daily[b.id, default: 0] }
                                }
                            }
                            return false
                        }
                        if daily.count < 3 && triple == nil && (daily[a.id] == nil) != (daily[b.id] == nil) {
                            return daily[a.id] == nil
                        }
                        let urgentA = calendar.startOfDay(for: a.deadline) == days[index].date
                        let urgentB = calendar.startOfDay(for: b.deadline) == days[index].date
                        if urgentA != urgentB { return urgentA }
                        if hasDailyBoost {
                            let loadA = Double(daily[a.id, default: 0]) / max(1, demands[a.id]!.averageMinutesPerDay * a.dailyWeight)
                            let loadB = Double(daily[b.id, default: 0]) / max(1, demands[b.id]!.averageMinutesPerDay * b.dailyWeight)
                            if loadA != loadB { return loadA < loadB }
                        }
                        if a.priority != b.priority { return a.priority > b.priority }
                        return daily[a.id, default: 0] < daily[b.id, default: 0]
                    }
                    guard let selected, let task = placement(selected, in: days[index].free) else { break }
                    book(task); daily[selected.id, default: 0] += task.durationMinutes
                }
            }
            for course in courses {
                missing[course.id] = allWork[course.id]!.dropFirst(positions[course.id]!).reduce(0) { $0 + $1.minutes }
            }
            for cutoff in Set(courses.map { calendar.startOfDay(for: $0.deadline) }).sorted() {
                let group = courses.filter { calendar.startOfDay(for: $0.deadline) <= cutoff }
                let before = group.reduce(0) { $0 + feasibleMissing[$1.id, default: 0] }
                let after = group.reduce(0) { $0 + missing[$1.id, default: 0] }
                if before == after { continue }
                if before < after {
                    tasks = feasibleTasks; missing = feasibleMissing
                    for i in days.indices { days[i].free = subtract(tasks.map { buffered(start: $0.start, end: $0.end) }, from: originalDays[i].free) }
                    adjustments.append(ScheduleExplanation.deadlineFallback)
                }
                break
            }
        }
        // Rescue incomplete heuristic allocations by jointly placing whole lessons
        // and floating events. The bounded search only replaces a plan with a full witness.
        if missing.values.contains(where: { $0 > 0 }), jointSearchSupported,
           let solution = ScheduleFeasibilitySearch.find(
            queues: ordered.map { course in
                .init(courseID: course.id, start: minute(calendar.startOfDay(for: course.startDate)),
                      end: minute(instant(day: course.deadline, minute: 1440)),
                      work: allWork[course.id, default: []].map { .init(minutes: $0.minutes, lessonID: $0.lessonID, lessonName: $0.lessonName) })
            },
            study: hardDays.flatMap(\.free).map { .init(start: minute($0.start), end: Int(floor($0.end.timeIntervalSinceReferenceDate / 60))) },
            eventWindows: eventWindows, floating: floatingJobs, floor: minute(nextMinute), initial: minute(today)) {
            tasks = solution.tasks
            for i in originalDays.indices {
                let jobs = floatingJobs.filter { calendar.isDate($0.key, inSameDayAs: originalDays[i].date) }
                let reserved: [Span] = jobs.compactMap { job in
                    guard let start = solution.floatingStarts[job.key] else { return nil }
                    return .init(start: Date(timeIntervalSinceReferenceDate: Double(start) * 60),
                                 end: Date(timeIntervalSinceReferenceDate: Double(start + job.minutes) * 60))
                }
                originalDays[i].free = subtract(reserved, from: hardDays[i].free)
                days[i].free = subtract(tasks.map { buffered(start: $0.start, end: $0.end) }, from: originalDays[i].free)
            }
            missing = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, 0) })
            adjustments.append("已联合调整浮动事项在原窗口内的位置与课程分配，保持截止日期和整节课顺序。")
        }
        // Rebuild the feasible allocation day by day. Unlike merely shuffling one interval,
        // this gives equal-priority courses a share of days that were filled by a single course.
        // Keep the original allocation unless every booked block fits in the new arrangement.
        if (courses.count < 3 && (hasDailyBoost || courses.count == 2))
            || (!defaultOrder && priorities.orderedRules.first != .diversity) {
            var queues: [UUID: [ScheduledTask]] = [:]
            var positions: [UUID: Int] = [:], remaining: [UUID: Int] = [:], booked: [UUID: Int] = [:]
            var futureCapacity: [UUID: [Int]] = [:]
            for course in ordered {
                let ranks = Dictionary(uniqueKeysWithValues: state.lessonWorkItems(for: course).enumerated().map { ($0.element.id, $0.offset) })
                let queue = tasks.filter { $0.courseID == course.id }.sorted {
                    if let a = $0.lessonID, let b = $1.lessonID, let ra = ranks[a], let rb = ranks[b], ra != rb { return ra < rb }
                    return $0.start < $1.start
                }
                queues[course.id] = queue; positions[course.id] = 0
                let minutes = queue.reduce(0) { $0 + $1.durationMinutes }
                remaining[course.id] = minutes; booked[course.id] = minutes
                var capacity = [Int](repeating: 0, count: originalDays.count + 1)
                for index in originalDays.indices.reversed() {
                    capacity[index] = capacity[index + 1] + (eligible(course, originalDays[index].date)
                        ? originalDays[index].free.reduce(0) { $0 + $1.minutes } : 0)
                }
                futureCapacity[course.id] = capacity
            }
            var mixed: [ScheduledTask] = []
            var nextStart = Date.distantPast
            for (index, day) in originalDays.enumerated() {
                var daily: [UUID: Int] = [:]
                var previous: UUID?
                for span in day.free {
                    var time = max(span.start, nextStart)
                    while time < span.end {
                        let available = Int(span.end.timeIntervalSince(time) / 60)
                        var candidates = ordered.filter { course in
                            let position = positions[course.id]!
                            return eligible(course, day.date) && position < queues[course.id]!.count
                                && queues[course.id]![position].durationMinutes <= available
                        }
                        if !defaultOrder && priorities.orderedRules.first == .balancedLoad {
                            // An even daily pace may leave room today only when later
                            // learnable days can still hold the booked whole blocks.
                            candidates = candidates.filter { course in
                                let target = max(1, demands[course.id]!.averageMinutesPerDay)
                                return Double(daily[course.id, default: 0]) < target
                                    || remaining[course.id]! > futureCapacity[course.id]![index + 1]
                            }
                        }
                        let selected = candidates.min { a, b in
                            let urgentA = remaining[a.id]! > futureCapacity[a.id]![index + 1]
                            let urgentB = remaining[b.id]! > futureCapacity[b.id]![index + 1]
                            if urgentA != urgentB { return urgentA }
                            if urgentA && calendar.startOfDay(for: a.deadline) != calendar.startOfDay(for: b.deadline) {
                                return a.deadline < b.deadline
                            }
                            if !defaultOrder {
                                for rule in priorities.orderedRules {
                                    switch rule {
                                    case .diversity:
                                        if (daily[a.id] == nil) != (daily[b.id] == nil) { return daily[a.id] == nil }
                                    case .dailyWeight:
                                        if hasDailyBoost {
                                            let targetA = max(1, demands[a.id]!.averageMinutesPerDay * a.dailyWeight)
                                            let targetB = max(1, demands[b.id]!.averageMinutesPerDay * b.dailyWeight)
                                            let loadA = (Double(daily[a.id, default: 0]) + Double(queues[a.id]![positions[a.id]!].durationMinutes) / 2) / targetA
                                            let loadB = (Double(daily[b.id, default: 0]) + Double(queues[b.id]![positions[b.id]!].durationMinutes) / 2) / targetB
                                            if loadA != loadB { return loadA < loadB }
                                        }
                                    case .coursePriority:
                                        if a.priority != b.priority { return a.priority > b.priority }
                                    case .balancedLoad:
                                        let loadA = daily[a.id, default: 0], loadB = daily[b.id, default: 0]
                                        if loadA != loadB { return loadA < loadB }
                                        let progressA = Double(booked[a.id]! - remaining[a.id]!) / Double(max(1, booked[a.id]!))
                                        let progressB = Double(booked[b.id]! - remaining[b.id]!) / Double(max(1, booked[b.id]!))
                                        if progressA != progressB { return progressA < progressB }
                                    }
                                }
                                return false
                            }
                            // Even with only two courses, ordinary priority must not
                            // monopolize a day when the other course can also fit.
                            let tripleDay = courses.contains { $0.dailyWeight == 3 && daily[$0.id] != nil }
                            if !tripleDay && a.dailyWeight < 3 && b.dailyWeight < 3
                                && (daily[a.id] == nil) != (daily[b.id] == nil) {
                                return daily[a.id] == nil
                            }
                            if hasDailyBoost {
                                // Compare progress toward each course's daily target,
                                // including half the next block so a boost also matters
                                // when only one whole lesson fits into a day.
                                let targetA = max(1, demands[a.id]!.averageMinutesPerDay * a.dailyWeight)
                                let targetB = max(1, demands[b.id]!.averageMinutesPerDay * b.dailyWeight)
                                let loadA = (Double(daily[a.id, default: 0]) + Double(queues[a.id]![positions[a.id]!].durationMinutes) / 2) / targetA
                                let loadB = (Double(daily[b.id, default: 0]) + Double(queues[b.id]![positions[b.id]!].durationMinutes) / 2) / targetB
                                if loadA != loadB { return loadA < loadB }
                            }
                            if a.priority != b.priority { return a.priority > b.priority }
                            let loadA = daily[a.id, default: 0], loadB = daily[b.id, default: 0]
                            if loadA != loadB { return loadA < loadB }
                            if (a.id == previous) != (b.id == previous) { return a.id != previous }
                            let progressA = Double(booked[a.id]! - remaining[a.id]!) / Double(max(1, booked[a.id]!))
                            let progressB = Double(booked[b.id]! - remaining[b.id]!) / Double(max(1, booked[b.id]!))
                            if progressA != progressB { return progressA < progressB }
                            // `ordered` supplies a stable deadline/demand/ID tie-break.
                            return false
                        }
                        guard let selected else { break }
                        var task = queues[selected.id]![positions[selected.id]!]
                        task.start = time; mixed.append(task); time = task.end.addingTimeInterval(breakSeconds); nextStart = time
                        positions[selected.id]! += 1; remaining[selected.id]! -= task.durationMinutes
                        daily[selected.id, default: 0] += task.durationMinutes; previous = selected.id
                    }
                }
            }
            if mixed.count == tasks.count {
                tasks = mixed
                for index in days.indices {
                    let occupied = tasks.map { buffered(start: $0.start, end: $0.end) }
                    days[index].free = subtract(occupied, from: originalDays[index].free)
                }
            } else if !defaultOrder {
                adjustments.append("为保留截止日前已排入的整节课，自定义权重在空间不足处已让步。")
            }
        }
        let dateIndices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.date, $0.offset) })
        var totals = [Int](repeating: 0, count: days.count)
        var loads: [UUID: [Int]] = [:]
        for course in courses { loads[course.id] = [Int](repeating: 0, count: days.count) }
        for task in tasks {
            let i = dateIndices[calendar.startOfDay(for: task.start)]!
            totals[i] += task.durationMinutes; loads[task.courseID]![i] += task.durationMinutes
        }
        // Every move strictly decreases that course's sum of squared daily loads, so this terminates.
        // Never take away a booked block to balance another course: feasibility is preserved.
        var changed = courses.count < 3 && defaultOrder
        while changed {
            changed = false
            for t in tasks.indices {
                let task = tasks[t]
                if task.lessonID != nil { continue }
                let course = courses.first { $0.id == task.courseID }!
                let source = dateIndices[calendar.startOfDay(for: task.start)]!
                let size = task.durationMinutes
                let candidates = days.indices.filter {
                    $0 != source && eligible(course, days[$0].date) &&
                    (preferredDays[course.id]?.contains(days[$0].date) ?? true) &&
                    loads[course.id]![source] - loads[course.id]![$0] > size &&
                    days[$0].free.contains { $0.minutes >= size }
                }
                let target = candidates.min {
                    let a = loads[course.id]![$0], b = loads[course.id]![$1]
                    if a != b { return a < b }
                    if totals[$0] != totals[$1] { return totals[$0] < totals[$1] }
                    return $0 < $1
                }
                if let target, let start = take(size, on: target) {
                    tasks[t].start = start
                    let occupied = tasks.map { buffered(start: $0.start, end: $0.end) }
                    for d in days.indices { days[d].free = subtract(occupied, from: originalDays[d].free) }
                    totals[source] -= size; totals[target] += size
                    loads[course.id]![source] -= size; loads[course.id]![target] += size
                    changed = true
                }
            }
        }
        // Compact and interleave within each original free interval. Moving blocks during
        // balancing may leave holes; compacting keeps a day's schedule useful and predictable.
        var packed: [ScheduledTask] = []
        var nextStart = Date.distantPast
        for day in originalDays {
            var previous: UUID?
            for span in day.free {
                var pool = tasks.filter { $0.start >= span.start && $0.end <= span.end }.sorted { $0.start < $1.start }
                var time = max(span.start, nextStart)
                while !pool.isEmpty {
                    let priority = courses.first { $0.id == pool[0].courseID }!.priority
                    let pick = defaultOrder ? (pool.firstIndex { task in
                        task.courseID != previous && courses.first { $0.id == task.courseID }!.priority == priority
                    } ?? 0) : 0
                    var item = pool.remove(at: pick)
                    item.start = time; time = item.end.addingTimeInterval(breakSeconds); nextStart = time; previous = item.courseID
                    packed.append(item)
                }
            }
        }
        tasks = packed.sorted { $0.start < $1.start }
        // A recorded start should produce a usable timetable from the first free
        // window, even if daily balancing emptied earlier windows. Pull today's
        // tasks forward in their existing order; every move ends no later than
        // the old placement, preserving feasibility and lesson order.
        if actualStart != nil, let todayPlan = originalDays.first {
            var cursor = Date.distantPast
            for i in tasks.indices where calendar.isDate(tasks[i].start, inSameDayAs: today) {
                let seconds = Double(tasks[i].durationMinutes * 60)
                if let span = todayPlan.free.first(where: { max($0.start, cursor).addingTimeInterval(seconds) <= $0.end }) {
                    tasks[i].start = max(span.start, cursor)
                    cursor = tasks[i].end.addingTimeInterval(breakSeconds)
                }
            }
        }
        for i in tasks.indices {
            let task = tasks[i]
            let affected = floatingRegions.filter { $0.start < task.end && $0.end > task.start }
            if !affected.isEmpty {
                tasks[i].floatingWindowStart = min(task.start, affected.map(\.start).min()!)
                tasks[i].floatingWindowEnd = max(task.end, affected.map(\.end).max()!)
            }
        }
        tasks = state.applyingDailyTaskOrders(to: tasks, calendar: calendar)
        for i in tasks.indices {
            let t = tasks[i]
            let base = "task|\(t.courseID.uuidString)|\(Int64(t.start.timeIntervalSinceReferenceDate))|\(t.durationMinutes)" + (t.lessonID.map { "|" + $0 } ?? "")
            var generated = stablePlannerID(base)
            let replacement = state.tasks.contains { !$0.isUnconfirmed && ($0.id == generated ||
                ($0.courseID == t.courseID && $0.start == t.start && $0.durationMinutes == t.durationMinutes && $0.lessonID == t.lessonID)) }
            if replacement {
                generated = stablePlannerID(base + "|confirmed|" + state.tasks.filter { !$0.isUnconfirmed && $0.courseID == t.courseID }.map { $0.id.uuidString }.sorted().joined(separator: ","))
            }
            let previous = state.tasks.first { $0.isUnconfirmed && $0.courseID == t.courseID && $0.start == t.start && $0.durationMinutes == t.durationMinutes && $0.lessonID == t.lessonID }
            tasks[i].id = previous?.id ?? generated
            tasks[i].replacesConfirmedBlock = previous?.replacesConfirmedBlock ?? (replacement ? true : nil)
        }
        for i in tasks.indices { tasks[i].status = calendar.isDate(tasks[i].start, inSameDayAs: today) ? .planned : .future }
        var risks: [ScheduleRisk] = []
        for cutoff in Set(courses.map { calendar.startOfDay(for: $0.deadline) }).sorted() {
            let group = courses.filter { calendar.startOfDay(for: $0.deadline) <= cutoff }
            let absent = group.reduce(0) { $0 + (missing[$1.id] ?? 0) }
            guard absent > 0 else { continue }
            let capacity = originalDays.filter { day in day.date <= cutoff && group.contains { eligible($0, day.date) } }.reduce(0) { $0 + $1.free.reduce(0) { $0 + $1.minutes } }
            risks.append(.init(deadline: cutoff, requiredMinutes: group.reduce(0) { $0 + required[$1.id, default: 0] }, availableMinutes: capacity,
                               unscheduledMinutes: absent, courseNames: group.filter { missing[$0.id, default: 0] > 0 }.map(\.name)))
        }
        var result = ScheduleResult(tasks: tasks, risks: risks, demands: demands, diagnostics: Array(Set(diagnostics)).sorted())
        result.adjustments = adjustments
        result.dayPlans = originalDays.map { day in
            .init(date: day.date, availableMinutes: day.free.reduce(0) { $0 + $1.minutes },
                  plannedMinutes: tasks.filter { calendar.isDate($0.start, inSameDayAs: day.date) }.reduce(0) { $0 + $1.durationMinutes })
        }
        // Ignoring floating occupancy and breaks gives an optimistic upper bound.
        // Only a deficit against that bound is a proven shortage.
        if !courses.contains(where: { calendar.startOfDay(for: $0.deadline) > horizon }) {
            for start in Set([today] + courses.map { max(today, calendar.startOfDay(for: $0.startDate)) }).sorted() {
                for end in Set(courses.map { calendar.startOfDay(for: $0.deadline) }).sorted() {
                    let group = courses.filter { max(today, calendar.startOfDay(for: $0.startDate)) >= start && calendar.startOfDay(for: $0.deadline) <= end }
                    let needed = group.reduce(0) { $0 + required[$1.id, default: 0] }
                    let upper = hardDays.filter { $0.date >= start && $0.date <= end }.reduce(0) { $0 + $1.free.reduce(0) { $0 + $1.minutes } }
                    if needed > upper {
                        result.conflicts.append(.init(windowStart: start, deadline: end, requiredMinutes: needed,
                                                      availableMinutes: upper, courseNames: group.map(\.name)))
                    }
                }
            }
            for course in courses {
                let longest = hardDays.filter { eligible(course, $0.date) }.flatMap(\.free).map(\.minutes).max() ?? 0
                if let blocked = allWork[course.id]?.first(where: { $0.minutes > longest }) {
                    result.conflicts.append(.init(windowStart: max(today, calendar.startOfDay(for: course.startDate)), deadline: course.deadline,
                                                  requiredMinutes: blocked.minutes, availableMinutes: longest, courseNames: [course.name],
                                                  minimumContinuousMinutes: blocked.minutes))
                }
            }
        }
        return result
    }
}

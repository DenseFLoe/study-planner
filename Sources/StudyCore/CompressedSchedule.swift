import Foundation

public struct CompressedCourseFinish: Identifiable, Codable, Sendable {
    public var id: UUID { course.id }
    public let course: Course
    public let remainingMinutes: Int
    public let finish: Date?
}

public struct CompressedFixedOccurrence: Identifiable, Codable, Sendable {
    public var id: String { "\(event.id)|\(start.timeIntervalSinceReferenceDate)" }
    public let event: FixedEvent
    public let start: Date
    public let end: Date
}

public struct CompressedSchedule: Codable, Sendable {
    public let capturedAt: Date
    public let courses: [CompressedCourseFinish]
    public let tasks: [ScheduledTask]
    public let fixed: [CompressedFixedOccurrence]
    public var finish: Date? { tasks.last?.end }
}

public enum CompressedScheduleError: Error, LocalizedError {
    case invalidSettings, invalidEvent, invalidCourse(String), horizon
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: "请设置有效的每日学习时段后再计算。"
        case .invalidEvent: "固定事项存在无效时间或无法同时容纳的安排，请先调整固定课表。"
        case .invalidCourse(let name): "「\(name)」的课节时长与剩余总量不一致，请先核对课程，避免把课节拆成普通时间块。"
        case .horizon: "未来十年内无法排完完整课节；请检查课节时长和每日连续学习时段。"
        }
    }
}

/// Single-machine non-preemptive makespan minimization with ordered course queues
/// and calendar non-availability. Exact feasibility search + binary search on Cmax.
/// No rest, old course deadlines, release dates, daily weights, or draft reservations.
/// A lesson is never split. Non-lesson courses use their existing minimum blocks.
public struct CompressedScheduleEngine: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    private struct Span: Sendable { var start: Int; var end: Int }
    private struct Work: Sendable { var minutes: Int; var id: String? = nil; var name: String? = nil }
    private struct Queue: Sendable { var course: Course; var work: [Work] }
    private struct Event: Sendable { var event: FixedEvent; var day: Date; var start: Int; var end: Int; var minutes: Int }
    private struct Model {
        var study: [Span] = []
        var eventWindows: [Span] = []
        var events: [Event] = []
        var exact: [CompressedFixedOccurrence] = []
    }
    private struct Key: Hashable {
        var positions: [Int]
        var group: Int
        var pending: [Int]
    }
    private struct Step { var choice: Int; var start: Int; var minutes: Int }
    private struct Witness { var steps: [Step]; var finish: Int }
    private enum SearchResult { case found(Witness), impossible, unknown }

    public func calculate(state: PlannerState, now: Date,
                          progress: @Sendable (Int) -> Void = { _ in }) throws -> CompressedSchedule {
        try Task.checkCancellation()
        let courses = state.courses.filter { !$0.isArchived }
        var queues: [Queue] = []
        var remaining: [UUID: Int] = [:]
        for course in courses {
            try Task.checkCancellation()
            let minutes = state.remainingMinutes(for: course)
            remaining[course.id] = minutes
            guard minutes > 0 else { continue }
            let lessons = state.lessonWorkItems(for: course).filter { $0.remainingMinutes > 0 }
            var work = lessons.map { Work(minutes: $0.remainingMinutes, id: $0.id, name: $0.name) }
            if work.reduce(0, { $0 + $1.minutes }) != minutes {
                if course.type == .lessonBasedRecorded && (course.manualLessons?.isEmpty == false || course.webCourse != nil || course.mergedSources != nil) {
                    throw CompressedScheduleError.invalidCourse(course.name)
                }
                work = []
                var left = minutes
                let unit = max(1, course.minimumBlockMinutes > 0 ? course.minimumBlockMinutes : state.settings.minimumScheduleUnit)
                while left > 0 {
                    try Task.checkCancellation()
                    let size = min(left, unit)
                    work.append(.init(minutes: size)); left -= size
                }
            }
            queues.append(.init(course: course, work: work))
        }
        func output(_ tasks: [ScheduledTask], _ fixed: [CompressedFixedOccurrence]) -> CompressedSchedule {
            let finishes = Dictionary(grouping: tasks, by: \.courseID).mapValues { $0.map(\.end).max()! }
            return .init(capturedAt: now, courses: courses.map {
                .init(course: $0, remainingMinutes: remaining[$0.id] ?? 0, finish: finishes[$0.id])
            }, tasks: tasks, fixed: fixed)
        }
        guard !queues.isEmpty else { return output([], []) }
        let availability = state.settings.availability
        guard !availability.isEmpty, availability.allSatisfy({
            (1...7).contains($0.weekday) && $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.startMinute < $0.endMinute
        }) else { throw CompressedScheduleError.invalidSettings }
        guard state.fixedEvents.allSatisfy({
            $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.validDuration && $0.endDate >= calendar.startOfDay(for: $0.startDate)
        }) else { throw CompressedScheduleError.invalidEvent }
        let floor = Int(ceil(now.timeIntervalSinceReferenceDate / 60))
        // Rounding the last seconds of a day up must also move the event horizon
        // to tomorrow; yesterday's floating events are already in the past.
        let today = calendar.startOfDay(for: date(floor))
        let total = queues.reduce(0) { $0 + $1.work.reduce(0) { $0 + $1.minutes } }
        func gcd(_ lhs: Int, _ rhs: Int) -> Int {
            var a = lhs, b = rhs
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        let quantum = queues.flatMap(\.work).reduce(0) { gcd($0, $1.minutes) }
        var model = Model(), day = today, days = 0, capacity = 0
        var lower: Int?
        var upper: Witness?
        var nextProbe = 1
        let limit = calendar.date(byAdding: .year, value: 10, to: today)!
        while day < limit && upper == nil {
            try Task.checkCancellation()
            let part = try dayModel(state: state, day: day, floor: floor)
            for span in part.study {
                let usable = (span.end - span.start) / quantum * quantum
                if lower == nil && capacity + usable >= total { lower = span.start + total - capacity }
                capacity += usable
            }
            model.study += part.study; model.eventWindows += part.eventWindows
            model.events += part.events; model.exact += part.exact
            days += 1
            let cutoff = minute(calendar.date(byAdding: .day, value: 1, to: day)!)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            guard capacity >= total, days >= nextProbe || day >= limit else { continue }
            // A budget is used only to obtain an initial feasible upper bound.
            // Unknown never means impossible; all optimality checks below are exhaustive.
            switch try search(queues: queues, model: model, floor: floor, cutoff: cutoff,
                              budget: day >= limit ? nil : 30_000, progress: progress) {
            case .found(let witness): upper = witness
            case .impossible, .unknown: nextProbe = max(days + 1, days * 2)
            }
        }
        guard var best = upper, var lo = lower else { throw CompressedScheduleError.horizon }
        var hi = best.finish
        // Capacity ignoring indivisibility and floating jobs is an admissible lower
        // bound. Feasibility is monotone in the last study minute, so binary search
        // proves the earliest possible end, rather than stopping at a greedy plan.
        while lo < hi {
            try Task.checkCancellation()
            let mid = lo + (hi - lo) / 2
            switch try search(queues: queues, model: model, floor: floor, cutoff: mid, budget: nil, progress: progress) {
            case .found(let witness): best = witness; hi = witness.finish
            case .impossible: lo = mid + 1
            case .unknown: preconditionFailure("Exact search must not return unknown")
            }
        }
        var tasks: [ScheduledTask] = [], fixed = model.exact.filter { $0.start < endOfDay(containing: best.finish - 1) }
        var positions = queues.map { _ in 0 }
        for step in best.steps {
            if step.choice >= 0 {
                let queue = queues[step.choice], work = queue.work[positions[step.choice]]
                positions[step.choice] += 1
                tasks.append(.init(courseID: queue.course.id, start: date(step.start), durationMinutes: work.minutes,
                                   lessonID: work.id, lessonName: work.name))
            } else {
                let event = model.events[-step.choice - 1]
                if event.day < endOfDay(containing: best.finish - 1) {
                    fixed.append(.init(event: event.event, start: date(step.start), end: date(step.start + step.minutes)))
                }
            }
        }
        return output(tasks, fixed.sorted { $0.start < $1.start })
    }

    private func minute(_ date: Date) -> Int { Int(floor(date.timeIntervalSinceReferenceDate / 60)) }
    private func date(_ minute: Int) -> Date { Date(timeIntervalSinceReferenceDate: Double(minute) * 60) }
    private func endOfDay(containing minute: Int) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date(minute)))!
    }
    private func subtract(_ blocks: [Span], from spans: [Span]) -> [Span] {
        var result = spans
        for block in blocks {
            result = result.flatMap { span in
                guard block.start < span.end && block.end > span.start else { return [span] }
                var parts: [Span] = []
                if span.start < block.start { parts.append(.init(start: span.start, end: block.start)) }
                if block.end < span.end { parts.append(.init(start: block.end, end: span.end)) }
                return parts
            }
        }
        return result
    }
    private func dayModel(state: PlannerState, day: Date, floor: Int) throws -> Model {
        let engine = ScheduleEngine(calendar: calendar)
        let start = minute(day), end = minute(calendar.date(byAdding: .day, value: 1, to: day)!)
        let events = state.fixedEvents.filter { $0.occurs(on: day, calendar: calendar) }
        let exact = events.filter { !$0.isFloating }.map {
            CompressedFixedOccurrence(event: $0, start: engine.instant(day: day, minute: $0.startMinute),
                                      end: engine.instant(day: day, minute: $0.endMinute))
        }.sorted { $0.start < $1.start }
        for pair in zip(exact, exact.dropFirst()) where pair.0.end > pair.1.start { throw CompressedScheduleError.invalidEvent }
        let blocks = exact.map { Span(start: minute($0.start), end: minute($0.end)) }
        // Union overlapping study settings before computing capacity.
        let weekday = calendar.component(.weekday, from: day)
        var windows: [Span] = []
        for window in state.settings.availability.filter({ $0.weekday == weekday }).sorted(by: { $0.startMinute < $1.startMinute }) {
            let span = Span(start: max(floor, minute(engine.instant(day: day, minute: window.startMinute))),
                            end: minute(engine.instant(day: day, minute: window.endMinute)))
            guard span.start < span.end else { continue }
            if let last = windows.last, last.end >= span.start { windows[windows.count - 1].end = max(last.end, span.end) }
            else { windows.append(span) }
        }
        return Model(study: subtract(blocks, from: windows), eventWindows: subtract(blocks, from: [.init(start: start, end: end)]),
                     events: events.filter(\.isFloating).sorted { $0.id.uuidString < $1.id.uuidString }.map {
            .init(event: $0, day: day, start: minute(engine.instant(day: day, minute: $0.startMinute)),
                  end: minute(engine.instant(day: day, minute: $0.endMinute)), minutes: $0.occupiedMinutes)
        }, exact: exact)
    }

    private func search(queues: [Queue], model: Model, floor: Int, cutoff: Int, budget: Int?,
                        progress: @Sendable (Int) -> Void) throws -> SearchResult {
        let study = model.study.filter { $0.start < cutoff }.map { Span(start: $0.start, end: min($0.end, cutoff)) }
        let until = endOfDay(containing: cutoff - 1)
        let events = Array(model.events.prefix { $0.day < until })
        var groups: [[Int]] = []
        for index in events.indices {
            if let last = groups.last, events[last[0]].day == events[index].day { groups[groups.count - 1].append(index) }
            else { groups.append([index]) }
        }
        func place(_ spans: [Span], after: Int, minutes: Int, deadline: Int) -> Int? {
            var lo = 0, hi = spans.count
            while lo < hi { let mid = (lo + hi) / 2; if spans[mid].end < after + minutes { lo = mid + 1 } else { hi = mid } }
            for span in spans[lo...] {
                let start = max(after, span.start)
                if start + minutes > deadline { return nil }
                if start + minutes <= span.end { return start }
            }
            return nil
        }
        var suffix: [[Int]] = [], latest: [[Int]] = []
        for queue in queues {
            var sums = [Int](repeating: 0, count: queue.work.count + 1)
            var starts = sums, end = cutoff
            for index in queue.work.indices.reversed() {
                let minutes = queue.work[index].minutes
                sums[index] = sums[index + 1] + minutes
                guard let span = study.last(where: { min(end, $0.end) - minutes >= $0.start }) else { return .impossible }
                starts[index] = min(end, span.end) - minutes; end = starts[index]
            }
            suffix.append(sums); latest.append(starts)
        }
        var eventLatest: [Int] = [], eventCost: [Int] = []
        for event in events {
            try Task.checkCancellation()
            let windows = model.eventWindows.filter { $0.start < event.end && $0.end > event.start }
            var last: Int?, cost = Int.max
            let localStudy = study.filter { $0.start < event.end && $0.end > event.start }
            for window in windows {
                let first = max(window.start, event.start), final = min(window.end, event.end) - event.minutes
                guard first <= final else { continue }
                last = max(last ?? final, final)
                for start in first...final {
                    let overlap = localStudy.reduce(0) { $0 + max(0, min(start + event.minutes, $1.end) - max(start, $1.start)) }
                    cost = min(cost, overlap)
                }
            }
            guard let last else { return .impossible }
            eventLatest.append(last); eventCost.append(cost)
        }
        var futureCosts = [Int](repeating: 0, count: groups.count + 1)
        for g in groups.indices.reversed() { futureCosts[g] = futureCosts[g + 1] + groups[g].reduce(0) { $0 + eventCost[$1] } }
        var seen: [Key: Int] = [:]
        var visits = 0, exhausted = false
        // Earliest end dominates later ends for identical queue/event progress.
        // Enumerating every next course and same-day event is complete: for any
        // feasible chronological order, pushing each job left cannot harm later jobs.
        func expand(_ key: Key, cursor: Int) throws -> [Step]? {
            visits += 1
            if visits % 1024 == 0 { try Task.checkCancellation() }
            if visits % 50_000 == 0 { progress(visits) }
            if let budget, visits > budget { exhausted = true; return nil }
            if let old = seen[key], old <= cursor { return nil }
            seen[key] = cursor
            if key.pending.contains(where: { cursor > eventLatest[$0] }) { return nil }
            var required = 0
            for c in queues.indices where key.positions[c] < queues[c].work.count {
                if max(floor, cursor) > latest[c][key.positions[c]] { return nil }
                required += suffix[c][key.positions[c]]
            }
            let capacity = study.reduce(0) { $0 + max(0, $1.end - max(cursor, $1.start)) }
            let cost = key.pending.reduce(0) { $0 + eventCost[$1] } + (key.group < groups.count ? futureCosts[key.group + 1] : 0)
            if required > capacity - cost { return nil }
            var options: [Step] = []
            for c in queues.indices where key.positions[c] < queues[c].work.count {
                let work = queues[c].work[key.positions[c]]
                if let start = place(study, after: max(floor, cursor), minutes: work.minutes, deadline: cutoff),
                   !key.pending.contains(where: { start + work.minutes > eventLatest[$0] }) {
                    options.append(.init(choice: c, start: start, minutes: work.minutes))
                }
            }
            for index in key.pending {
                let event = events[index]
                if let start = place(model.eventWindows, after: max(cursor, event.start), minutes: event.minutes, deadline: event.end) {
                    options.append(.init(choice: -index - 1, start: start, minutes: event.minutes))
                }
            }
            options.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.minutes != $1.minutes { return $0.minutes > $1.minutes }
                return $0.choice < $1.choice
            }
            return options
        }
        struct Frame {
            var key: Key
            var cursor: Int
            var finish: Int
            var via: Step?
            var options: [Step]?
            var index = 0
        }
        let first = Key(positions: queues.map { _ in 0 }, group: 0, pending: groups.first ?? [])
        var stack = [Frame(key: first, cursor: minute(calendar.startOfDay(for: date(floor))), finish: floor)]
        // An explicit stack avoids overflowing the thread stack on large imports.
        while let frame = stack.last {
            if frame.key.group == groups.count && queues.indices.allSatisfy({ frame.key.positions[$0] == queues[$0].work.count }) {
                return .found(.init(steps: stack.compactMap(\.via), finish: frame.finish))
            }
            if frame.options == nil {
                guard let options = try expand(frame.key, cursor: frame.cursor) else {
                    stack.removeLast()
                    if exhausted { return .unknown }
                    continue
                }
                stack[stack.count - 1].options = options
                continue
            }
            guard frame.index < frame.options!.count else { stack.removeLast(); continue }
            let step = frame.options![frame.index]
            stack[stack.count - 1].index += 1
            var next = frame.key
            if step.choice >= 0 { next.positions[step.choice] += 1 }
            else {
                next.pending.removeAll { $0 == -step.choice - 1 }
                if next.pending.isEmpty {
                    next.group += 1
                    if next.group < groups.count { next.pending = groups[next.group] }
                }
            }
            stack.append(Frame(key: next, cursor: step.start + step.minutes,
                               finish: step.choice >= 0 ? step.start + step.minutes : frame.finish, via: step))
        }
        try Task.checkCancellation()
        progress(visits)
        return exhausted ? .unknown : .impossible
    }
}

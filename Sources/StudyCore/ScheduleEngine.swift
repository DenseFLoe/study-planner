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
}

/// Pure, minute-based local scheduling. No persistence, UI, system Calendar, or EventKit dependencies.
/// Calendar below is Foundation date arithmetic only.
public struct ScheduleEngine: Sendable {
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
        let nextMinute = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 60) * 60)
        let active = state.tasks.filter { $0.start < now && $0.end > now && $0.isUnconfirmed }
        let courses = state.courses.filter { !$0.isArchived && $0.autoScheduleEnabled && state.remainingMinutes(for: $0) > 0 }
        var diagnostics: [String] = []
        let validEvents = state.fixedEvents.filter {
            let valid = $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.endMinute > $0.startMinute && $0.endDate >= calendar.startOfDay(for: $0.startDate)
            if !valid { diagnostics.append("固定事项「\($0.title)」的时间无效，请修改。") }
            return valid
        }
        let availability = state.settings.availability.filter {
            let valid = (1...7).contains($0.weekday) && $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.endMinute > $0.startMinute
            if !valid { diagnostics.append("部分可学习时间设置无效，已忽略。") }
            return valid
        }
        var days: [Day] = []
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
            var blocks = validEvents.filter { $0.occurs(on: day, calendar: calendar) }.map {
                Span(start: instant(day: day, minute: $0.startMinute), end: instant(day: day, minute: $0.endMinute))
            }
            blocks += active.map { Span(start: $0.start, end: $0.end) }
            days.append(.init(date: day, free: subtract(blocks, from: windows)))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let originalDays = days
        var demands: [UUID: CourseDemand] = [:]
        var required: [UUID: Int] = [:]
        func unit(_ course: Course) -> Int { max(1, course.minimumBlockMinutes > 0 ? course.minimumBlockMinutes : state.settings.minimumScheduleUnit) }
        func eligible(_ course: Course, _ day: Date) -> Bool {
            day >= calendar.startOfDay(for: course.startDate) && day <= calendar.startOfDay(for: course.deadline)
        }
        for course in courses {
            let reserved = active.filter { $0.courseID == course.id }.reduce(0) { $0 + $1.durationMinutes }
            let remaining = max(0, state.remainingMinutes(for: course) - reserved)
            required[course.id] = remaining
            let count = days.filter { eligible(course, $0.date) && $0.free.contains(where: { $0.minutes >= min(unit(course), remaining) && remaining > 0 }) }.count
            demands[course.id] = .init(remainingMinutes: remaining, learnableDays: count)
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
        func take(_ minutes: Int, on index: Int) -> Date? {
            guard let slot = days[index].free.firstIndex(where: { $0.minutes >= minutes }) else { return nil }
            let start = days[index].free[slot].start
            days[index].free[slot].start = start.addingTimeInterval(Double(minutes) * 60)
            if days[index].free[slot].minutes == 0 { days[index].free.remove(at: slot) }
            return start
        }
        // Feasibility first: allocate earliest deadlines before distributing load across later days.
        for course in ordered {
            var remaining = required[course.id]!
            for index in days.indices where eligible(course, days[index].date) {
                while remaining > 0 {
                    let size = min(unit(course), remaining)
                    guard let start = take(size, on: index) else { break }
                    tasks.append(.init(courseID: course.id, start: start, durationMinutes: size))
                    remaining -= size
                }
            }
            missing[course.id] = remaining
        }
        // Repair fragmented capacity: evacuate blocking small chunks to other free intervals
        // before declaring a larger chunk unplaceable. A failed attempt rolls back completely.
        var repairAttempts = 0
        for course in ordered {
            var remaining = missing[course.id, default: 0]
            while remaining > 0 && repairAttempts < 200 {
                let size = min(unit(course), remaining)
                var repaired = false
                search: for dayIndex in originalDays.indices where eligible(course, originalDays[dayIndex].date) {
                    for span in originalDays[dayIndex].free where span.minutes >= size {
                        let starts = ([span.start] + tasks.filter { $0.start >= span.start && $0.end < span.end }.map(\.end)).sorted()
                        for start in starts {
                            repairAttempts += 1
                            if repairAttempts > 200 { break search }
                            let reserved = Span(start: start, end: start.addingTimeInterval(Double(size) * 60))
                            guard reserved.end <= span.end else { continue }
                            let blockers = tasks.indices.filter { tasks[$0].start < reserved.end && tasks[$0].end > reserved.start }
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
                                let occupied = untouched.filter { calendar.isDate($0.start, inSameDayAs: days[d].date) }.map { Span(start: $0.start, end: $0.end) }
                                days[d].free = subtract(occupied + [reserved], from: originalDays[d].free)
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
                                tasks.append(.init(courseID: course.id, start: start, durationMinutes: size))
                                remaining -= size; repaired = true
                                break search
                            }
                            days = oldDays; tasks = oldTasks
                        }
                    }
                }
                if !repaired { break }
            }
            missing[course.id] = remaining
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
        var changed = true
        while changed {
            changed = false
            for t in tasks.indices {
                let task = tasks[t]
                let course = courses.first { $0.id == task.courseID }!
                let source = dateIndices[calendar.startOfDay(for: task.start)]!
                let size = task.durationMinutes
                let candidates = days.indices.filter {
                    $0 != source && eligible(course, days[$0].date) &&
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
                    days[source].free = merged(days[source].free + [.init(start: task.start, end: task.end)])
                    tasks[t].start = start
                    totals[source] -= size; totals[target] += size
                    loads[course.id]![source] -= size; loads[course.id]![target] += size
                    changed = true
                }
            }
        }
        // Compact and interleave within each original free interval. Moving blocks during
        // balancing may leave holes; compacting keeps a day's schedule useful and predictable.
        var packed: [ScheduledTask] = []
        for day in originalDays {
            for span in day.free {
                var pool = tasks.filter { $0.start >= span.start && $0.end <= span.end }.sorted { $0.start < $1.start }
                var time = span.start
                var previous: UUID?
                while !pool.isEmpty {
                    let pick = pool.firstIndex { $0.courseID != previous } ?? 0
                    var item = pool.remove(at: pick)
                    item.start = time; time = item.end; previous = item.courseID
                    packed.append(item)
                }
            }
        }
        tasks = packed.sorted { $0.start < $1.start }
        for i in tasks.indices {
            let t = tasks[i]
            let base = "task|\(t.courseID.uuidString)|\(Int64(t.start.timeIntervalSinceReferenceDate))|\(t.durationMinutes)"
            var generated = stablePlannerID(base)
            if state.tasks.contains(where: { !$0.isUnconfirmed && $0.id == generated }) {
                generated = stablePlannerID(base + "|confirmed|" + state.tasks.filter { !$0.isUnconfirmed && $0.courseID == t.courseID }.map { $0.id.uuidString }.sorted().joined(separator: ","))
            }
            tasks[i].id = state.tasks.first(where: { $0.isUnconfirmed && $0.courseID == t.courseID && $0.start == t.start && $0.durationMinutes == t.durationMinutes })?.id
                ?? generated
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
        return .init(tasks: tasks, risks: risks, demands: demands, diagnostics: Array(Set(diagnostics)).sorted())
    }
}

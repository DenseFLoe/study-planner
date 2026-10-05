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
        let nextMinute = Date(timeIntervalSince1970: ceil((actualStart ?? now).timeIntervalSince1970 / 60) * 60)
        let courses = state.courses.filter { !$0.isArchived && $0.autoScheduleEnabled && state.remainingMinutes(for: $0) > 0 }
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
            blocks += state.tasks.filter {
                let replacingToday = actualStart != nil && calendar.isDate($0.start, inSameDayAs: now)
                return $0.planningStart < now && (($0.isUnconfirmed && $0.planningEnd <= now && !replacingToday) || $0.completedMinutes > 0)
            }
                .map { buffered(start: min($0.planningStart, $0.confirmedAt ?? $0.planningStart),
                                end: min($0.planningEnd, $0.confirmedAt ?? $0.planningEnd)) }
            days.append(.init(date: day, free: subtract(blocks, from: windows)))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let originalDays = days
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
        // Rebuild the feasible allocation day by day. Unlike merely shuffling one interval,
        // this gives equal-priority courses a share of days that were filled by a single course.
        // Keep the original allocation unless every booked block fits in the new arrangement.
        if Set(courses.map(\.priority)).count < courses.count {
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
                        let candidates = ordered.filter { course in
                            let position = positions[course.id]!
                            return eligible(course, day.date) && position < queues[course.id]!.count
                                && queues[course.id]![position].durationMinutes <= available
                        }
                        let selected = candidates.min { a, b in
                            let urgentA = remaining[a.id]! > futureCapacity[a.id]![index + 1]
                            let urgentB = remaining[b.id]! > futureCapacity[b.id]![index + 1]
                            if urgentA != urgentB { return urgentA }
                            if urgentA && calendar.startOfDay(for: a.deadline) != calendar.startOfDay(for: b.deadline) {
                                return a.deadline < b.deadline
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
        var changed = true
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
                    let pick = pool.firstIndex { task in
                        task.courseID != previous && courses.first { $0.id == task.courseID }!.priority == priority
                    } ?? 0
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
            if state.tasks.contains(where: { !$0.isUnconfirmed && $0.id == generated }) {
                generated = stablePlannerID(base + "|confirmed|" + state.tasks.filter { !$0.isUnconfirmed && $0.courseID == t.courseID }.map { $0.id.uuidString }.sorted().joined(separator: ","))
            }
            tasks[i].id = state.tasks.first(where: { $0.isUnconfirmed && $0.courseID == t.courseID && $0.start == t.start && $0.durationMinutes == t.durationMinutes && $0.lessonID == t.lessonID })?.id
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

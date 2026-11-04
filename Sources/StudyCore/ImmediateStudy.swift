import Foundation

public struct ImmediateStudyRequest: Codable, Equatable, Sendable {
    public var task: ScheduledTask
    /// A short first segment keeps the rest of that lesson ahead of its course's queue.
    public var continuesLesson: Bool? = nil
}

/// A pinned task always has an actual interval. Some repeated-hour intervals
/// cannot also be expressed by one same-day pair of clock-minute bounds.
struct ImmediateStudyReservation: Sendable {
    var start: Date
    var end: Date
    var nominalEvent: FixedEvent?
}

private func mergedImmediateIntervals(_ spans: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
    var result: [(start: Date, end: Date)] = []
    for span in spans.filter({ $0.start < $0.end }).sorted(by: { $0.start < $1.start }) {
        if let last = result.last, span.start <= last.end {
            result[result.count - 1].end = max(last.end, span.end)
        } else { result.append(span) }
    }
    return result
}

private func subtractImmediateIntervals(_ blocks: [(start: Date, end: Date)],
                                        from spans: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
    var result = mergedImmediateIntervals(spans)
    for block in mergedImmediateIntervals(blocks) {
        result = result.flatMap { span -> [(start: Date, end: Date)] in
            guard block.start < span.end, block.end > span.start else { return [span] }
            var parts: [(start: Date, end: Date)] = []
            if span.start < block.start { parts.append((span.start, block.start)) }
            if block.end < span.end { parts.append((block.end, span.end)) }
            return parts
        }
    }
    return result
}

public enum ImmediateStudyError: Error, LocalizedError, Equatable {
    case unavailable, unavailableTask, invalidDate, noSpace, noFeasiblePlan, pinnedTask

    public var errorDescription: String? {
        switch self {
        case .unavailable: "请选择已启用自动排课、还有未完成课节的分节研习。"
        case .unavailableTask: "当前课表没有可继续的未确认课程，请查看今天或之后的课表。"
        case .invalidDate: "现在不在这门课程的开始与截止日期内，无法立即学习。"
        case .noSpace: "当前空档不足以安排这次学习：请检查可学习时段、固定事项及已确认学习后的 15 分钟休息。未更改课表。"
        case .noFeasiblePlan: "未能按立即学习约束生成新课表，未更改原安排。请调整可学习时段或固定事项后重试。"
        case .pinnedTask: "这节课是本次从现在开始重排的优先课程，暂不支持交换位置。可用「继续上课」更新开始时间，或选择另一节课重新排课。"
        }
    }
}

extension PlannerState {
    public var immediateStudyCourses: [Course] {
        courses.filter {
            $0.type == .lessonBasedRecorded && !$0.isArchived && $0.autoScheduleEnabled &&
            lessonWorkItems(for: $0).contains { $0.remainingMinutes > 0 }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Matches the course rows in the visible day timeline, including elapsed
    /// but unconfirmed drafts. Fixed events and confirmed history are not courses to resume.
    public func firstUnconfirmedTask(on day: Date, calendar: Calendar = .current) -> ScheduledTask? {
        tasks.filter { task in
            task.isUnconfirmed && calendar.isDate(task.start, inSameDayAs: day) &&
            courses.contains { $0.id == task.courseID && !$0.isArchived }
        }.min { $0.start != $1.start ? $0.start < $1.start : $0.id.uuidString < $1.id.uuidString }
    }

    /// Move the visible first course block to now, preserving its duration and
    /// progress. Publish only after the entire replacement plan is validated.
    @discardableResult
    public mutating func continueStudying(on day: Date, now: Date = Date(),
                                         calendar: Calendar = .current) throws -> ScheduleResult {
        guard calendar.startOfDay(for: day) >= calendar.startOfDay(for: now),
              let task = firstUnconfirmedTask(on: day, calendar: calendar),
              let course = courses.first(where: { $0.id == task.courseID && $0.autoScheduleEnabled }),
              let remaining = immediateStudyRemainingMinutes(for: task),
              (1...1440).contains(task.durationMinutes), remaining >= task.durationMinutes else {
            throw ImmediateStudyError.unavailableTask
        }
        return try scheduleStudyNow(course: course, lessonID: task.lessonID, lessonName: task.lessonName,
                                    minutes: task.durationMinutes, remaining: remaining, allowShortening: false,
                                    now: now, calendar: calendar)
    }

    /// Builds and validates a complete replacement before publishing any mutation.
    @discardableResult
    public mutating func studyImmediately(courseID: UUID, lessonID: String? = nil,
                                         now: Date = Date(), calendar: Calendar = .current) throws -> ScheduleResult {
        guard let course = immediateStudyCourses.first(where: { $0.id == courseID }),
              let lesson = lessonWorkItems(for: course).first(where: {
                  $0.remainingMinutes > 0 && (lessonID == nil || $0.id == lessonID)
              }) else {
            throw ImmediateStudyError.unavailable
        }
        return try scheduleStudyNow(course: course, lessonID: lesson.id, lessonName: lesson.name,
                                    minutes: lesson.remainingMinutes, remaining: lesson.remainingMinutes,
                                    allowShortening: true, now: now, calendar: calendar)
    }

    private mutating func scheduleStudyNow(course: Course, lessonID: String?, lessonName: String?,
                                          minutes: Int, remaining: Int, allowShortening: Bool,
                                          now: Date, calendar: Calendar) throws -> ScheduleResult {
        let start = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 60) * 60)
        let day = calendar.startOfDay(for: start)
        guard day >= calendar.startOfDay(for: course.startDate), day <= calendar.startOfDay(for: course.deadline) else {
            throw ImmediateStudyError.invalidDate
        }
        var next = self
        // This explicit action starts a fresh plan now. An elapsed, unconfirmed
        // draft is not evidence of study and must not impose a rest period.
        let minute = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        try next.recordActualStudyStart(minute: minute, now: start, calendar: calendar)
        // Preserve the explicitly chosen occurrence during a repeated clock hour.
        next.settings.actualStudyStart = start
        guard let free = next.immediateStudyFreeIntervals(on: day, calendar: calendar)
            .first(where: { $0.start <= start && start < $0.end }) else { throw ImmediateStudyError.noSpace }
        let maximum = min(minutes, 1440, Int(floor(free.end.timeIntervalSince(start) / 60)))
        guard maximum > 0, allowShortening || maximum == minutes else { throw ImmediateStudyError.noSpace }
        func fittingTask(_ duration: Int) -> ScheduledTask? {
            let task = ScheduledTask(courseID: course.id, start: start, durationMinutes: duration,
                                     lessonID: lessonID, lessonName: lessonName)
            next.settings.immediateStudy = .init(task: task, continuesLesson: lessonID != nil && duration < remaining ? true : nil)
            return next.validImmediateStudyTask(now: now, calendar: calendar)
        }
        var chosen = fittingTask(maximum)
        if chosen == nil && allowShortening {
            // Floating events may need some of this window. Find a shorter legal
            // first segment, rather than rejecting a lesson that can begin now.
            var low = 1, high = maximum - 1
            while low <= high {
                let middle = (low + high) / 2
                if let task = fittingTask(middle) { chosen = task; low = middle + 1 }
                else { high = middle - 1 }
            }
        }
        guard let task = chosen else { throw ImmediateStudyError.noSpace }
        next.settings.immediateStudy = .init(task: task, continuesLesson: lessonID != nil && task.durationMinutes < remaining ? true : nil)
        let result = next.replan(now: now, calendar: calendar)
        guard result.tasks.contains(where: { $0.id == task.id }) else { throw ImmediateStudyError.noFeasiblePlan }
        self = next
        return result
    }

    public func immediateStudyContinuation(now: Date = Date(), calendar: Calendar = .current) -> LessonWorkItem? {
        guard let request = settings.immediateStudy, request.continuesLesson == true,
              let course = courses.first(where: { $0.id == request.task.courseID && !$0.isArchived && $0.autoScheduleEnabled }),
              calendar.startOfDay(for: now) >= calendar.startOfDay(for: course.startDate),
              calendar.startOfDay(for: now) <= calendar.startOfDay(for: course.deadline) else { return nil }
        return lessonWorkItems(for: course).first { $0.id == request.task.lessonID && $0.remainingMinutes > 0 }
    }

    private func immediateStudyRemainingMinutes(for task: ScheduledTask) -> Int? {
        guard let course = courses.first(where: { $0.id == task.courseID && !$0.isArchived && $0.autoScheduleEnabled }) else { return nil }
        let remaining = remainingMinutes(for: course)
        let lessons = lessonWorkItems(for: course)
        let consistentLessons = !lessons.isEmpty && lessons.reduce(0, { $0 + $1.remainingMinutes }) == remaining
        if let lessonID = task.lessonID {
            guard consistentLessons else { return nil }
            return lessons.first { $0.id == lessonID }?.remainingMinutes
        }
        // Ordinary time blocks are also used when imported lesson totals are inconsistent.
        return consistentLessons ? nil : remaining
    }

    /// The first reserved segment expires at its end or confirmation; hard constraints win.
    func validImmediateStudyTask(now: Date, calendar: Calendar) -> ScheduledTask? {
        guard let task = settings.immediateStudy?.task, task.isUnconfirmed,
              (1...1440).contains(task.durationMinutes), task.start < task.end, task.end > now,
              task.start.timeIntervalSince(now) < 60,
              !tasks.contains(where: { $0.id == task.id && !$0.isUnconfirmed }),
              let course = courses.first(where: { $0.id == task.courseID }),
              let remaining = immediateStudyRemainingMinutes(for: task), remaining >= task.durationMinutes else { return nil }
        let day = calendar.startOfDay(for: task.start)
        let engine = ScheduleEngine(calendar: calendar)
        guard calendar.isDate(task.start, inSameDayAs: now),
              day >= calendar.startOfDay(for: course.startDate), day <= calendar.startOfDay(for: course.deadline),
              task.end <= engine.instant(day: day, minute: 1440),
              task.start >= (settings.actualStudyStart(on: now, calendar: calendar) ?? day) else { return nil }
        guard immediateStudyFreeIntervals(on: day, calendar: calendar).contains(where: {
            task.start >= $0.start && task.end <= $0.end
        }) else { return nil }
        let pause = Double(ScheduleEngine.breakMinutes * 60)
        let anchored = settings.actualStudyStart(on: now, calendar: calendar) != nil
        let history = tasks.filter {
            $0.id != task.id && $0.planningStart < now &&
            (($0.isUnconfirmed && $0.planningEnd <= now && !(anchored && calendar.isDate($0.start, inSameDayAs: now))) || $0.completedMinutes > 0)
        }
        guard !history.contains(where: {
            let span = $0.retainedHistoryInterval
            return task.start < span.end.addingTimeInterval(pause) && task.end > span.start.addingTimeInterval(-pause)
        }) else { return nil }
        guard immediateFloatingEventsFit(task, day: day, calendar: calendar) else { return nil }
        return task
    }

    private func immediateStudyFreeIntervals(on day: Date, calendar: Calendar) -> [(start: Date, end: Date)] {
        let engine = ScheduleEngine(calendar: calendar), end = engine.instant(day: day, minute: 1440)
        let study = settings.availability.filter {
            $0.weekday == calendar.component(.weekday, from: day) && $0.startMinute >= 0 &&
            $0.endMinute <= 1440 && $0.startMinute < $0.endMinute
        }.map {
            (start: max(day, engine.instant(day: day, minute: $0.startMinute)),
             end: min(end, engine.instant(day: day, minute: $0.endMinute)))
        }
        let exact = fixedEvents.filter { !$0.isFloating && $0.occurs(on: day, calendar: calendar) }.map {
            (start: engine.instant(day: day, minute: $0.startMinute), end: engine.instant(day: day, minute: $0.endMinute))
        }
        return subtractImmediateIntervals(exact, from: study)
    }

    private func immediateFloatingEventsFit(_ task: ScheduledTask, day: Date, calendar: Calendar) -> Bool {
        let events = fixedEvents.filter { $0.occurs(on: day, calendar: calendar) }
        let floating = events.filter(\.isFloating)
        guard !floating.isEmpty else { return true }
        let engine = ScheduleEngine(calendar: calendar), dayEnd = engine.instant(day: day, minute: 1440)
        let pin = immediateStudyReservation(task, calendar: calendar)
        let exact = mergedImmediateIntervals(events.filter { !$0.isFloating }.map {
            (start: engine.instant(day: day, minute: $0.startMinute), end: engine.instant(day: day, minute: $0.endMinute))
        } + [(pin.start, pin.end)])
        let available = Set(settings.availability.filter {
            $0.weekday == calendar.component(.weekday, from: day) && $0.startMinute >= 0 &&
            $0.endMinute <= 1440 && $0.startMinute < $0.endMinute
        }.flatMap { Array($0.startMinute..<$0.endMinute) })
        func valid(_ spans: [UUID: (start: Date, end: Date)]) -> Bool {
            let physicalOrder = (Array(spans.values) + exact).sorted { $0.start < $1.start }
            return spans.count == floating.count && floating.allSatisfy { event in
                guard let span = spans[event.id] else { return false }
                return span.end.timeIntervalSince(span.start) >= Double(event.occupiedMinutes) * 60
                    && span.start >= engine.instant(day: day, minute: event.startMinute)
                    && span.end <= engine.instant(day: day, minute: event.endMinute)
                    && span.start >= day && span.end <= dayEnd
            } && zip(physicalOrder, physicalOrder.dropFirst()).allSatisfy { $0.end <= $1.start }
        }
        if let nominal = FloatingPlacement.reserve(events + (pin.nominalEvent.map { [$0] } ?? []), studyMinutes: available) {
            var spans: [UUID: (start: Date, end: Date)] = [:]
            for event in floating {
                guard let start = nominal[event.id] else { return false }
                spans[event.id] = (engine.instant(day: day, minute: start), engine.instant(day: day, minute: start + event.occupiedMinutes))
            }
            if valid(spans) { return true }
        }
        func minute(_ date: Date) -> Int { Int(ceil(date.timeIntervalSinceReferenceDate / 60)) }
        let beginning = minute(day), end = minute(dayEnd)
        let study = immediateStudyFreeIntervals(on: day, calendar: calendar)
        let eventFree = subtractImmediateIntervals(exact, from: [(day, dayEnd)])
        guard let solution = ScheduleFeasibilitySearch.find(
            queues: [.init(courseID: task.courseID, start: beginning, end: end, work: [])],
            study: study.map { .init(start: minute($0.start), end: Int(floor($0.end.timeIntervalSinceReferenceDate / 60))) },
            eventWindows: eventFree.map { .init(start: minute($0.start), end: Int(floor($0.end.timeIntervalSinceReferenceDate / 60))) },
            floating: floating.map { .init(key: day, start: minute(engine.instant(day: day, minute: $0.startMinute)),
                                          end: minute(engine.instant(day: day, minute: $0.endMinute)), minutes: $0.occupiedMinutes) },
            floor: beginning, initial: beginning), solution.tasks.isEmpty, solution.floatingStarts.count == floating.count else { return false }
        var spans: [UUID: (start: Date, end: Date)] = [:]
        for (index, event) in floating.enumerated() {
            guard let start = solution.floatingStarts[index] else { return false }
            spans[event.id] = (Date(timeIntervalSinceReferenceDate: Double(start) * 60),
                               Date(timeIntervalSinceReferenceDate: Double(start + event.occupiedMinutes) * 60))
        }
        return valid(spans)
    }

    func immediateStudyReservation(_ task: ScheduledTask, calendar: Calendar) -> ImmediateStudyReservation {
        let day = calendar.startOfDay(for: task.start), engine = ScheduleEngine(calendar: calendar)
        let dayEnd = engine.instant(day: day, minute: 1440)
        let first = calendar.component(.hour, from: task.start) * 60 + calendar.component(.minute, from: task.start)
        let last = task.end == dayEnd ? 1440 : calendar.component(.hour, from: task.end) * 60 + calendar.component(.minute, from: task.end)
        var reservation = ImmediateStudyReservation(start: task.start, end: task.end, nominalEvent: nil)
        if first < last, task.start >= day, task.end <= dayEnd,
           engine.instant(day: day, minute: first) == task.start, engine.instant(day: day, minute: last) == task.end {
            reservation.nominalEvent = FixedEvent(title: "立即学习", startMinute: first, endMinute: last,
                                                 startDate: day, endDate: day)
        }
        return reservation
    }
}

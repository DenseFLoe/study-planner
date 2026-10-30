import Foundation

public struct ImmediateStudyRequest: Codable, Equatable, Sendable {
    public var task: ScheduledTask
    /// A short first segment keeps the rest of that lesson ahead of its course's queue.
    public var continuesLesson: Bool? = nil
}

public enum ImmediateStudyError: Error, LocalizedError, Equatable {
    case unavailable, invalidDate, noSpace, noFeasiblePlan, pinnedTask

    public var errorDescription: String? {
        switch self {
        case .unavailable: "请选择已启用自动排课、还有未完成课节的不定时录播课程。"
        case .invalidDate: "现在不在这门课程的开始与截止日期内，无法立即学习。"
        case .noSpace: "当前没有可开始学习的空档：现在处于固定事项、可学习时段之外，或已确认学习后的 15 分钟休息内。未更改课表。"
        case .noFeasiblePlan: "未能按立即学习约束生成新课表，未更改原安排。请调整可学习时段或固定事项后重试。"
        case .pinnedTask: "这节课已设为立即学习，优先于拖动顺序。请先取消右侧的立即学习安排，再交换位置。"
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
        let available = Set(settings.availability.filter {
            $0.weekday == calendar.component(.weekday, from: day) && $0.startMinute >= 0 &&
            $0.endMinute <= 1440 && $0.startMinute < $0.endMinute
        }.flatMap { Array($0.startMinute..<$0.endMinute) })
        let exact = fixedEvents.filter { !$0.isFloating && $0.occurs(on: day, calendar: calendar) }
        var stop = minute
        while stop < 1440, available.contains(stop),
              !exact.contains(where: { $0.startMinute <= stop && stop < $0.endMinute }) { stop += 1 }
        let maximum = min(lesson.remainingMinutes, stop - minute)
        guard maximum > 0 else { throw ImmediateStudyError.noSpace }
        func fittingTask(_ duration: Int) -> ScheduledTask? {
            let task = ScheduledTask(courseID: course.id, start: start, durationMinutes: duration,
                                     lessonID: lesson.id, lessonName: lesson.name)
            next.settings.immediateStudy = .init(task: task, continuesLesson: duration < lesson.remainingMinutes ? true : nil)
            return next.validImmediateStudyTask(now: now, calendar: calendar)
        }
        var chosen = fittingTask(maximum)
        if chosen == nil {
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
        next.settings.immediateStudy = .init(task: task, continuesLesson: task.durationMinutes < lesson.remainingMinutes ? true : nil)
        let result = next.replan(now: now, calendar: calendar)
        guard result.tasks.contains(where: { $0.id == task.id }) else { throw ImmediateStudyError.noFeasiblePlan }
        self = next
        return result
    }

    public func immediateStudyContinuation(now: Date = Date(), calendar: Calendar = .current) -> LessonWorkItem? {
        guard let request = settings.immediateStudy, request.continuesLesson == true,
              let course = immediateStudyCourses.first(where: { $0.id == request.task.courseID }),
              calendar.startOfDay(for: now) >= calendar.startOfDay(for: course.startDate),
              calendar.startOfDay(for: now) <= calendar.startOfDay(for: course.deadline) else { return nil }
        return lessonWorkItems(for: course).first { $0.id == request.task.lessonID && $0.remainingMinutes > 0 }
    }

    /// The first reserved segment expires at its end or confirmation; hard constraints win.
    func validImmediateStudyTask(now: Date, calendar: Calendar) -> ScheduledTask? {
        guard let task = settings.immediateStudy?.task, task.isUnconfirmed,
              task.durationMinutes > 0, task.start < task.end, task.end > now,
              task.start.timeIntervalSince(now) < 60,
              !tasks.contains(where: { $0.id == task.id && !$0.isUnconfirmed }),
              let course = immediateStudyCourses.first(where: { $0.id == task.courseID }),
              let lesson = lessonWorkItems(for: course).first(where: { $0.id == task.lessonID && $0.remainingMinutes > 0 }),
              lesson.remainingMinutes >= task.durationMinutes,
              lessonWorkItems(for: course).reduce(0, { $0 + $1.remainingMinutes }) == remainingMinutes(for: course) else { return nil }
        let day = calendar.startOfDay(for: task.start)
        let engine = ScheduleEngine(calendar: calendar)
        guard calendar.isDate(task.start, inSameDayAs: now),
              day >= calendar.startOfDay(for: course.startDate), day <= calendar.startOfDay(for: course.deadline),
              task.end <= engine.instant(day: day, minute: 1440),
              task.start >= (settings.actualStudyStart(on: now, calendar: calendar) ?? day) else { return nil }
        let first = calendar.component(.hour, from: task.start) * 60 + calendar.component(.minute, from: task.start)
        let available = Set(settings.availability.filter {
            $0.weekday == calendar.component(.weekday, from: day) && $0.startMinute >= 0 &&
            $0.endMinute <= 1440 && $0.startMinute < $0.endMinute
        }.flatMap { Array($0.startMinute..<$0.endMinute) })
        guard (first..<(first + task.durationMinutes)).allSatisfy({ available.contains($0) }) else { return nil }
        let events = fixedEvents.filter { $0.occurs(on: day, calendar: calendar) }
        guard !events.contains(where: { !$0.isFloating && first < $0.endMinute && first + task.durationMinutes > $0.startMinute }),
              FloatingPlacement.reserve(events + [immediateStudyReservation(task, calendar: calendar)], studyMinutes: available) != nil else { return nil }
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
        return task
    }

    func immediateStudyReservation(_ task: ScheduledTask, calendar: Calendar) -> FixedEvent {
        let first = calendar.component(.hour, from: task.start) * 60 + calendar.component(.minute, from: task.start)
        return FixedEvent(title: "立即学习", startMinute: first, endMinute: first + task.durationMinutes,
                          startDate: task.start, endDate: task.start)
    }
}

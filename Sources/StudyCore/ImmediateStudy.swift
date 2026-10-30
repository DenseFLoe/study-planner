import Foundation

public struct ImmediateStudyRequest: Codable, Equatable, Sendable {
    public var task: ScheduledTask
}

public enum ImmediateStudyError: Error, LocalizedError, Equatable {
    case unavailable, invalidDate, noSpace, noFeasiblePlan, pinnedTask

    public var errorDescription: String? {
        switch self {
        case .unavailable: "请选择已启用自动排课、还有未完成课节的不定时录播课程。"
        case .invalidDate: "现在不在这门课程的开始与截止日期内，或早于今天设置的实际学习开始时间，无法调换。"
        case .noSpace: "现在无法完整放下这节课及必要的课间休息，或与固定事项、可学习时段冲突，未更改课表。"
        case .noFeasiblePlan: "未找到既能立即上这节课、又能保留各课程截止日前已排入学习量的方案，未更改课表。请换一门课程或调整时段。"
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
        guard day >= calendar.startOfDay(for: course.startDate), day <= calendar.startOfDay(for: course.deadline),
              start >= (settings.actualStudyStart(on: now, calendar: calendar) ?? now) else {
            throw ImmediateStudyError.invalidDate
        }
        var next = self
        let task = ScheduledTask(courseID: course.id, start: start, durationMinutes: lesson.remainingMinutes,
                                 lessonID: lesson.id, lessonName: lesson.name)
        next.settings.immediateStudy = .init(task: task)
        guard next.validImmediateStudyTask(now: now, calendar: calendar) != nil else { throw ImmediateStudyError.noSpace }
        let result = next.replan(now: now, calendar: calendar)
        guard result.tasks.contains(where: { $0.id == task.id }) else { throw ImmediateStudyError.noFeasiblePlan }
        self = next
        return result
    }

    /// A request expires at its end or confirmation; changed hard constraints win.
    func validImmediateStudyTask(now: Date, calendar: Calendar) -> ScheduledTask? {
        guard let task = settings.immediateStudy?.task, task.isUnconfirmed,
              task.durationMinutes > 0, task.start < task.end, task.end > now,
              task.start.timeIntervalSince(now) < 60,
              !tasks.contains(where: { $0.id == task.id && !$0.isUnconfirmed }),
              let course = immediateStudyCourses.first(where: { $0.id == task.courseID }),
              let lesson = lessonWorkItems(for: course).first(where: { $0.id == task.lessonID && $0.remainingMinutes > 0 }),
              lesson.remainingMinutes == task.durationMinutes,
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

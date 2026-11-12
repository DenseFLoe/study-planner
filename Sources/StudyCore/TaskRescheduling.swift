import Foundation

public enum TaskReschedulingError: Error, LocalizedError {
    case unavailable, invalidDate, noSpace, staleWork

    public var errorDescription: String? {
        switch self {
        case .unavailable: "只能移动今天或之后尚未确认、没有学习记录的任务；正在立即学习的课节及其续课不能移动。"
        case .invalidDate: "目标日期须在今天或之后且位于课程起止日期内，指定时间不能早于现在。"
        case .noSpace: "未找到能保留其他任务、完整课节时长和课间休息的目标时段；未修改。请换一个日期或时间。"
        case .staleWork: "该任务的学习量已被其他安排或学习记录覆盖，或课表不符合当前约束；请刷新课表后重试。"
        }
    }
}

extension PlannerState {
    /// Changes exactly one persisted occurrence. A later explicit replan may replace it.
    public mutating func moveTask(_ taskID: UUID, to targetDate: Date, startMinute: Int? = nil,
                                  now: Date = Date(), calendar: Calendar = .current) throws {
        let today = calendar.startOfDay(for: now), day = calendar.startOfDay(for: targetDate)
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[index].isUnconfirmed, tasks[index].completedMinutes == 0,
              !completions.contains(where: { $0.taskID == taskID }),
              calendar.startOfDay(for: tasks[index].start) >= today,
              let course = courses.first(where: { $0.id == tasks[index].courseID && !$0.isArchived && $0.autoScheduleEnabled }) else {
            throw TaskReschedulingError.unavailable
        }
        let source = tasks[index]
        if settings.immediateStudy?.task.id == taskID { throw TaskReschedulingError.unavailable }
        if let continuation = immediateStudyContinuation(now: now, calendar: calendar),
           settings.immediateStudy?.task.courseID == source.courseID, continuation.id == source.lessonID {
            throw TaskReschedulingError.unavailable
        }
        guard day >= today, day >= calendar.startOfDay(for: course.startDate),
              day <= calendar.startOfDay(for: course.deadline),
              startMinute.map({ (0..<1440).contains($0) }) ?? true else { throw TaskReschedulingError.invalidDate }
        let engine = ScheduleEngine(calendar: calendar)
        let nextMinute = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
        let earliest = startMinute.map { engine.instant(day: day, minute: $0) } ?? max(day, nextMinute)
        guard earliest > now, calendar.isDate(earliest, inSameDayAs: day),
              startMinute.map({ calendar.component(.hour, from: earliest) * 60 + calendar.component(.minute, from: earliest) == $0 }) ?? true else {
            throw TaskReschedulingError.invalidDate
        }
        guard var moved = placeSingleTask(source, earliest: earliest, calendar: calendar),
              startMinute == nil || moved.start == earliest else { throw TaskReschedulingError.noSpace }
        // The chosen slot is concrete; do not widen it into a floating window that
        // would visually cover unchanged neighboring tasks.
        moved.floatingWindowStart = nil; moved.floatingWindowEnd = nil
        moved.status = calendar.isDate(moved.start, inSameDayAs: now) ? .planned : .future
        var next = self
        next.tasks[index] = moved
        guard !engine.hasInvalidSavedTasks(state: next, now: now) else { throw TaskReschedulingError.staleWork }
        self = next
    }
}

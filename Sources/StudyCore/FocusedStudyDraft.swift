import Foundation

public enum FocusedStudyError: Error, LocalizedError {
    case unavailable, activeStudy, noSpace, invalidPlan
    public var errorDescription: String? {
        switch self {
        case .unavailable: "所选课程今天不可学习、已完成或课节数据不完整；没有修改。"
        case .activeStudy: "正在立即学习，请先确认本次学习进度，再整体安排；没有修改。"
        case .noSpace: "今天剩余可学时段无法安排这门课程，已保留固定事项、学习记录和休息；没有修改。"
        case .invalidPlan: "整套安排未通过本机约束检查，没有修改。"
        }
    }
}

/// One transaction for a day-level goal. No fake completions or permanent
/// priority/deadline edits: today's reservations are deducted inside the engine.
public struct FocusedStudyDraft: Sendable {
    public let preview: PlannerState
    public let todayTasks: [ScheduledTask]
    public let assessment: ScheduleResult

    public init(state: PlannerState, courseID: UUID, now: Date, earliestStart: Date? = nil, calendar: Calendar = .current) throws {
        let day = calendar.startOfDay(for: now)
        let start = max(now, earliestStart ?? now)
        guard calendar.isDate(start, inSameDayAs: now) else { throw FocusedStudyError.noSpace }
        guard let course = state.courses.first(where: { $0.id == courseID && !$0.isArchived && $0.autoScheduleEnabled }),
              day >= calendar.startOfDay(for: course.startDate), day <= calendar.startOfDay(for: course.deadline),
              state.remainingMinutes(for: course) > 0 else { throw FocusedStudyError.unavailable }
        if let active = state.validImmediateStudyTask(now: now, calendar: calendar), active.start <= now, active.end > now {
            throw FocusedStudyError.activeStudy
        }
        let lessons = state.lessonWorkItems(for: course).filter { $0.remainingMinutes > 0 }
        if course.type == .lessonBasedRecorded,
           lessons.reduce(0, { $0 + $1.remainingMinutes }) != state.remainingMinutes(for: course) {
            throw FocusedStudyError.unavailable
        }
        let unit = max(1, course.minimumBlockMinutes > 0 ? course.minimumBlockMinutes : state.settings.minimumScheduleUnit)
        var work: [(id: String?, name: String?, minutes: Int)] = lessons.map { ($0.id, $0.name, $0.remainingMinutes) }
        if lessons.isEmpty { work = [(nil, nil, state.remainingMinutes(for: course))] }
        let engine = ScheduleEngine(calendar: calendar)
        var next = state
        next.settings.immediateStudy = nil
        next.settings.actualStudyStart = start
        next.settings.dailyTaskOrders?.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        // Today's elapsed unconfirmed drafts are replaceable; real history stays.
        next.tasks.removeAll { $0.isUnconfirmed && ($0.planningEnd > now || calendar.isDate($0.start, inSameDayAs: day)) }
        var placement = next, reserved: [ScheduledTask] = []
        var cursor = Date(timeIntervalSince1970: ceil(start.timeIntervalSince1970 / 60) * 60)
        let end = engine.instant(day: day, minute: 1440)
        outer: for item in work {
            var remaining = item.minutes
            while remaining > 0, cursor < end {
                let prototype = ScheduledTask(courseID: courseID, start: cursor, durationMinutes: 1,
                                              lessonID: item.id, lessonName: item.name)
                guard let first = placement.placeSingleTask(prototype, earliest: cursor, calendar: calendar) else { break outer }
                // Find the longest prefix at the earliest legal start. Shortened
                // lessons retain their identity and their remainder is scheduled later.
                var best = first, low = 2, high = min(remaining, item.id == nil ? unit : 1440)
                while low <= high {
                    let middle = (low + high) / 2
                    var candidate = prototype; candidate.durationMinutes = middle
                    if let fitted = placement.placeSingleTask(candidate, earliest: first.start, calendar: calendar), fitted.start == first.start {
                        best = fitted; low = middle + 1
                    } else { high = middle - 1 }
                }
                best.floatingWindowStart = nil; best.floatingWindowEnd = nil
                reserved.append(best); placement.tasks.append(best)
                remaining -= best.durationMinutes
                cursor = best.end.addingTimeInterval(Double(ScheduleEngine.breakMinutes * 60))
            }
        }
        guard !reserved.isEmpty else { throw FocusedStudyError.noSpace }
        let result = engine.generateAfterToday(state: next, now: now, reserved: reserved)
        next.tasks.append(contentsOf: result.tasks)
        next.tasks.sort { $0.start < $1.start }
        guard !engine.hasInvalidSavedTasks(state: next, now: now) else { throw FocusedStudyError.invalidPlan }
        preview = next; todayTasks = reserved; assessment = result
    }
}

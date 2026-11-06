import Foundation

public enum AssistantScheduleChangeError: LocalizedError {
    case invalid, changed, expired
    public var errorDescription: String? {
        switch self {
        case .invalid: "修改参数无效，未生成日程草稿。"
        case .changed: "日程已有更新，原预览失效，请重新生成并核对。"
        case .expired: "预览已过期或任务已开始，请重新生成并核对。"
        }
    }
}

/// A local, computed draft. Constructing one never writes the planner.
public struct AssistantScheduleChange: Identifiable, Sendable {
    public let id = UUID()
    public let baseline: PlannerState
    public let preview: PlannerState
    public let result: ScheduleResult
    public let title: String
    public let createdAt: Date
    public let calendar: Calendar

    public init(state: PlannerState, action: String, courseID: UUID?, value: String,
                now: Date, calendar: Calendar = .current) throws {
        baseline = state; createdAt = now; self.calendar = calendar
        var next = state
        if action == "replan" {
            guard courseID == nil, value.isEmpty else { throw AssistantScheduleChangeError.invalid }
            title = "重新计算今天及未来未完成的日程"
        } else {
            guard let index = next.courses.firstIndex(where: { $0.id == courseID && !$0.isArchived }) else { throw AssistantScheduleChangeError.invalid }
            let course = next.courses[index]
            switch action {
            case "deadline":
                let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
                format.timeZone = calendar.timeZone; format.locale = Locale(identifier: "en_US_POSIX")
                format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
                guard let day = format.date(from: value), format.string(from: day) == value,
                      day >= calendar.startOfDay(for: max(now, course.startDate)),
                      day <= calendar.date(byAdding: .year, value: 10, to: now)! else { throw AssistantScheduleChangeError.invalid }
                next.courses[index].deadline = day
                title = "「\(course.name)」截止日期：\(format.string(from: course.deadline)) → \(value)"
            case "auto_schedule":
                guard value == "true" || value == "false" else { throw AssistantScheduleChangeError.invalid }
                next.courses[index].autoScheduleEnabled = value == "true"
                title = "「\(course.name)」自动排课：\(course.autoScheduleEnabled ? "开启" : "暂停") → \(value == "true" ? "开启" : "暂停")"
            case "daily_weight":
                guard let weight = Double(value), weight.isFinite, (1...3).contains(weight) else { throw AssistantScheduleChangeError.invalid }
                next.courses[index].dailyStudyWeight = weight
                title = "「\(course.name)」每日倍率：\(course.dailyStudyWeight ?? 1) → \(weight)（偏好，不是硬上限）"
            default: throw AssistantScheduleChangeError.invalid
            }
        }
        result = next.replan(now: now, calendar: calendar)
        preview = next
    }

    private static func comparable(_ state: PlannerState) -> PlannerState {
        var value = state
        value.courses.sort { $0.id < $1.id }; value.tasks.sort { $0.id < $1.id }
        value.fixedEvents.sort { $0.id < $1.id }; value.completions.sort { $0.id < $1.id }
        value.settings.availability.sort { $0.id < $1.id }
        return value
    }
    public func apply(to state: inout PlannerState, now: Date = Date()) throws {
        guard now >= createdAt, now.timeIntervalSince(createdAt) < 300,
              calendar.isDate(now, inSameDayAs: createdAt),
              !baseline.tasks.contains(where: { $0.isUnconfirmed && $0.start > createdAt && $0.start <= now }),
              !preview.tasks.contains(where: { $0.isUnconfirmed && $0.start > createdAt && $0.start < now }) else { throw AssistantScheduleChangeError.expired }
        guard Self.comparable(state) == Self.comparable(baseline) else { throw AssistantScheduleChangeError.changed }
        state = preview
    }
}

import Foundation
import StudyCore

/// Presentation totals use course IDs, not the overlapping deadline risk groups.
struct CourseScheduleAttention: Identifiable {
    var id: UUID { course.id }
    let course: Course
    let remainingMinutes: Int
    let plannedMinutes: Int
    let unplacedMinutes: Int

    static func items(state: PlannerState, result: ScheduleResult) -> [Self] {
        let planned = Dictionary(grouping: result.tasks, by: \.courseID)
            .mapValues { $0.reduce(0) { $0 + $1.durationMinutes } }
        return state.courses.compactMap { course in
            guard !course.isArchived else { return nil }
            let remaining = state.remainingMinutes(for: course)
            guard remaining > 0 else { return nil }
            let placed = course.autoScheduleEnabled ? min(remaining, planned[course.id, default: 0]) : 0
            guard placed < remaining else { return nil }
            return Self(course: course, remainingMinutes: remaining, plannedMinutes: placed,
                        unplacedMinutes: remaining - placed)
        }.sorted { $0.course.deadline < $1.course.deadline }
    }
}

struct ScheduleHealthPresentation {
    let health: ScheduleHealth
    let warningMinutes: Int

    init(health: ScheduleHealth, warningMinutes: Int) {
        self.health = health
        self.warningMinutes = max(30, warningMinutes)
    }

    var title: String {
        switch health.status {
        case .scheduled: "剩余课程已全部安排"
        case .heavy: "课程已排完，部分日期负担偏重"
        case .pending: "课程安排还需要检查"
        case .shortage: "现有学习时间无法满足安排要求"
        }
    }

    var overview: String {
        let planned = max(0, health.remainingMinutes - health.unscheduledMinutes - health.pausedMinutes)
        var text = "剩余学习内容共 \(studyDuration(health.remainingMinutes))，已安排 \(studyDuration(planned))。"
        if health.unscheduledMinutes > 0 { text += "还有 \(studyDuration(health.unscheduledMinutes))未排入日程。" }
        if health.pausedMinutes > 0 { text += "另有 \(studyDuration(health.pausedMinutes))因课程暂停自动排程而未安排。" }
        return text
    }

    var guidance: String {
        switch health.status {
        case .scheduled: "当前课表已覆盖剩余内容，截止日期保持不变。"
        case .heavy: "截止日期保持不变。建议先检查负担较重的日期，再调整可学习时段。"
        case .pending:
            health.unscheduledMinutes > 0
                ? "这表示课表还不完整，并不代表一定来不及学完。先检查下方课程，再调整可学习时段。"
                : "请检查暂停排程的课程或下方提示，再重新核对安排。"
        case .shortage: "已有明确的时间冲突，请按下方原因调整可学习时段、事项或课节安排。"
        }
    }

    var heavyDays: [ScheduleDayPlan] { health.dayPlans.filter { $0.plannedMinutes > warningMinutes } }

    var loadSummary: String {
        guard !health.dayPlans.isEmpty else { return "目前没有已排入的学习任务，暂时无法评估每日负担。" }
        let peak = health.dayPlans.max { $0.plannedMinutes < $1.plannedMinutes }!
        let prefix = heavyDays.isEmpty
            ? "已安排的 \(health.dayPlans.count) 天均未超过每天 \(studyDuration(warningMinutes))的提醒线。"
            : "已安排的日程中，有 \(heavyDays.count) 天超过每天 \(studyDuration(warningMinutes))的提醒线。"
        return prefix + "最重的是 \(studyDate(peak.date))，安排了 \(studyDuration(peak.plannedMinutes))。"
    }

    var recoveryScheduledMinutes: Int { health.recovery.reduce(0) { $0 + $1.plannedMinutes } }
    var recoveryRemainingMinutes: Int { recoveryScheduledMinutes + health.recoveryUnscheduledMinutes }

    var recoverySummary: String {
        guard recoveryRemainingMinutes > 0 else { return "今天确认过的内容中，目前没有仍需补学的部分。" }
        if recoveryScheduledMinutes == 0 {
            return "这批内容还有 \(studyDuration(recoveryRemainingMinutes))需要补学，目前尚未排入课表。请到“课程安排”检查原因。"
        }
        let scheduled = "\(studyDuration(recoveryScheduledMinutes))已排到下面 \(health.recovery.count) 个日期，已包含在每日学习量中，按当天课表学习即可。"
        guard health.recoveryUnscheduledMinutes > 0 else { return scheduled }
        return scheduled + "另外 \(studyDuration(health.recoveryUnscheduledMinutes))还未排入，可到“课程安排”检查原因。"
    }
}

func studyDate(_ date: Date) -> String {
    date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day())
}

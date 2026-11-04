import Foundation
import StudyCore

/// Presentation of the remaining work, rather than the presence of a task ID.
struct LessonSchedulePreviewSummary {
    struct Entry {
        enum Status { case completed, fullyScheduled, partiallyScheduled, unscheduled }

        let remainingMinutes: Int
        let scheduledMinutes: Int
        let segmentCount: Int
        let firstStart: Date?
        let lastEnd: Date?

        var missingMinutes: Int { max(0, remainingMinutes - scheduledMinutes) }
        var status: Status {
            if remainingMinutes == 0 { return .completed }
            if scheduledMinutes == 0 { return .unscheduled }
            return missingMinutes == 0 ? .fullyScheduled : .partiallyScheduled
        }
        var coverageText: String {
            switch status {
            case .completed: return "已看完"
            case .unscheduled: return "未排入 · 尚缺 \(missingMinutes) 分钟"
            case .fullyScheduled: return "已排齐 \(scheduledMinutes) / \(remainingMinutes) 分钟"
            case .partiallyScheduled:
                return "已排入 \(scheduledMinutes) / \(remainingMinutes) 分钟 · 尚缺 \(missingMinutes) 分钟"
            }
        }

        func timingText(calendar: Calendar = .current, locale: Locale = .current) -> String? {
            guard let firstStart, let lastEnd else { return nil }
            let format = Date.FormatStyle(date: .abbreviated, time: .shortened,
                                          locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            let start = firstStart.formatted(format)
            let end = calendar.isDate(firstStart, inSameDayAs: lastEnd)
                ? lastEnd.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                     locale: locale, calendar: calendar, timeZone: calendar.timeZone))
                : lastEnd.formatted(format)
            return "\(segmentCount) 段 · \(start) 至 \(end)"
        }
    }

    let entries: [String: Entry]
    let warning: String?

    var fullyScheduledCount: Int { entries.values.filter { $0.status == .fullyScheduled }.count }
    var partiallyScheduledCount: Int { entries.values.filter { $0.status == .partiallyScheduled }.count }
    var unscheduledCount: Int { entries.values.filter { $0.status == .unscheduled }.count }
    var pendingCount: Int { entries.values.filter { $0.status != .completed }.count }
    var countText: String {
        pendingCount == 0 ? "没有待排课节" :
            "完整排入 \(fullyScheduledCount) 节 · 部分排入 \(partiallyScheduledCount) 节 · 未排入 \(unscheduledCount) 节"
    }

    init(lessons: [LessonWorkItem], course: Course, result: ScheduleResult) {
        let grouped = Dictionary(grouping: result.tasks.filter {
            $0.courseID == course.id && $0.isUnconfirmed && $0.durationMinutes > 0 && $0.lessonID != nil
        }, by: { $0.lessonID! })
        entries = Dictionary(uniqueKeysWithValues: lessons.map { lesson in
            // Completed work is already removed from remainingMinutes. It must
            // neither count as newly scheduled nor change the upcoming dates.
            let segments = lesson.remainingMinutes > 0 ? grouped[lesson.id, default: []] : []
            return (lesson.id, Entry(remainingMinutes: lesson.remainingMinutes,
                                     scheduledMinutes: segments.reduce(0) { $0 + $1.durationMinutes },
                                     segmentCount: segments.count,
                                     firstStart: segments.map(\.start).min(),
                                     lastEnd: segments.map(\.end).max()))
        })
        let missing = entries.values.contains { $0.missingMinutes > 0 }
        let conflict = result.conflicts.contains { $0.courseNames.contains(course.name) }
        let risk = result.risks.contains { $0.courseNames.contains(course.name) }
        if !missing && !conflict && !risk {
            warning = nil
        } else if course.isArchived {
            warning = "此课程已归档，当前不会自动排程。"
        } else if !course.autoScheduleEnabled {
            warning = "此课程已暂停自动排程。"
        } else if conflict {
            warning = "已确认存在时间或连续空档不足，请查看排程详情中的具体原因。"
        } else {
            // Minute coverage itself is enough to warn, even without a risk
            // record. A partial first segment must never hide missing work.
            warning = "当前排法尚未完整，不等于客观上学不完。截止日保持不变，可调整学习时段或课节编排。"
        }
    }
}

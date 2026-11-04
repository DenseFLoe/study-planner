import Foundation
import StudyCore

/// Use the same study-day attribution as the daily forecast. Ambiguous legacy
/// records remain in course progress, but must not be assigned an invented day.
struct ConfirmedStudySummary {
    let minutes: Int?
    let legacyRecordCount: Int
    let ambiguousRecordCount: Int

    init(state: PlannerState, day: Date, calendar: Calendar = .current) {
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        minutes = try? analyzer.confirmed(on: day, state: state)
        var legacy = 0
        var ambiguous = 0
        let tasks = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in state.completions {
            if let effective = analyzer.effectiveDay(record, state: state) {
                if effective.legacy && calendar.isDate(effective.date, inSameDayAs: day) { legacy += 1 }
            } else if calendar.isDate(record.recordedAt, inSameDayAs: day) ||
                        tasks[record.taskID].map({ calendar.isDate($0.start, inSameDayAs: day) }) == true {
                ambiguous += 1
            }
        }
        legacyRecordCount = legacy
        ambiguousRecordCount = ambiguous
    }

    var value: String { minutes.map(studyDuration) ?? "合计超出范围" }

    var note: String {
        var parts = ["实际已学按实际学习日期统计；待学计划随重排更新。"]
        if legacyRecordCount > 0 {
            parts.append("其中 \(legacyRecordCount) 条旧记录按同日确认时间归属。")
        }
        if ambiguousRecordCount > 0 {
            parts.append("另有 \(ambiguousRecordCount) 条旧记录无法确定学习日期，未计入当日；课程总进度保留。")
        }
        if minutes == nil { parts.append("当日合计超出可显示范围，请核对记录。") }
        return parts.joined(separator: " ")
    }
}

/// Display integer minutes without asking the user to convert decimal hours.
/// Keep the existing hours formatter for totals and existing reports.
func studyDuration(_ minutes: Int) -> String {
    let hour = minutes / 60
    let minute = minutes % 60
    if hour == 0 { return "\(minute) 分钟" }
    if minute == 0 { return "\(hour) 小时" }
    return "\(hour) 小时 \(minute) 分"
}

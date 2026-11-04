import Foundation

/// Actual study time is attributed to the recorded study day, independently of
/// the current plan, archived courses, and the date a confirmation was entered.
public enum WeeklyActualStudySeries {
    public struct Summary: Sendable {
        public let chart: WeeklyChartSeries.Summary
        /// All ambiguous legacy history, not an estimate for the selected week.
        /// Nil means that this separate total cannot be represented safely.
        public let undatedMinutes: Int?
    }

    private static func add(_ total: Int?, _ minutes: Int) -> Int? {
        guard let total, minutes >= 0 else { return nil }
        let sum = total.addingReportingOverflow(minutes)
        return sum.overflow ? nil : sum.partialValue
    }

    public static func summary(state: PlannerState, weekStart: Date, calendar: Calendar = .current) -> Summary {
        guard let end = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
            return Summary(chart: .init(segments: [], totalMinutes: nil), undatedMinutes: nil)
        }
        let courses = Dictionary(state.courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tasks = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        var grouped: [Int: [UUID: Int]] = [:]
        var total: Int? = 0, undated: Int? = 0
        for record in state.completions {
            guard let date = analyzer.effectiveDay(record, task: tasks[record.taskID])?.date else {
                undated = add(undated, record.minutes); continue
            }
            guard date >= weekStart, date < end,
                  let day = calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: date)).day,
                  (0..<7).contains(day) else { continue }
            total = add(total, record.minutes)
            guard total != nil else { continue }
            // A nonnegative segment cannot exceed the checked whole-week sum.
            if record.minutes > 0 { grouped[day, default: [:]][record.courseID, default: 0] += record.minutes }
        }
        guard total != nil else {
            return Summary(chart: .init(segments: [], totalMinutes: nil), undatedMinutes: undated)
        }
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        let segments = grouped.flatMap { day, values in
            values.map { id, minutes in
                WeeklyBarSegment(dayIndex: day, dayLabel: labels[day], courseID: id,
                                 courseName: courses[id]?.name ?? "已删除课程", minutes: minutes)
            }
        }.sorted {
            if $0.dayIndex != $1.dayIndex { return $0.dayIndex < $1.dayIndex }
            if $0.courseName != $1.courseName { return $0.courseName < $1.courseName }
            return $0.courseID.uuidString < $1.courseID.uuidString
        }
        return Summary(chart: .init(segments: segments, totalMinutes: total), undatedMinutes: undated)
    }
}

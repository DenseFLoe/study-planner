import Foundation

public struct WeeklyBarSegment: Identifiable, Equatable, Sendable {
    public let dayIndex: Int
    public let dayLabel: String
    public let courseID: UUID
    public let courseName: String
    public let minutes: Int
    public var id: String { "\(dayIndex)-\(courseID.uuidString)" }

    public init(dayIndex: Int, dayLabel: String, courseID: UUID, courseName: String, minutes: Int) {
        self.dayIndex = dayIndex; self.dayLabel = dayLabel; self.courseID = courseID
        self.courseName = courseName; self.minutes = minutes
    }
}

/// Read-only planned time. Missing course rows and dates outside this week keep
/// the chart's existing visibility policy; actual study dates are a separate metric.
public enum WeeklyChartSeries {
    public struct Summary: Sendable {
        public let segments: [WeeklyBarSegment]
        /// Nil means the selected week's total cannot be represented safely.
        public let totalMinutes: Int?
    }

    /// Every series must appear in the chart's style domain, including same-named courses.
    public static func ids(in segments: [WeeklyBarSegment]) -> [UUID] {
        var seen = Set<UUID>()
        return segments.map(\.courseID).filter { seen.insert($0).inserted }
    }

    public static func segments(tasks: [ScheduledTask], courses: [Course], weekStart: Date,
                                calendar: Calendar) -> [WeeklyBarSegment] {
        summary(tasks: tasks, courses: courses, weekStart: weekStart, calendar: calendar).segments
    }

    public static func summary(tasks: [ScheduledTask], courses: [Course], weekStart: Date,
                               calendar: Calendar) -> Summary {
        guard let end = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
            return Summary(segments: [], totalMinutes: nil)
        }
        let byID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [Int: [UUID: Int]] = [:]
        var total = 0
        for task in tasks where task.start >= weekStart && task.start < end {
            guard byID[task.courseID] != nil else { continue }
            let day = calendar.dateComponents([.day], from: weekStart,
                                              to: calendar.startOfDay(for: task.start)).day ?? 0
            guard (0..<7).contains(day) else { continue }
            let old = grouped[day]?[task.courseID] ?? 0
            let segment = old.addingReportingOverflow(task.durationMinutes)
            let sum = total.addingReportingOverflow(task.durationMinutes)
            guard task.durationMinutes >= 0, !segment.overflow, !sum.overflow else {
                // Do not render a partial graph as though it were a complete weekly total.
                return Summary(segments: [], totalMinutes: nil)
            }
            grouped[day, default: [:]][task.courseID] = segment.partialValue
            total = sum.partialValue
        }
        let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        let segments = grouped.flatMap { day, totals in
            totals.map { id, minutes in
                WeeklyBarSegment(dayIndex: day, dayLabel: dayNames[day], courseID: id,
                                 courseName: byID[id]!.name, minutes: minutes)
            }
        }.sorted {
            if $0.dayIndex != $1.dayIndex { return $0.dayIndex < $1.dayIndex }
            if $0.courseName != $1.courseName { return $0.courseName < $1.courseName }
            return $0.courseID.uuidString < $1.courseID.uuidString
        }
        return Summary(segments: segments, totalMinutes: total)
    }
}

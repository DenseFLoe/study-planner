import Foundation

public enum ScheduleSearchScope: String, CaseIterable, Identifiable, Sendable {
    case upcoming = "接下来", history = "历史", all = "全部"
    public var id: Self { self }
    public var explanation: String {
        switch self {
        case .upcoming: "今天及以后的未确认安排 · 最近的在前"
        case .history: "已确认记录与往日安排 · 最近的在前"
        case .all: "全部已排日程 · 按日期从早到晚"
        }
    }
}

public enum ScheduleSearch {
    public static func matches(query: String, tasks: [ScheduledTask], courses: [Course],
                        scope: ScheduleSearchScope = .all, now: Date = Date(),
                        calendar: Calendar = .current) -> [ScheduledTask] {
        let terms = query.precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let coursesByID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let today = calendar.startOfDay(for: now)
        let dateLabel = DateFormatter()
        dateLabel.locale = Locale(identifier: "en_US_POSIX")
        dateLabel.calendar = Calendar(identifier: .gregorian)
        dateLabel.timeZone = calendar.timeZone
        dateLabel.dateFormat = "yyyy-MM-dd"
        return tasks.filter { task in
            let course = coursesByID[task.courseID]
            guard course?.isArchived == false || !task.isUnconfirmed else { return false }
            // Include unfinished work from today and windows crossing midnight.
            let upcoming = task.isUnconfirmed && (task.start >= today || task.planningEnd > today)
            if scope == .upcoming && !upcoming { return false }
            if scope == .history && upcoming { return false }
            let text = [course?.name, task.lessonName, dateLabel.string(from: task.start)].compactMap { $0 }
                .joined(separator: " ").precomposedStringWithCompatibilityMapping
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted {
            if $0.start != $1.start { return scope == .history ? $0.start > $1.start : $0.start < $1.start }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

}

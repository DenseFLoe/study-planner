import Foundation

public enum CourseCatalogScope: String, CaseIterable, Identifiable, Sendable {
    case all = "全部", automatic = "自动排程", paused = "已暂停"
    public var id: Self { self }
}

public enum CourseCatalogOrder: String, CaseIterable, Identifiable, Sendable {
    case deadline = "截止日期优先", priority = "课程优先级优先"
    public var id: Self { self }
}

public enum CourseCatalogSearch {
    public static func matches(query: String, courses: [Course], scope: CourseCatalogScope = .all,
                               order: CourseCatalogOrder = .deadline, includedIDs: Set<UUID>? = nil,
                               timeZone: TimeZone = .current) -> [Course] {
        let terms = query.precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).map(String.init)
        let dateLabel = DateFormatter()
        dateLabel.locale = Locale(identifier: "en_US_POSIX")
        dateLabel.calendar = Calendar(identifier: .gregorian)
        dateLabel.timeZone = timeZone; dateLabel.dateFormat = "yyyy-MM-dd"
        return courses.filter { course in
            guard !course.isArchived else { return false }
            if let includedIDs, !includedIDs.contains(course.id) { return false }
            if scope == .automatic && !course.autoScheduleEnabled { return false }
            if scope == .paused && course.autoScheduleEnabled { return false }
            guard !terms.isEmpty else { return true }
            let text = [course.name, course.notes, dateLabel.string(from: course.deadline)]
                .joined(separator: " ").precomposedStringWithCompatibilityMapping
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted {
            if order == .priority && $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.deadline == $1.deadline ? $0.id.uuidString < $1.id.uuidString : $0.deadline < $1.deadline
        }
    }
}

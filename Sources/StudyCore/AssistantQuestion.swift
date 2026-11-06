import Foundation

/// Shared local numbering prevents the question and evidence from assigning different aliases.
struct AssistantCourseScope {
    let courses: [Course]
    let selected: [Course]
    let aliases: [UUID: String]

    init(state: PlannerState, courseID: UUID?) {
        let courses = state.courses.filter { !$0.isArchived }.sorted { $0.id.uuidString < $1.id.uuidString }
        self.courses = courses
        aliases = Dictionary(uniqueKeysWithValues: courses.enumerated().map { ($0.element.id, "课程\($0.offset + 1)") })
        selected = courseID.map { id in courses.filter { $0.id == id } } ?? Array(courses.prefix(12))
    }
}

public enum AssistantQuestionError: Error, LocalizedError {
    case ambiguous, outsideScope, missingSelection, unknownAlias

    public var errorDescription: String? {
        switch self {
        case .ambiguous:
            "问题中的课程名称有同名或重叠歧义。请在课程选择器中明确选择，并改用“这门课”提问后重新预览。"
        case .outsideScope:
            "问题涉及的课程不在当前证据范围内。请切换到该课程，或在概览范围内提问，再重新预览。"
        case .missingSelection:
            "所选课程已删除或归档，请重新选择课程后预览。"
        case .unknownAlias:
            "问题中的课程编号不在本次证据范围内。请先选择课程，核对本机对应关系后重新预览。"
        }
    }
}

public struct AssistantQuestionResolution: Equatable, Sendable {
    public let question: String
    /// Local-only guidance; never appended to the API request.
    public let notice: String

    public static func resolve(_ question: String, state: PlannerState, courseID: UUID?) throws -> Self {
        let scope = AssistantCourseScope(state: state, courseID: courseID)
        guard courseID == nil || !scope.selected.isEmpty else { throw AssistantQuestionError.missingSelection }
        let selectedIDs = Set(scope.selected.map(\.id))
        let input = question as NSString
        struct Match { var range: NSRange; var candidates: [Course] }
        var matches: [Match] = []
        // Exact full names only. Do not guess abbreviations, nicknames or semantic similarity.
        for (name, courses) in Dictionary(grouping: scope.courses, by: \.name) where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var offset = 0
            while offset < input.length {
                let range = input.range(of: name, options: .literal, range: NSRange(location: offset, length: input.length - offset))
                guard range.location != NSNotFound else { break }
                matches.append(.init(range: range, candidates: courses))
                offset = range.location + max(1, range.length)
            }
        }
        matches.sort { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        for pair in zip(matches, matches.dropFirst()) where NSMaxRange(pair.0.range) > pair.1.range.location {
            throw AssistantQuestionError.ambiguous
        }
        var replacements: [(NSRange, String)] = []
        for match in matches {
            let course: Course
            if match.candidates.count == 1 {
                course = match.candidates[0]
            } else if let courseID, let selected = match.candidates.first(where: { $0.id == courseID }) {
                course = selected
            } else {
                throw AssistantQuestionError.ambiguous
            }
            guard selectedIDs.contains(course.id) else { throw AssistantQuestionError.outsideScope }
            replacements.append((match.range, scope.aliases[course.id]!))
        }
        let output = NSMutableString(string: question)
        for (range, alias) in replacements.reversed() { output.replaceCharacters(in: range, with: alias) }
        let resolved = output as String
        let aliasExpression = try! NSRegularExpression(pattern: #"课程([0-9]+)"#)
        let includedAliases = Set(scope.selected.compactMap { scope.aliases[$0.id] })
        for match in aliasExpression.matches(in: resolved, range: NSRange(resolved.startIndex..., in: resolved)) {
            let alias = (resolved as NSString).substring(with: match.range)
            guard includedAliases.contains(alias) else { throw AssistantQuestionError.unknownAlias }
        }
        let notice = replacements.isEmpty
            ? "未识别到可替换的完整课程名称；简称或别名不会自动匹配。若在问具体课程，请在课程选择器中明确选择，并核对编号。问题的其余文字将原样发送。"
            : "已在本机将问题中识别到的完整课程名称替换为编号；同名课程按明确选择的课程解析。请核对下方对应关系和实际发送问题。其余文字将原样发送。"
        return .init(question: resolved, notice: notice)
    }
}

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
            "问题中的课程名称有同名、重叠或名称与编号冲突。请在课程选择器中明确选择，并改用“这门课”提问；引用编号可写成「课程1」，然后重新预览。"
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
        let aliasIDs = Dictionary(uniqueKeysWithValues: scope.aliases.map { ($0.value, $0.key) })
        let inputRange = NSRange(location: 0, length: input.length)
        // Explicit references are reserved syntax. Resolve them on the original input, before
        // course names, so a real course called "课程1" cannot reinterpret 「课程1」.
        let explicitExpression = try! NSRegularExpression(pattern: #"「(课程[0-9]+)」"#)
        let explicit = explicitExpression.matches(in: question, range: inputRange)
        func intersectsExplicit(_ range: NSRange) -> Bool {
            explicit.contains { NSIntersectionRange($0.range, range).length > 0 }
        }
        var candidates: [NSRange: Set<UUID>] = [:]
        for match in explicit {
            let alias = input.substring(with: match.range(at: 1))
            guard let id = aliasIDs[alias] else { throw AssistantQuestionError.unknownAlias }
            candidates[match.range] = [id]
        }
        // Exact full names only. Do not guess abbreviations, nicknames or semantic similarity.
        for (name, courses) in Dictionary(grouping: scope.courses, by: \.name) where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var offset = 0
            while offset < input.length {
                let range = input.range(of: name, options: .literal, range: NSRange(location: offset, length: input.length - offset))
                guard range.location != NSNotFound else { break }
                if intersectsExplicit(range) {
                    // A known full name surrounding a reference is not safely anonymized by
                    // replacing only its inner token. Require selection and a generic question.
                    guard explicit.contains(where: { NSIntersectionRange($0.range, range) == range }) else {
                        throw AssistantQuestionError.ambiguous
                    }
                } else {
                    candidates[range, default: []].formUnion(courses.map(\.id))
                }
                offset = range.location + max(1, range.length)
            }
        }
        // Plain aliases and names contribute to the same candidate set. Neither interpretation
        // wins silently when the same text points at different courses.
        let aliasExpression = try! NSRegularExpression(pattern: #"课程[0-9]+"#)
        for match in aliasExpression.matches(in: question, range: inputRange) where !intersectsExplicit(match.range) {
            let alias = input.substring(with: match.range)
            if let id = aliasIDs[alias] { candidates[match.range, default: []].insert(id) }
            else if candidates[match.range] == nil { candidates[match.range] = [] }
        }
        let ranges = candidates.keys.sorted { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        for pair in zip(ranges, ranges.dropFirst()) where NSMaxRange(pair.0) > pair.1.location {
            throw AssistantQuestionError.ambiguous
        }
        var replacements: [(NSRange, String)] = []
        for range in ranges {
            let ids = candidates[range]!
            guard !ids.isEmpty else { throw AssistantQuestionError.unknownAlias }
            let id: UUID
            if ids.count == 1 {
                id = ids.first!
            } else if let courseID, ids.contains(courseID) {
                id = courseID
            } else {
                throw AssistantQuestionError.ambiguous
            }
            guard selectedIDs.contains(id) else { throw AssistantQuestionError.outsideScope }
            replacements.append((range, "「\(scope.aliases[id]!)」"))
        }
        // Replace once using original ranges. Never infer references by scanning generated text:
        // "英语2倍" must retain both course identity and the separate multiplier 2.
        let output = NSMutableString(string: question)
        for (range, alias) in replacements.reversed() { output.replaceCharacters(in: range, with: alias) }
        let resolved = output as String
        let notice = replacements.isEmpty
            ? "未识别到可替换的完整课程名称；简称或别名不会自动匹配。若在问具体课程，请在课程选择器中明确选择，并核对编号。问题的其余文字将原样发送。"
            : "已在本机将课程名称或编号解析为「课程编号」引用，避免与后面的数字混淆；同名或名称与编号冲突时按明确选择的课程解析。请核对下方对应关系和实际发送问题。其余文字将原样发送。"
        return .init(question: resolved, notice: notice)
    }
}

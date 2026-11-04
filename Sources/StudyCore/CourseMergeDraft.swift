import Foundation

public enum CourseMergeError: LocalizedError {
    case changed
    public var errorDescription: String? {
        "所选课程或学习记录在预览后已有变化，未执行合并。选择和名称仍保留，请核对最新预览后重试。"
    }
}

/// Review only the selected sources and their recorded progress; unrelated edits
/// and replaceable pending plans are carried forward by the final transaction.
public struct CourseMergeDraft: Sendable {
    public let ids: Set<UUID>
    public let name: String
    private let reviewed: Inputs

    public init(state: PlannerState, ids: Set<UUID>, name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = state.courses.filter { ids.contains($0.id) && !$0.isArchived }
        guard ids.count >= 2, sources.count == ids.count, !title.isEmpty else {
            throw WebCourseImportError.invalid("请选择至少两门现有课程，并填写合并后的名称。")
        }
        self.ids = ids; self.name = title
        reviewed = Self.inputs(state, ids: ids)
    }

    @discardableResult public func apply(to state: inout PlannerState) throws -> Course {
        guard Self.inputs(state, ids: ids) == reviewed else { throw CourseMergeError.changed }
        return try state.mergeCourses(ids: ids, name: name)
    }

    private struct Inputs: Equatable, Sendable {
        var courses: [Course]
        var tasks: [ScheduledTask]
        var completions: [CompletionRecord]
    }
    private static func inputs(_ state: PlannerState, ids: Set<UUID>) -> Inputs {
        let records = state.completions.filter { ids.contains($0.courseID) }
        let recordedTasks = Set(records.map(\.taskID))
        return Inputs(courses: state.courses.filter { ids.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString },
                      tasks: state.tasks.filter { ids.contains($0.courseID) && (!$0.isUnconfirmed || recordedTasks.contains($0.id)) }
                        .sorted { $0.id.uuidString < $1.id.uuidString },
                      completions: records.sorted { $0.id.uuidString < $1.id.uuidString })
    }
}

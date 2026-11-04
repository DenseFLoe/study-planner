import Foundation

public enum CourseDeletionError: LocalizedError {
    case changed
    public var errorDescription: String? {
        "课程或学习记录在确认期间已有变化，未执行删除。请查看最新课程后重新确认。"
    }
}

/// Holds the stored course and learning history reviewed before destructive deletion.
/// Replaceable pending plans do not invalidate a review; new or revised progress does.
public struct CourseDeletionDraft: Sendable {
    public let course: Course
    private let history: History

    public init(reviewed course: Course, state: PlannerState) {
        self.course = course
        history = Self.history(in: state, courseID: course.id)
    }

    public func validate(in state: PlannerState) throws {
        guard state.courses.first(where: { $0.id == course.id }) == course,
              Self.history(in: state, courseID: course.id) == history else {
            throw CourseDeletionError.changed
        }
    }

    public func apply(to state: inout PlannerState) throws {
        try validate(in: state)
        state.removeCourse(id: course.id)
    }

    private struct History: Equatable, Sendable {
        var tasks: [ScheduledTask]
        var completions: [CompletionRecord]
    }
    private static func history(in state: PlannerState, courseID: UUID) -> History {
        // Include zero-minute and orphan records: deletion removes those too.
        let completions = state.completions.filter { $0.courseID == courseID }
        let recorded = Set(completions.map(\.taskID))
        return History(tasks: state.tasks.filter {
            $0.courseID == courseID && (!$0.isUnconfirmed || recorded.contains($0.id))
        }.sorted { $0.id.uuidString < $1.id.uuidString },
                       completions: completions.sorted { $0.id.uuidString < $1.id.uuidString })
    }
}

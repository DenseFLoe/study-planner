import Foundation
import StudyCore

/// Compute the merged course and its lessons together from one read-only snapshot.
struct CourseMergePreview: Sendable {
    let draft: CourseMergeDraft
    let state: PlannerState
    let course: Course
    let lessons: [LessonWorkItem]

    init(state: PlannerState, selected: Set<UUID>, name: String) throws {
        draft = try CourseMergeDraft(state: state, ids: selected, name: name)
        var preview = state
        course = try draft.apply(to: &preview)
        lessons = preview.lessonWorkItems(for: course)
        self.state = preview
    }
}

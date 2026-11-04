import Foundation
import StudyCore

/// Compute the merged course and its lessons together from one read-only snapshot.
struct CourseMergePreview: Sendable {
    let course: Course
    let lessons: [LessonWorkItem]

    init(state: PlannerState, selected: Set<UUID>, name: String) throws {
        var preview = state
        course = try preview.mergeCourses(ids: selected, name: name)
        lessons = preview.lessonWorkItems(for: course)
    }
}

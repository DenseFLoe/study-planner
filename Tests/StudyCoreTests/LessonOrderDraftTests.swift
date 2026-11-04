import XCTest
@testable import StudyCore

final class LessonOrderDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.settings.availability = []
        var course = Course(name: "排序课程", totalMinutes: 180, startDate: now,
                            deadline: now.addingTimeInterval(86400 * 10))
        course.type = .lessonBasedRecorded
        course.manualLessons = ["a", "b", "c"].map { .init(id: $0, name: $0, durationMinutes: 60) }
        course.lessonOrder = ["a", "b", "c"]
        state.courses = [course]
        return state
    }

    private func confirm(_ lesson: String, in state: inout PlannerState, minutes: Int = 20) throws {
        let task = ScheduledTask(courseID: state.courses[0].id, start: now.addingTimeInterval(-7200),
                                 durationMinutes: 60, lessonID: lesson)
        state.tasks.append(task)
        try state.confirm(taskID: task.id, actualMinutes: minutes, now: now)
    }

    private func assertRejected(_ draft: LessonOrderDraft, by current: PlannerState,
                                _ expected: LessonOrderEditError, file: StaticString = #filePath, line: UInt = #line) {
        var value = current
        XCTAssertThrowsError(try draft.apply(to: &value), file: file, line: line) {
            XCTAssertEqual($0 as? LessonOrderEditError, expected, file: file, line: line)
        }
        XCTAssertEqual(value, current, "Rejected intent must be atomic", file: file, line: line)
    }

    func testStaleOrderRejectsAndKeepsStableDraftAndPreview() throws {
        let initial = fixture()
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var current = initial
        current.courses[0].lessonOrder = ["c", "a", "b"]
        assertRejected(draft, by: current, .orderChanged)
        XCTAssertEqual(draft.order, ["b", "a", "c"])
        XCTAssertEqual(try draft.preview().courses[0].lessonOrder, draft.order)
        XCTAssertTrue(draft.hasChanges)
        let reloaded = LessonOrderDraft(course: current.courses[0], state: current)
        XCTAssertEqual(reloaded.order, ["c", "a", "b"])
        XCTAssertFalse(reloaded.hasChanges)
    }

    func testUnchangedDraftPreservesNewOrderWithoutCreatingAnEdit() throws {
        let initial = fixture()
        let unchanged = LessonOrderDraft(course: initial.courses[0], state: initial)
        var current = initial
        current.courses[0].lessonOrder = ["c", "a", "b"]
        let latest = current
        try unchanged.apply(to: &current)
        XCTAssertEqual(current, latest)
        XCTAssertFalse(unchanged.hasChanges)
    }

    func testIdenticalOrderIsIdempotentAndPreservesIndependentFieldsAndProgress() throws {
        let initial = fixture()
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var current = initial
        current.courses[0].lessonOrder = draft.order
        current.courses[0].lessonOrderCustomized = true
        current.courses[0].name = "手机改名"
        current.courses[0].notes = "新备注"
        current.courses[0].priority = 5
        try confirm("a", in: &current)
        let latest = current
        try draft.apply(to: &current)
        XCTAssertEqual(current, latest)
        try draft.apply(to: &current)
        XCTAssertEqual(current, latest)
    }

    func testAddedDeletedRenamedOrResizedLessonsRejectWholeIntent() throws {
        let initial = fixture()
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        for operation in 0..<4 {
            var current = initial
            switch operation {
            case 0:
                current.courses[0].manualLessons!.append(.init(id: "d", name: "d", durationMinutes: 60))
                current.courses[0].totalMinutes += 60
            case 1: try current.removeLessons(courseID: initial.courses[0].id, ids: ["a"])
            case 2: current.courses[0].manualLessons![0].name = "新课节名称"
            default:
                current.courses[0].manualLessons![0].durationMinutes += 10
                current.courses[0].totalMinutes += 10
            }
            assertRejected(draft, by: current, .lessonsChanged)
        }
    }

    func testRemovedAndArchivedCoursesCannotBeRevived() throws {
        let initial = fixture()
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var removed = initial
        removed.removeCourse(id: initial.courses[0].id)
        assertRejected(draft, by: removed, .removed)
        var archived = initial
        archived.courses[0].isArchived = true
        assertRejected(draft, by: archived, .removed)
    }

    func testNewConfirmationForPendingDeletionRejectsWithoutLosingDraft() throws {
        let initial = fixture()
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        try draft.removeLessons(["a"])
        var current = initial
        try confirm("a", in: &current)
        assertRejected(draft, by: current, .progressChanged)
        XCTAssertEqual(draft.deleted, ["a"])
        XCTAssertEqual(draft.order, ["b", "c"])
    }

    func testRepeatedStudyOnAlreadyCompletePendingDeletionStillRejects() throws {
        var initial = fixture()
        try confirm("a", in: &initial, minutes: 60)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        try draft.removeLessons(["a"])
        var current = initial
        try confirm("a", in: &current)
        XCTAssertEqual(initial.lessonWorkItems(for: initial.courses[0]).first?.remainingMinutes, 0)
        XCTAssertEqual(current.lessonWorkItems(for: current.courses[0]).first?.remainingMinutes, 0)
        assertRejected(draft, by: current, .progressChanged)
    }

    func testReorderPreservesNewCompletionsAndTheirTaskIdentity() throws {
        let initial = fixture()
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var current = initial
        try confirm("a", in: &current)
        let tasks = current.tasks, completions = current.completions
        try draft.apply(to: &current)
        XCTAssertEqual(current.tasks, tasks)
        XCTAssertEqual(current.completions, completions)
        XCTAssertEqual(current.lessonWorkItems(for: current.courses[0]).map(\.remainingMinutes), [60, 40, 60])
    }

    func testDeletionPreservesUntouchedNewConfirmationAndIndependentCourseEdits() throws {
        let initial = fixture()
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        try draft.removeLessons(["a"])
        var current = initial
        current.courses[0].name = "手机改名"
        current.courses[0].notes = "新备注"
        try confirm("b", in: &current)
        let completions = current.completions, tasks = current.tasks
        try draft.apply(to: &current)
        XCTAssertEqual(current.tasks, tasks)
        XCTAssertEqual(current.completions, completions)
        XCTAssertEqual(current.courses[0].name, "手机改名")
        XCTAssertEqual(current.courses[0].notes, "新备注")
        XCTAssertEqual(current.courses[0].deletedLessonIDs, ["a"])
        XCTAssertEqual(current.courses[0].totalMinutes, 120)
    }

    func testExplicitDeletionRemovesOnlyReviewedHistory() throws {
        var initial = fixture()
        try confirm("a", in: &initial)
        try confirm("b", in: &initial)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        try draft.removeLessons(["a"])
        var current = initial
        try draft.apply(to: &current)
        XCTAssertEqual(current.tasks.map(\.lessonID), ["b"])
        XCTAssertEqual(current.completions.map(\.taskID), current.tasks.map(\.id))
        XCTAssertEqual(current.lessonWorkItems(for: current.courses[0]).map(\.remainingMinutes), [40, 60])
    }

    func testInvalidPermutationAndDeletingEverythingRejectWithoutChangingDraft() throws {
        let initial = fixture()
        for order in [["a", "a", "c"], ["a", "b"], ["a", "b", "unknown"], []] {
            var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
            draft.order = order
            assertRejected(draft, by: initial, .invalidOrder)
        }
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        XCTAssertThrowsError(try draft.removeLessons(["a", "b", "c"]))
        XCTAssertTrue(draft.deleted.isEmpty)
        XCTAssertEqual(draft.order, ["a", "b", "c"])
    }

    func testWebsiteRefreshPreservesProgressButProtectsPendingDeletion() throws {
        var initial = fixture()
        let snapshot = WebCourseSnapshot(packageID: "fixture", name: "网站课程", sourceURL: "https://example.com/course",
            fetchedAt: now, expectedOutlines: 1, fetchedOutlines: 1,
            lessons: ["a", "b", "c"].map { .init(id: $0, name: $0, subject: "", stage: "", chapter: "",
                kind: "video", published: true, durationSeconds: 3600, watchedPercent: 0,
                markedFinished: false, requiresDuration: true) }, issues: [])
        initial.courses = []
        try initial.importWebCourses([snapshot], deadline: now.addingTimeInterval(86400 * 10), now: now)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        var deletion = draft
        draft.order = ["b", "a", "c"]
        try deletion.removeLessons(["a"])
        var current = initial, refreshed = snapshot
        refreshed.lessons[0].watchedPercent = 50
        refreshed.fetchedAt = now.addingTimeInterval(60)
        try current.importWebCourses([refreshed], deadline: current.courses[0].deadline, now: now)
        assertRejected(deletion, by: current, .progressChanged)
        try draft.apply(to: &current)
        XCTAssertEqual(current.courses[0].webCourse, refreshed)
        XCTAssertEqual(current.lessonWorkItems(for: current.courses[0]).map(\.remainingMinutes), [60, 30, 60])
        draft.order = ["a", "b", "c"]
        // Selecting website order in a new draft restores follow-website mode.
        var follow = LessonOrderDraft(course: current.courses[0], state: current)
        follow.order = try XCTUnwrap(follow.websiteOrder)
        try follow.apply(to: &current)
        XCTAssertEqual(current.courses[0].lessonOrderCustomized, false)
    }
}

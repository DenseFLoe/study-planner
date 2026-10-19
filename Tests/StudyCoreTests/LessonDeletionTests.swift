import XCTest
@testable import StudyCore

final class LessonDeletionTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 813_888_000)
    private func fixture() throws -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "部分删除", totalMinutes: 180, startDate: now, deadline: now.addingTimeInterval(86400 * 7))
        course.type = .lessonBasedRecorded
        course.manualLessons = ["a", "b", "c"].map { ManualLesson(id: $0, name: $0, durationMinutes: 60) }
        course.initialCompletedMinutes = 70
        course.lessonOrder = ["c", "a", "b"]
        state.courses = [course]
        for (offset, id) in ["a", "b", "c"].enumerated() {
            var task = ScheduledTask(courseID: course.id, start: now.addingTimeInterval(Double(offset * 7200)), durationMinutes: 60)
            task.lessonID = id
            state.tasks.append(task)
            if id != "a" { try state.confirm(taskID: task.id, actualMinutes: 20, now: task.end) }
        }
        return state
    }
    private func snapshot(_ ids: [String], fetchedAt: Date? = nil) -> WebCourseSnapshot {
        .init(packageID: "package", name: "网站课", sourceURL: "https://example.com/course", fetchedAt: fetchedAt ?? now,
              expectedOutlines: 1, fetchedOutlines: 1, lessons: ids.map {
                  .init(id: $0, name: $0, subject: "", stage: "", chapter: "", kind: "video", published: true,
                        durationSeconds: 3600, watchedPercent: $0 == "b" ? 50 : 0, markedFinished: false, requiresDuration: true)
              }, issues: [])
    }
    func testManualDeletionPreservesOtherProgressAndHistory() throws {
        var state = try fixture()
        let original = state, courseID = state.courses[0].id
        let before = Dictionary(uniqueKeysWithValues: state.lessonWorkItems(for: state.courses[0]).map { ($0.id, $0.remainingMinutes) })
        try state.removeLessons(courseID: courseID, ids: ["a", "c"])
        let course = state.courses[0]
        XCTAssertEqual(course.totalMinutes, 60)
        XCTAssertEqual(course.initialCompletedMinutes, 10)
        XCTAssertEqual(course.lessonOrder, ["b"])
        XCTAssertEqual(state.lessonWorkItems(for: course).map(\.remainingMinutes), [before["b"]!])
        XCTAssertEqual(state.tasks, original.tasks.filter { $0.lessonID == "b" })
        XCTAssertEqual(state.completions, original.completions.filter { $0.taskID == state.tasks[0].id })
        XCTAssertEqual(try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state)), state)
        _ = state.replan(now: now)
        XCTAssertTrue(state.tasks.allSatisfy { $0.lessonID == "b" })
    }
    func testInvalidSelectionsAndLegacyRecordsLeaveStateUnchanged() throws {
        var state = try fixture()
        for ids: Set<String> in [[], ["missing"], ["a", "b", "c"]] {
            let before = state
            XCTAssertThrowsError(try state.removeLessons(courseID: state.courses[0].id, ids: ids))
            XCTAssertEqual(state, before)
        }
        state.tasks[1].lessonID = nil
        let before = state
        XCTAssertThrowsError(try state.removeLessons(courseID: state.courses[0].id, ids: ["a"]))
        XCTAssertEqual(state, before)
    }
    func testWebsiteDeletionKeepsOtherProgressAcrossRefreshAndUndo() throws {
        var state = PlannerState()
        try state.importWebCourses([snapshot(["a", "b", "c"])], deadline: now.addingTimeInterval(86400), now: now)
        let id = state.courses[0].id
        for lesson in ["a", "b"] {
            var task = ScheduledTask(courseID: id, start: now, durationMinutes: 20)
            task.lessonID = lesson
            state.tasks.append(task)
            try state.confirm(taskID: task.id, actualMinutes: 20, now: now.addingTimeInterval(1))
        }
        try state.removeLessons(courseID: id, ids: ["a"])
        XCTAssertEqual(state.courses[0].totalMinutes, 120)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [10, 60])
        try state.importWebCourses([snapshot(["a", "b", "c", "d"], fetchedAt: now.addingTimeInterval(2))], deadline: now.addingTimeInterval(86400), now: now)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.id), ["b", "c", "d"])
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [10, 60, 60])
        try state.undoConfirmation(taskID: state.tasks[0].id, now: now.addingTimeInterval(3))
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [30, 60, 60])
    }
    func testNestedMergedDeletionDropsWholeSourceAndKeepsPartialSource() throws {
        var state = try fixture()
        let a = state.courses[0]
        let b = Course(name: "整门来源", totalMinutes: 45, startDate: now, deadline: a.deadline)
        state.courses.append(b)
        let first = try state.mergeCourses(ids: [a.id, b.id], name: "第一组合")
        state.removeArchivedCourses()
        let c = Course(name: "保留来源", totalMinutes: 30, startDate: now, deadline: a.deadline)
        state.courses.append(c)
        let merged = try state.mergeCourses(ids: [first.id, c.id], name: "嵌套组合")
        state.removeArchivedCourses()
        let old = Dictionary(uniqueKeysWithValues: state.lessonWorkItems(for: merged).map { ($0.id, $0.remainingMinutes) })
        let prefix = first.id.uuidString + "/"
        let removed: Set<String> = [prefix + b.id.uuidString + "/whole", prefix + a.id.uuidString + "/a"]
        try state.removeLessons(courseID: merged.id, ids: removed)
        let course = state.courses[0]
        XCTAssertEqual(course.totalMinutes, 150)
        XCTAssertEqual(course.initialCompletedMinutes, 10)
        XCTAssertEqual(course.mergedSources?.first(where: { $0.id == first.id })?.mergedSources?.count, 1)
        for lesson in state.lessonWorkItems(for: course) { XCTAssertEqual(lesson.remainingMinutes, old[lesson.id]) }
        XCTAssertFalse(state.tasks.contains { removed.contains($0.lessonID ?? "") })
    }
    func testDeletionMarkersStillProtectHistoryAfterLaterMerge() throws {
        var state = try fixture()
        let sourceID = state.courses[0].id
        try state.removeLessons(courseID: sourceID, ids: ["a"])
        let other = Course(name: "新来源", totalMinutes: 30, startDate: now, deadline: now.addingTimeInterval(86400))
        state.courses.append(other)
        let merged = try state.mergeCourses(ids: [sourceID, other.id], name: "后续合并")
        state.removeArchivedCourses()
        var stale = ScheduledTask(courseID: merged.id, start: now, durationMinutes: 30)
        stale.lessonID = sourceID.uuidString + "/a"
        state.tasks.append(stale)
        try state.confirm(taskID: stale.id, actualMinutes: 10, now: stale.end)
        var ledger = SyncLedger()
        try ledger.capture(state)
        let restored = try ledger.materialize()
        XCTAssertFalse(restored.tasks.contains { $0.id == stale.id })
        XCTAssertFalse(restored.completions.contains { $0.taskID == stale.id })
        XCTAssertEqual(restored.courses[0].totalMinutes, 150)
    }
    func testOfflineConfirmationCannotRestoreDeletedLessonHistory() throws {
        var state = try fixture(), mac = SyncLedger(), phone = SyncLedger()
        try mac.capture(state)
        try phone.merge(mac.changes(after: 0))
        var other = try phone.materialize()
        let task = try XCTUnwrap(other.tasks.first { $0.lessonID == "a" })
        try other.confirm(taskID: task.id, actualMinutes: 10, now: now)
        try phone.capture(other)
        try state.removeLessons(courseID: state.courses[0].id, ids: ["a"])
        try mac.capture(state)
        let local = mac.changes(after: 0), remote = phone.changes(after: 0)
        try mac.merge(remote)
        try phone.merge(local)
        let result = try mac.materialize()
        XCTAssertEqual(result, try phone.materialize())
        XCTAssertFalse(result.tasks.contains { $0.lessonID == "a" })
        XCTAssertFalse(result.completions.contains { $0.taskID == task.id })
        XCTAssertEqual(result.courses[0].totalMinutes, 120)
    }
}

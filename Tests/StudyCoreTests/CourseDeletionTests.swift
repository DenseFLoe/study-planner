import XCTest
@testable import StudyCore

final class CourseDeletionTests: XCTestCase {
    func fixture() throws -> PlannerState {
        var state = PlannerState()
        state.settings.availability = []
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for name in ["删除课程", "保留课程"] {
            let course = Course(name: name, totalMinutes: 180, startDate: day, deadline: day.addingTimeInterval(86400))
            state.courses.append(course)
            for offset in [0, 3600, 7200] {
                let task = ScheduledTask(courseID: course.id, start: day.addingTimeInterval(Double(offset)), durationMinutes: 60)
                state.tasks.append(task)
                if offset < 7200 { try state.confirm(taskID: task.id, actualMinutes: offset == 0 ? 60 : 20, now: task.end) }
            }
        }
        state.fixedEvents = [.init(title: "固定事项", startMinute: 720, endMinute: 780, startDate: day, endDate: day)]
        return state
    }

    func testDeletionRemovesCompletedPartialAndFutureTasksOnlyForSelectedCourse() throws {
        var state = try fixture()
        let original = state, id = state.courses[0].id
        state.removeCourse(id: id)
        XCTAssertEqual(state.courses, [original.courses[1]])
        XCTAssertEqual(state.tasks, original.tasks.filter { $0.courseID != id })
        XCTAssertEqual(state.completions, original.completions.filter { $0.courseID != id })
        XCTAssertEqual(state.fixedEvents, original.fixedEvents)
        XCTAssertEqual(state.settings, original.settings)
        let deleted = state
        state.removeCourse(id: id)
        XCTAssertEqual(state, deleted)
    }

    func testLegacyArchivedCoursesAndTheirHistoryAreRemoved() throws {
        var state = try fixture()
        state.courses[0].isArchived = true
        var expected = state
        expected.removeCourse(id: state.courses[0].id)
        state.removeArchivedCourses()
        XCTAssertEqual(state, expected)
    }

    func testDeletionSyncsAndConcurrentCompletionCannotRestoreRemovedHistory() throws {
        var state = try fixture()
        let id = state.courses[0].id
        var mac = SyncLedger(), phone = SyncLedger()
        try mac.capture(state)
        try phone.merge(mac.changes(after: 0))
        var onPhone = try phone.materialize()
        let pending = try XCTUnwrap(onPhone.tasks.first { $0.courseID == id && $0.isUnconfirmed })
        try onPhone.confirm(taskID: pending.id, actualMinutes: 60, now: pending.end)
        try phone.capture(onPhone)
        state.removeCourse(id: id)
        try mac.capture(state)
        let macChanges = mac.changes(after: 0), phoneChanges = phone.changes(after: 0)
        try mac.merge(phoneChanges)
        try phone.merge(macChanges)
        XCTAssertEqual(try mac.materialize(), try phone.materialize())
        let result = try mac.materialize()
        XCTAssertFalse(result.tasks.contains { $0.courseID == id })
        XCTAssertFalse(result.completions.contains { $0.courseID == id })
        XCTAssertEqual(result.courses.map(\.id), [state.courses[0].id])
        try mac.capture(result)
        try phone.merge(mac.changes(after: 0))
        XCTAssertEqual(try phone.materialize(), result)
        XCTAssertEqual(mac.records["courses/" + id.uuidString]?.deleted, true)
        XCTAssertTrue(mac.records.values.filter { $0.kind == "completions" && $0.deleted }.count >= 3)
    }

    func testLegacyArchivedSyncRecordsAreCleanedAndDeletionPropagates() throws {
        let state = try fixture(), id = state.courses[0].id
        var ledger = SyncLedger()
        try ledger.capture(state)
        var course = state.courses[0]
        course.isArchived = true
        var archived = try XCTUnwrap(ledger.records["courses/" + id.uuidString])
        archived.payload = try JSONEncoder().encode(course)
        archived.version += 1
        try ledger.merge([archived])
        let cleaned = try ledger.materialize()
        XCTAssertFalse(cleaned.courses.contains { $0.id == id })
        XCTAssertFalse(cleaned.tasks.contains { $0.courseID == id })
        XCTAssertFalse(cleaned.completions.contains { $0.courseID == id })
        try ledger.capture(cleaned)
        XCTAssertEqual(ledger.records[archived.key]?.deleted, true)
        var peer = SyncLedger()
        try peer.merge(ledger.changes(after: 0))
        XCTAssertEqual(try peer.materialize(), cleaned)
    }

    func testCleanupPreservesHistoryTransferredToMergedCourse() throws {
        var state = try fixture()
        var ledger = SyncLedger()
        try ledger.capture(state)
        let merged = try state.mergeCourses(ids: Set(state.courses.map(\.id)), name: "合并课程")
        state.removeArchivedCourses()
        XCTAssertEqual(state.courses, [merged])
        XCTAssertEqual(state.tasks.count, 6)
        XCTAssertEqual(state.completions.count, 4)
        XCTAssertTrue(state.tasks.allSatisfy { $0.courseID == merged.id })
        XCTAssertTrue(state.completions.allSatisfy { $0.courseID == merged.id })
        try ledger.capture(state)
        let loaded = try ledger.materialize()
        XCTAssertEqual(loaded.courses, state.courses)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: loaded.tasks.map { ($0.id, $0) }), Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0) }))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: loaded.completions.map { ($0.id, $0) }), Dictionary(uniqueKeysWithValues: state.completions.map { ($0.id, $0) }))
        XCTAssertEqual(loaded.completedMinutes(for: merged), 160)
        state.removeCourse(id: merged.id)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertTrue(state.completions.isEmpty)
    }
}

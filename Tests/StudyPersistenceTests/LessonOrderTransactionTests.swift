import XCTest
import StudyCore
@testable import StudyPersistence

final class LessonOrderTransactionTests: XCTestCase {
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

    private func confirm(_ lesson: String, in state: inout PlannerState) throws {
        let task = ScheduledTask(courseID: state.courses[0].id, start: now.addingTimeInterval(-7200),
                                 durationMinutes: 60, lessonID: lesson)
        state.tasks.append(task)
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now)
    }

    func testFinalTransactionRejectsNewOrderAndLeavesDiskAndLedgerUntouched() throws {
        let repository = try LocalRepository(inMemory: true), initial = fixture()
        try repository.save(initial)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var prepared = initial
        try draft.apply(to: &prepared)
        var remote = initial
        remote.courses[0].lessonOrder = ["c", "a", "b"]
        try repository.save(remote)
        let records = try repository.loadLedger().records
        XCTAssertThrowsError(try repository.saveLessonOrder(draft, now: now)) {
            XCTAssertEqual($0 as? LessonOrderEditError, .orderChanged)
        }
        XCTAssertEqual(try repository.load(), remote)
        XCTAssertEqual(try repository.loadLedger().records, records)
        XCTAssertEqual(try repository.loadLedger().materialize(), remote)
    }

    func testFinalTransactionReplansLatestStateAndPreservesNewHistory() throws {
        let repository = try LocalRepository(inMemory: true), initial = fixture()
        try repository.save(initial)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var remote = initial
        remote.courses[0].name = "新名称"
        remote.courses[0].notes = "新备注"
        try confirm("a", in: &remote)
        try repository.save(remote)
        let saved = try repository.saveLessonOrder(draft, now: now)
        XCTAssertEqual(saved.courses[0].name, "新名称")
        XCTAssertEqual(saved.courses[0].notes, "新备注")
        XCTAssertEqual(saved.courses[0].lessonOrder, draft.order)
        XCTAssertEqual(saved.completions, remote.completions)
        XCTAssertEqual(saved.tasks, remote.tasks)
        XCTAssertEqual(try repository.load(), saved)
        XCTAssertEqual(try repository.loadLedger().materialize(), saved)
    }

    func testPendingDeletionDoesNotPurgeConfirmationArrivingAfterPreparation() throws {
        let repository = try LocalRepository(inMemory: true), initial = fixture()
        try repository.save(initial)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        try draft.removeLessons(["a"])
        var remote = initial
        try confirm("a", in: &remote)
        try repository.save(remote)
        let records = try repository.loadLedger().records
        XCTAssertThrowsError(try repository.saveLessonOrder(draft, now: now)) {
            XCTAssertEqual($0 as? LessonOrderEditError, .progressChanged)
        }
        XCTAssertEqual(try repository.load(), remote)
        XCTAssertEqual(try repository.loadLedger().records, records)
        XCTAssertEqual(try repository.loadLedger().materialize(), remote)
    }

    func testSameOrderIsIdempotentInLedger() throws {
        let repository = try LocalRepository(inMemory: true)
        var initial = fixture()
        initial.settings.availability = AppSettings().availability
        try repository.save(initial)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        let saved = try repository.saveLessonOrder(draft, now: now)
        XCTAssertFalse(saved.tasks.isEmpty)
        let records = try repository.loadLedger().records
        XCTAssertEqual(try repository.saveLessonOrder(draft, now: now), saved)
        XCTAssertEqual(try repository.loadLedger().records, records)
    }

    func testDeletedCourseCannotBeRecreatedAtFinalTransaction() throws {
        let repository = try LocalRepository(inMemory: true), initial = fixture()
        try repository.save(initial)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var remote = initial
        remote.removeCourse(id: initial.courses[0].id)
        try repository.save(remote)
        let records = try repository.loadLedger().records
        XCTAssertThrowsError(try repository.saveLessonOrder(draft, now: now)) {
            XCTAssertEqual($0 as? LessonOrderEditError, .removed)
        }
        XCTAssertEqual(try repository.load(), remote)
        XCTAssertEqual(try repository.loadLedger().records, records)
    }

    func testWriteDuringOptimisticCalculationRetriesAndRevalidatesIntent() throws {
        for deleting in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("ordering.store")
            let repository = try LocalRepository(url: url), initial = fixture()
            try repository.save(initial)
            var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
            var remote = initial
            if deleting {
                try draft.removeLessons(["a"])
                try confirm("a", in: &remote)
            } else {
                draft.order = ["b", "a", "c"]
                remote.courses[0].lessonOrder = ["c", "a", "b"]
            }
            var attempts = 0
            var committedRecords: [String: SyncRecord] = [:]
            XCTAssertThrowsError(try repository.update { state, _ in
                attempts += 1
                try draft.apply(to: &state)
                _ = state.replan(now: now)
                if attempts == 1 {
                    try LocalRepository.withExclusiveAccess {
                        let peer = try LocalRepository(url: url)
                        try peer.save(remote)
                        committedRecords = try peer.loadLedger().records
                    }
                }
            }) {
                XCTAssertEqual($0 as? LessonOrderEditError, deleting ? .progressChanged : .orderChanged)
            }
            XCTAssertEqual(attempts, 2)
            let reopened = try LocalRepository(url: url)
            XCTAssertEqual(try reopened.load(), remote)
            XCTAssertEqual(try reopened.loadLedger().records, committedRecords)
            XCTAssertEqual(try reopened.loadLedger().materialize(), remote)
        }
    }
}

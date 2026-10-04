import XCTest
import StudyCore
import SwiftData
@testable import StudyPersistence

final class LocalRepositoryTests: XCTestCase {
    @MainActor func testLegacyCourseDeletionIsCleanedOnLoadAndPersistsAfterReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.store")
        var state = PlannerState()
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var removed = Course(name: "旧删除课程", totalMinutes: 120, startDate: day, deadline: day)
        let kept = Course(name: "保留课程", totalMinutes: 60, startDate: day, deadline: day)
        state.courses = [removed, kept]
        for course in state.courses {
            let task = ScheduledTask(courseID: course.id, start: day, durationMinutes: 60)
            state.tasks.append(task)
            try state.confirm(taskID: task.id, actualMinutes: 30, now: task.end)
        }
        do { let repo = try LocalRepository(url: url); try repo.save(state) }
        // Seed the archive flag exactly as the earlier application persisted it.
        removed.isArchived = true
        do {
            let container = try ModelContainer(for: LocalRecord.self, configurations: ModelConfiguration("StudyPlanner", url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<LocalRecord>()).first { $0.key == "course/\(removed.id)" })
            row.payload = try JSONEncoder().encode(removed)
            try context.save()
        }
        var expected = state
        expected.removeCourse(id: removed.id)
        do {
            let repo = try LocalRepository(url: url)
            let loaded = try repo.load()
            XCTAssertEqual(loaded, expected)
            try repo.save(loaded)
        }
        let reopened = try LocalRepository(url: url)
        XCTAssertEqual(try reopened.load(), expected)
        let ledger = try reopened.loadLedger()
        XCTAssertEqual(ledger.records["courses/" + removed.id.uuidString]?.deleted, true)
        XCTAssertEqual(try ledger.materialize(), expected)
    }

    @MainActor func testFloatingEventsAndTaskWindowsSurviveReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("floating.store")
        let day = Calendar.current.startOfDay(for: Date())
        var state = PlannerState()
        let course = Course(name: "浮动学习", totalMinutes: 60, startDate: day, deadline: day)
        state.courses = [course]
        var event = FixedEvent(title: "杂务", startMinute: 840, endMinute: 1080, startDate: day, endDate: day)
        event.floatingDurationMinutes = 60
        state.fixedEvents = [event]
        try state.setFixedEventSkipped(id: event.id, on: day, skipped: true, now: day)
        event = state.fixedEvents[0]
        var task = ScheduledTask(courseID: course.id, start: day.addingTimeInterval(840 * 60), durationMinutes: 60)
        task.floatingWindowStart = task.start
        task.floatingWindowEnd = day.addingTimeInterval(1080 * 60)
        state.tasks = [task]
        do { let repo = try LocalRepository(url: url); try repo.save(state) }
        let loaded = try LocalRepository(url: url).load()
        XCTAssertEqual(loaded.fixedEvents, [event])
        XCTAssertFalse(loaded.fixedEvents[0].occurs(on: day, calendar: .current))
        XCTAssertEqual(loaded.tasks, [task])
    }

    @MainActor func testDiskRoundTripAndReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("planner.store")
        var state = PlannerState()
        state.courses = [.init(name: "数学", totalMinutes: 600, startDate: Date(), deadline: Date().addingTimeInterval(86400 * 10))]
        try state.recordActualStudyStart(minute: 630, now: Date())
        _ = state.replan(now: Date())
        let task = try XCTUnwrap(state.tasks.first)
        try state.confirm(taskID: task.id, actualMinutes: 30, now: Date())
        do { let repo = try LocalRepository(url: url); try repo.save(state) }
        let reopened = try LocalRepository(url: url)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.courses, state.courses)
        XCTAssertEqual(Set(loaded.tasks.map(\.id)), Set(state.tasks.map(\.id)))
        XCTAssertEqual(loaded.completions, state.completions)
        XCTAssertEqual(loaded.settings, state.settings)
        state.tasks.removeAll { $0.isUnconfirmed }
        try reopened.save(state)
        XCTAssertEqual(try reopened.load().tasks.count, 1)
        try reopened.save(state)
        XCTAssertEqual(try reopened.load().completions.count, 1)
    }
}

extension LocalRepositoryTests {
    func testLedgerTombstonesAndAutomaticDatePersistTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.store")
        let db = try LocalRepository(url: url)
        var s = PlannerState(); s.settings.availability = []
        s.courses = [.init(name: "离线课程", totalMinutes: 60, startDate: Date(), deadline: Date())]
        try db.save(s); let id = s.courses[0].id.uuidString
        s.courses.removeAll(); try db.save(s)
        var ledger = try db.loadLedger(); ledger.lastAutoDate = "2026-09-19"; ledger.peerCursor = 123
        try db.save(s, ledger: ledger)
        let reopened = try LocalRepository(url: url)
        XCTAssertTrue(try reopened.load().courses.isEmpty)
        XCTAssertEqual(try reopened.loadLedger().records["courses/" + id]?.deleted, true)
        XCTAssertEqual(try reopened.loadLedger().lastAutoDate, "2026-09-19")
        XCTAssertEqual(try reopened.loadLedger().peerCursor, 123)
        let sequence = ledger.sequence
        var invalid = try XCTUnwrap(ledger.records["courses/" + id]); invalid.version += 100; invalid.deleted = false; invalid.payload = Data("broken".utf8)
        try ledger.merge([invalid])
        XCTAssertThrowsError(try ledger.materialize())
        XCTAssertEqual(try reopened.loadLedger().sequence, sequence)
        XCTAssertTrue(try reopened.load().courses.isEmpty)
    }
}

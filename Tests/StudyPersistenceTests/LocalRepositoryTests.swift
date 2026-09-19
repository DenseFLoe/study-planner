import XCTest
import StudyCore
@testable import StudyPersistence

final class LocalRepositoryTests: XCTestCase {
    @MainActor func testDiskRoundTripAndReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("planner.store")
        var state = PlannerState()
        state.courses = [.init(name: "数学", totalMinutes: 600, startDate: Date(), deadline: Date().addingTimeInterval(86400 * 10))]
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

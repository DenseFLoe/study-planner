import XCTest
@testable import StudyCore

final class SyncLedgerTests: XCTestCase {
    func fixture() -> PlannerState {
        var s = PlannerState(); s.settings.availability = []
        s.courses = [Course(name: "数学", totalMinutes: 600, startDate: Date(timeIntervalSinceReferenceDate: 800_000_000), deadline: Date(timeIntervalSinceReferenceDate: 800_864_000))]
        return s
    }
    func testOfflineAddsBidirectionalEditsAndDeletes() throws {
        var a = SyncLedger(), b = SyncLedger(); var sa = fixture(), sb = fixture()
        sb.courses[0].name = "英语"
        try a.capture(sa); try b.capture(sb)
        try a.merge(b.changes(after: 0)); try b.merge(a.changes(after: 0))
        XCTAssertEqual(try a.materialize(), try b.materialize())
        XCTAssertEqual(try a.materialize().courses.count, 2)
        sa = try a.materialize(); sa.courses[0].notes = "Mac 修改"; try a.capture(sa)
        try b.merge(a.changes(after: 0)); XCTAssertEqual(try b.materialize().courses[0].notes, "Mac 修改")
        sb = try b.materialize(); sb.courses[0].notes = "Android 修改"; try b.capture(sb)
        try a.merge(b.changes(after: 0)); XCTAssertEqual(try a.materialize().courses[0].notes, "Android 修改")
        sa = try a.materialize(); sa.courses.removeFirst(); try a.capture(sa); try b.merge(a.changes(after: 0))
        XCTAssertEqual(try b.materialize().courses.count, 1)
        sb = try b.materialize(); sb.courses.removeAll(); try b.capture(sb); try a.merge(b.changes(after: 0))
        XCTAssertTrue(try a.materialize().courses.isEmpty)
        XCTAssertEqual(a.records.values.filter { $0.kind == "courses" && $0.deleted }.count, 2)
    }
    func testConflictConvergesAndDuplicateDeliveryHasNoNewRevision() throws {
        var a = SyncLedger(); a.device = "A"; var b = SyncLedger(); b.device = "B"
        var s = fixture(); try a.capture(s); try b.merge(a.changes(after: 0))
        s.courses[0].name = "Mac"; try a.capture(s)
        var other = try b.materialize(); other.courses[0].name = "Android"; try b.capture(other)
        let fromA = a.changes(after: 0), fromB = b.changes(after: 0)
        try a.merge(fromB); try b.merge(fromA)
        XCTAssertEqual(try a.materialize(), try b.materialize())
        XCTAssertEqual(try a.materialize().courses[0].name, "Android")
        let sequence = a.sequence; try a.merge(fromB); XCTAssertEqual(sequence, a.sequence)
        try a.capture(a.materialize()); XCTAssertEqual(sequence, a.sequence)
    }
    func testSuccessfulAutomaticOnlyOnceAndFailureBackoffSurvivesRestart() throws {
        let now = Date(timeIntervalSince1970: 1_789_810_000)
        var l = SyncLedger(); XCTAssertTrue(l.permitsAutomatic(at: now))
        l.lastAttempt = now.timeIntervalSince1970
        XCTAssertFalse(l.permitsAutomatic(at: now.addingTimeInterval(1799)))
        XCTAssertTrue(l.permitsAutomatic(at: now.addingTimeInterval(1801)))
        l.lastAutoDate = SyncLedger.day(now)
        let reopened = try JSONDecoder().decode(SyncLedger.self, from: JSONEncoder().encode(l))
        XCTAssertFalse(reopened.permitsAutomatic(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(reopened.permitsAutomatic(at: now.addingTimeInterval(86400)))
    }
    func testStableGeneratedIDsAndConfirmations() throws {
        var s = fixture(); s.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1380) }
        let now = s.courses[0].startDate
        _ = s.replan(now: now); let ids = s.tasks.map(\.id)
        _ = s.replan(now: now); XCTAssertEqual(ids, s.tasks.map(\.id))
        let task = try XCTUnwrap(s.tasks.first)
        try s.confirm(taskID: task.id, actualMinutes: task.durationMinutes, now: now)
        XCTAssertEqual(s.completions.first?.id, stablePlannerID("completion|" + task.id.uuidString))
        _ = s.replan(now: now)
        XCTAssertEqual(Set(s.tasks.map(\.id)).count, s.tasks.count)
    }
    func testWireFixtureAndJavaResponse() throws {
        var s = fixture(); s.courses[0].id = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        var l = SyncLedger(); l.device = "MAC-FIXTURE"; try l.capture(s)
        try JSONEncoder().encode(l).write(to: URL(fileURLWithPath: "/tmp/study-sync-swift-fixture.json"))
        XCTAssertEqual(stablePlannerID("task|AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA|800000000|60").uuidString, "897861BE-3B8A-5F5C-84D2-6194FA9D75CD")
        let path = URL(fileURLWithPath: "/tmp/study-sync-java-fixture.json")
        if FileManager.default.fileExists(atPath: path.path) {
            let java = try JSONDecoder().decode(SyncLedger.self, from: Data(contentsOf: path))
            try l.merge(java.changes(after: 0))
            XCTAssertEqual(try l.materialize().courses.first?.notes, "Java round trip 中文")
        }
    }
}

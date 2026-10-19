import XCTest
@testable import StudyCore

final class SyncLedgerTests: XCTestCase {
    func testEarlyCompletionAndReplacementAtSameSlotBothSurviveSync() throws {
        for legacy in [false, true] {
            var state = fixture(); let now = state.courses[0].startDate
            state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1380) }
            _ = state.replan(now: now)
            if legacy, let index = state.tasks.firstIndex(where: { $0.start > now }) { state.tasks[index].id = UUID() }
            let first = try XCTUnwrap(state.tasks.first { $0.start > now })
            try state.confirm(taskID: first.id, actualMinutes: first.durationMinutes, now: now)
            _ = state.replan(now: now)
            let replacement = try XCTUnwrap(state.tasks.first { $0.isUnconfirmed && $0.start == first.start && $0.durationMinutes == first.durationMinutes })
            XCTAssertNotEqual(first.id, replacement.id)
            var ledger = SyncLedger(); try ledger.capture(state)
            let merged = try ledger.materialize()
            XCTAssertEqual(Set(merged.tasks.map(\.id)), Set(state.tasks.map(\.id)))
            XCTAssertEqual(merged.completions.count, 1)
            XCTAssertNotNil(merged.tasks.first { $0.id == first.id }?.confirmedAt)
            XCTAssertEqual(merged.tasks.first { $0.id == replacement.id }?.isUnconfirmed, true)
            try state.confirm(taskID: replacement.id, actualMinutes: replacement.durationMinutes, now: now.addingTimeInterval(1))
            _ = state.replan(now: now.addingTimeInterval(1)); try ledger.capture(state)
            XCTAssertEqual(try ledger.materialize().completions.count, 2)
            XCTAssertEqual(Set(try ledger.materialize().tasks.map(\.id)), Set(state.tasks.map(\.id)))
        }
    }

    func testLatestEditWinsDespiteLargerOfflineCounterAndSurvivesRestart() throws {
        var mac = SyncLedger(), phone = SyncLedger()
        var state = fixture()
        let t = Date(timeIntervalSince1970: 2_000_000_000)
        try mac.capture(state, now: t); try phone.merge(mac.changes(after: 0))
        for i in 1...20 {
            state.courses[0].notes = "旧修改 \(i)"
            try phone.capture(state, now: t.addingTimeInterval(Double(i)))
        }
        var newer = try mac.materialize(); newer.courses[0].notes = "较新的电脑修改"
        try mac.capture(newer, now: t.addingTimeInterval(30))
        let left = mac.changes(after: 0), right = phone.changes(after: 0)
        try mac.merge(right); try phone.merge(left)
        XCTAssertEqual(try mac.materialize(), try phone.materialize())
        XCTAssertEqual(try phone.materialize().courses[0].notes, "较新的电脑修改")
        phone = try JSONDecoder().decode(SyncLedger.self, from: JSONEncoder().encode(phone))
        newer = try phone.materialize(); newer.courses[0].notes = "更晚的手机修改"
        try phone.capture(newer, now: t.addingTimeInterval(40)); try mac.merge(phone.changes(after: 0))
        XCTAssertEqual(try mac.materialize().courses[0].notes, "更晚的手机修改")
        let sequence = mac.sequence; try mac.capture(mac.materialize(), now: t.addingTimeInterval(50))
        XCTAssertEqual(sequence, mac.sequence)
    }

    func testConfirmedHistorySurvivesStaleDraftsDuplicatesAndExplicitUndo() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for minutes in [0, 20, 60] {
            var mac = SyncLedger(), phone = SyncLedger(); var state = fixture()
            let task = ScheduledTask(courseID: state.courses[0].id, start: now.addingTimeInterval(-7200), durationMinutes: 60)
            state.tasks = [task]
            try mac.capture(state, now: now); try phone.merge(mac.changes(after: 0))
            var confirmed = try mac.materialize()
            try confirmed.confirm(taskID: task.id, actualMinutes: minutes, now: now)
            try mac.capture(confirmed, now: now.addingTimeInterval(1))
            // A later replan/save on the stale peer is not an undo operation.
            var stale = try phone.materialize(); stale.tasks[0].status = .future
            var duplicate = task; duplicate.id = UUID(); stale.tasks.append(duplicate)
            try phone.capture(stale, now: now.addingTimeInterval(2))
            let left = mac.changes(after: 0), right = phone.changes(after: 0)
            try mac.merge(right); try phone.merge(left)
            XCTAssertEqual(try mac.materialize(), try phone.materialize())
            let merged = try mac.materialize()
            XCTAssertEqual(merged.tasks.count, 1)
            XCTAssertEqual(merged.tasks.first?.confirmedAt, now)
            XCTAssertEqual(merged.completions.first?.minutes, minutes)
            XCTAssertTrue(merged.confirmationCandidates(at: now).isEmpty)
            try mac.capture(merged, now: now.addingTimeInterval(3)); try phone.merge(mac.changes(after: 0))
            var undone = try phone.materialize(); try undone.undoConfirmation(taskID: task.id, now: now)
            try phone.capture(undone, now: now.addingTimeInterval(4)); try mac.merge(phone.changes(after: 0))
            XCTAssertNil(try mac.materialize().tasks.first?.confirmedAt)
            XCTAssertTrue(try mac.materialize().completions.isEmpty)
            // A stale confirmed task alone must not restore the undone completion.
            var row = try XCTUnwrap(mac.records["tasks/" + task.id.uuidString])
            row.payload = try JSONEncoder().encode(confirmed.tasks[0]); row.modifiedAt = Int64(now.timeIntervalSince1970 * 1000) + 5000
            row.version += 1
            try mac.merge([row])
            XCTAssertNil(try mac.materialize().tasks.first?.confirmedAt)
            var redone = try mac.materialize(); try redone.confirm(taskID: task.id, actualMinutes: minutes, now: now)
            try mac.capture(redone, now: now.addingTimeInterval(6)); try phone.merge(mac.changes(after: 0))
            XCTAssertEqual(try phone.materialize().tasks.first?.confirmedAt, now)
        }
    }

    func testOfflineConfirmationRecoversDeletedDraft() throws {
        var mac = SyncLedger(), phone = SyncLedger(); var state = fixture()
        let task = ScheduledTask(courseID: state.courses[0].id, start: Date().addingTimeInterval(-7200), durationMinutes: 60)
        state.tasks = [task]; try mac.capture(state); try phone.merge(mac.changes(after: 0))
        var confirmed = state; try confirmed.confirm(taskID: task.id, actualMinutes: 60, now: Date()); try mac.capture(confirmed)
        state.tasks = []; try phone.capture(state)
        try phone.merge(mac.changes(after: 0)); try mac.merge(phone.changes(after: 0))
        XCTAssertEqual(try mac.materialize(), try phone.materialize())
        XCTAssertEqual(try phone.materialize().tasks.first?.confirmedAt, confirmed.tasks[0].confirmedAt)
    }

    func testLegacyRecordsPreserveConfirmationAndNewEditsTakePriority() throws {
        var ledger = SyncLedger(); var state = fixture()
        let task = ScheduledTask(courseID: state.courses[0].id, start: Date().addingTimeInterval(-7200), durationMinutes: 60)
        state.tasks = [task]; try state.confirm(taskID: task.id, actualMinutes: 0, now: Date())
        try ledger.capture(state)
        for key in Array(ledger.records.keys) { ledger.records[key]?.modifiedAt = nil }
        ledger = try JSONDecoder().decode(SyncLedger.self, from: JSONEncoder().encode(ledger))
        let courseKey = "courses/" + state.courses[0].id.uuidString
        var legacy = try XCTUnwrap(ledger.records[courseKey]); legacy.version = 100_000
        try ledger.merge([legacy])
        var updated = try ledger.materialize(); updated.courses[0].notes = "新修改"
        try ledger.capture(updated)
        legacy.version += 1; try ledger.merge([legacy])
        XCTAssertEqual(try ledger.materialize().courses[0].notes, "新修改")
        XCTAssertNotNil(try ledger.materialize().tasks[0].confirmedAt)
        XCTAssertEqual(try ledger.materialize().completions[0].minutes, 0)
    }

    func testConfirmationWireRoundTrip() throws {
        var ledger = SyncLedger(); var state = fixture()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        state.courses[0].id = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        var task = ScheduledTask(courseID: state.courses[0].id, start: now.addingTimeInterval(-7200), durationMinutes: 60)
        task.id = stablePlannerID("confirmation-wire-task")
        state.tasks = [task]; try ledger.capture(state, now: now)
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now)
        try ledger.capture(state, now: now.addingTimeInterval(1))
        var stale = try XCTUnwrap(ledger.records["tasks/" + task.id.uuidString])
        stale.payload = try JSONEncoder().encode(task); stale.version += 100
        stale.modifiedAt = Int64(now.timeIntervalSince1970 * 1000) + 2000
        try ledger.merge([stale])
        try JSONEncoder().encode(ledger).write(to: URL(fileURLWithPath: "/tmp/study-confirmation-swift-fixture.json"))
        let reply = URL(fileURLWithPath: "/tmp/study-confirmation-java-fixture.json")
        if FileManager.default.fileExists(atPath: reply.path) {
            let phone = try JSONDecoder().decode(SyncLedger.self, from: Data(contentsOf: reply))
            try ledger.merge(phone.changes(after: 0))
            XCTAssertNil(try ledger.materialize().tasks.first?.confirmedAt)
            XCTAssertTrue(try ledger.materialize().completions.isEmpty)
        }
    }

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
        let floatingPath = URL(fileURLWithPath: "/tmp/study-floating-java-fixture.json")
        if FileManager.default.fileExists(atPath: floatingPath.path) {
            let ledger = try JSONDecoder().decode(SyncLedger.self, from: Data(contentsOf: floatingPath))
            let state = try ledger.materialize()
            XCTAssertEqual(state.fixedEvents.first?.floatingDurationMinutes, 60)
            XCTAssertTrue(state.tasks.allSatisfy(\.isFloating))
        }
        var s = fixture(); s.courses[0].id = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        var l = SyncLedger(); l.device = "MAC-FIXTURE"; try l.capture(s, now: Date(timeIntervalSince1970: 1))
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

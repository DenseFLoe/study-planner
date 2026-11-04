import XCTest
import StudyCore
@testable import StudyPersistence

final class PlannerBackupRestoreRepositoryTests: XCTestCase {
    @MainActor func testConcurrentPeerEditRejectsRestoreAndFreshReviewReplacesAllRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("planner.store")
        let repository = try LocalRepository(url: url), day = Calendar.current.startOfDay(for: Date())
        var original = PlannerState()
        original.courses = [Course(name: "Reviewed course", totalMinutes: 120, startDate: day, deadline: day)]
        original.tasks = [.init(courseID: original.courses[0].id, start: day.addingTimeInterval(8 * 3600), durationMinutes: 60)]
        try repository.save(original)
        let reviewed = try repository.load(), backup = PlannerBackup(state: PlannerState(), reason: "Reviewed empty backup")
        let pending = PlannerBackupRestore(backup: backup, reviewedState: reviewed)
        let peer = try LocalRepository(url: url)
        var incoming = try peer.load()
        incoming.courses[0].notes = "Received after review"
        try incoming.confirm(taskID: incoming.tasks[0].id, actualMinutes: 20, now: Date())
        try peer.save(incoming)
        let committed = try peer.load(), sequence = try peer.loadLedger().sequence
        XCTAssertThrowsError(try repository.restoreBackup(pending)) { XCTAssertTrue($0 is PlannerBackupRestoreError) }
        let reopened = try LocalRepository(url: url)
        XCTAssertEqual(try reopened.load(), committed)
        XCTAssertEqual(try reopened.loadLedger().sequence, sequence)

        let saved = try reopened.restoreBackup(.init(backup: backup, reviewedState: committed))
        XCTAssertTrue(saved.courses.isEmpty && saved.tasks.isEmpty && saved.completions.isEmpty)
        let final = try LocalRepository(url: url)
        XCTAssertEqual(try final.load(), saved)
        let synced = try final.loadLedger().materialize()
        XCTAssertTrue(synced.courses.isEmpty && synced.tasks.isEmpty && synced.completions.isEmpty)
    }
}

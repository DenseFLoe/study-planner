#if os(macOS)
import XCTest
import StudyCore
@testable import StudyPersistence

final class AssistantScheduleTransactionTests: XCTestCase {
    @MainActor func testConcurrentDiskChangeRejectsPreviewAndPreservesLedger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("planner.store"), now = Date()
        let repository = try LocalRepository(url: url)
        var original = PlannerState()
        original.courses = [.init(name: "合成课程", totalMinutes: 60, startDate: now, deadline: now + 86400)]
        try repository.save(original)
        let reviewed = try repository.load()
        let draft = try AssistantScheduleChange(state: reviewed, action: "auto_schedule", courseID: reviewed.courses[0].id, value: "false", now: now)
        let peer = try LocalRepository(url: url)
        var incoming = try peer.load(); incoming.courses[0].notes = "并发修改"
        try peer.save(incoming)
        let saved = try peer.load(), sequence = try peer.loadLedger().sequence
        XCTAssertThrowsError(try repository.saveAssistantChange(draft, now: { now }))
        let reopened = try LocalRepository(url: url)
        XCTAssertEqual(try reopened.load(), saved)
        XCTAssertEqual(try reopened.loadLedger().sequence, sequence)
        let fresh = try AssistantScheduleChange(state: saved, action: "auto_schedule", courseID: saved.courses[0].id, value: "false", now: now)
        let applied = try reopened.saveAssistantChange(fresh, now: { now })
        XCTAssertEqual(applied, fresh.preview)
        XCTAssertThrowsError(try reopened.saveAssistantChange(fresh, now: { now }))
        XCTAssertEqual(try reopened.loadLedger().materialize().courses[0].notes, "并发修改")
        XCTAssertFalse(try reopened.load().courses[0].autoScheduleEnabled)
    }
}
#endif

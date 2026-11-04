import XCTest
import StudyCore
@testable import StudyPersistence

final class DailyTaskSwapRepositoryTests: XCTestCase {
    private func fixture() -> PlannerState {
        let day = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        var state = PlannerState()
        state.courses = (0..<2).map { Course(name: "Course \($0)", totalMinutes: 120, startDate: day, deadline: day) }
        state.tasks = state.courses.enumerated().map { ScheduledTask(courseID: $0.element.id, start: day.addingTimeInterval(Double(480 + $0.offset * 75) * 60), durationMinutes: 60) }
        return state
    }
    @MainActor func testFinalTransactionProtectsPeerConfirmationAndRecognizesIdenticalSwap() throws {
        for identical in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("planner.store")
            let repository = try LocalRepository(url: url)
            try repository.save(fixture())
            let baseline = try repository.load()
            let draft = try DailyTaskSwapDraft(state: baseline, sourceID: baseline.tasks[0].id, targetID: baseline.tasks[1].id)
            let peer = try LocalRepository(url: url)
            var remote = identical ? draft.preview : baseline
            if !identical { try remote.confirm(taskID: baseline.tasks[0].id, actualMinutes: 20, now: Date()) }
            remote.courses[0].notes = "Peer notes after preview"
            try peer.save(remote)
            let committed = try peer.load()
            if identical {
                let saved = try repository.saveDailyTaskSwap(draft)
                XCTAssertEqual(saved.tasks, committed.tasks)
                XCTAssertEqual(saved.settings, committed.settings)
            } else {
                XCTAssertThrowsError(try repository.saveDailyTaskSwap(draft)) { XCTAssertTrue($0 is DailyTaskSwapError) }
            }
            let reopened = try LocalRepository(url: url).load()
            XCTAssertEqual(reopened, committed)
        }
    }
    @MainActor func testSaveUsesCurrentDayInsteadOfPreviewDay() throws {
        let repository = try LocalRepository(inMemory: true)
        try repository.save(fixture())
        let baseline = try repository.load()
        let draft = try DailyTaskSwapDraft(state: baseline, sourceID: baseline.tasks[0].id, targetID: baseline.tasks[1].id)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: baseline.tasks[0].start)!
        XCTAssertThrowsError(try repository.saveDailyTaskSwap(draft, now: { nextDay })) {
            guard case DailyTaskSwapError.pastDay = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try repository.load(), baseline)
    }
}

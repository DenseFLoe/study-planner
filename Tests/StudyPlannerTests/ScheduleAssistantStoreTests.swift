import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

@MainActor final class ScheduleAssistantStoreTests: XCTestCase {
    func testConfirmedPreviewUsesExistingSaveAndRejectsRepeatOrStaleState() async throws {
        let repository = try LocalRepository(inMemory: true), now = Date()
        var original = PlannerState()
        original.courses = [.init(name: "合成课程", totalMinutes: 60, startDate: now, deadline: now + 86400)]
        try repository.save(original)
        let state = try repository.load()
        let store = PlannerStore(state: state, repository: repository, result: ScheduleEngine().assessSavedPlan(state: state, now: now))
        let draft = try AssistantScheduleChange(state: state, action: "auto_schedule", courseID: state.courses[0].id, value: "false", now: now)
        let saved = await store.saveAssistantChange(draft)
        XCTAssertTrue(saved); XCTAssertEqual(store.state, draft.preview)
        XCTAssertFalse(try repository.load().courses[0].autoScheduleEnabled)
        let repeated = await store.saveAssistantChange(draft)
        XCTAssertFalse(repeated); XCTAssertFalse(store.orderSaveBusy)
        XCTAssertFalse(store.backupEntries.isEmpty)
    }
}

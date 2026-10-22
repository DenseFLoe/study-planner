import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class DailyConsequenceControllerTests: XCTestCase {
    private func fixture() -> (PlannerState, ScheduleResult, Date) {
        let calendar = Calendar.current, day = calendar.startOfDay(for: Date())
        let now = calendar.date(byAdding: .hour, value: 8, to: day)!
        var state = PlannerState()
        var c = Course(name: "模拟课程", totalMinutes: 240, startDate: day, deadline: calendar.date(byAdding: .day, value: 2, to: day)!)
        c.type = .lessonBasedRecorded
        c.manualLessons = (0..<4).map { .init(id: "lesson\($0)", name: "第\($0)节", durationMinutes: 60) }
        state.courses = [c]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 615) }
        let result = state.replan(now: now)
        return (state, result, now)
    }
    @MainActor func testChangingBurdenReminderDoesNotShrinkDailyGoalAfterPartialCompletion() async throws {
        var (state, result, now) = fixture()
        let controller = DailyConsequenceController(inMemory: true)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        let original = controller.today?.goalMinutes
        now = now.addingTimeInterval(1800)
        try state.confirm(taskID: result.tasks[0].id, actualMinutes: 30, now: now)
        result = state.replan(now: now)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 90)
        controller.cancel()
        XCTAssertEqual(controller.today?.goalMinutes, original)
        XCTAssertEqual(controller.today?.warningMinutes, 90)
    }
    @MainActor func testGoalIsFrozenAndEachCrossedBandCelebratesOnlyOnceIncludingAfterRestart() async throws {
        var (state, result, now) = fixture()
        let repository = DailyConsequenceRepository(inMemory: true)
        let controller = DailyConsequenceController(repository: repository)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        let goal = controller.today?.goalMinutes
        now = now.addingTimeInterval(30 * 60)
        try state.confirm(taskID: result.tasks[0].id, actualMinutes: 30, now: now)
        result = state.replan(now: now)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        XCTAssertEqual(controller.today?.goalMinutes, goal)
        XCTAssertEqual(controller.confirmedToday, 30)
        XCTAssertEqual(controller.celebrationEvents[0], 1)
        XCTAssertNil(controller.celebrationEvents[250])
        let next = try XCTUnwrap(result.tasks.first { Calendar.current.isDate($0.start, inSameDayAs: now) })
        now = next.start.addingTimeInterval(60)
        try state.confirm(taskID: next.id, actualMinutes: 1, now: now)
        result = state.replan(now: now)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        XCTAssertEqual(controller.celebrationEvents[250], 1)
        XCTAssertEqual(controller.today?.goalMinutes, goal)
        await controller.waitForPersistence()
        let restored = DailyConsequenceController(repository: repository)
        await restored.refresh(state: state, result: result, now: now, warningMinutes: 120)
        restored.cancel()
        XCTAssertEqual(restored.today?.goalMinutes, goal)
        XCTAssertTrue(restored.celebrationEvents.isEmpty)
        XCTAssertTrue(restored.today?.achieved(250, confirmed: restored.confirmedToday) == true)
        try state.undoConfirmation(taskID: next.id, now: now)
        result = state.replan(now: now)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        XCTAssertFalse(controller.today?.achieved(250, confirmed: controller.confirmedToday) == true)
        XCTAssertEqual(controller.celebrationEvents[250], 1)
    }
    @MainActor func testRolloverShowsReviewedYesterdayAndFreshTodayWithoutCelebrationReplay() async throws {
        var (state, result, now) = fixture()
        let controller = DailyConsequenceController(inMemory: true)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        let original = try XCTUnwrap(controller.today)
        for task in original.plannedToday { try state.confirm(taskID: task.id, actualMinutes: 0, now: now, studyDate: now) }
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        result = state.replan(now: nextDay)
        await controller.refresh(state: state, result: result, now: nextDay, warningMinutes: 120)
        await controller.waitForYesterday()
        controller.cancel()
        XCTAssertEqual(controller.yesterday?.date, original.date)
        XCTAssertEqual(controller.yesterday?.confirmedMinutes, 0)
        XCTAssertEqual(controller.yesterday?.isReviewed, true)
        XCTAssertEqual(controller.confirmedToday, 0)
        XCTAssertNotEqual(controller.today?.date, original.date)
        XCTAssertTrue(controller.celebrationEvents.isEmpty)
    }
}

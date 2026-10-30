import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class CompressedScheduleControllerTests: XCTestCase {
    private actor Gate {
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        var count = 0
        func hold(_ state: PlannerState, now: Date, calendar: Calendar) async throws -> CompressedSchedule {
            let result = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: now)
            count += 1
            let index = count
            await withCheckedContinuation { waiting[index] = $0 }
            return result // Deliberately ignores cancellation to exercise stale results.
        }
        func release(_ index: Int) { waiting.removeValue(forKey: index)?.resume() }
        func waitForCount(_ expected: Int) async {
            while count < expected { await Task.yield() }
        }
    }
    private func fixture() -> (PlannerState, Date) {
        var state = PlannerState()
        let calendar = Calendar.current
        let now = ScheduleEngine().instant(day: Date(), minute: 480)
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 600) }
        state.courses = [Course(name: "课程", totalMinutes: 60, startDate: calendar.startOfDay(for: now), deadline: now)]
        return (state, now)
    }

    @MainActor func testMainActorRemainsUsableAndOldCalculationCannotOverwriteNewInput() async throws {
        var (state, now) = fixture()
        let gate = Gate()
        let controller = CompressedScheduleController { try await gate.hold($0, now: $1, calendar: $2) }
        var delivered: [CompressedSchedulePreview] = []
        controller.onResolved = { delivered.append($0) }
        controller.update(state: state, now: now)
        await gate.waitForCount(1)
        XCTAssertTrue(controller.calculating)
        XCTAssertNil(controller.plan)
        // This UI-side mutation executes while the first background job is held.
        state.courses[0].totalMinutes = 30
        controller.update(state: state, now: now)
        await gate.waitForCount(2)
        await gate.release(2)
        await controller.waitForCalculation()
        let finish = controller.plan?.finish
        XCTAssertEqual(finish, now.addingTimeInterval(30 * 60))
        XCTAssertFalse(controller.calculating)
        await gate.release(1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.plan?.finish, finish)
        XCTAssertFalse(controller.calculating)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.courses.first?.remainingMinutes, 30)
    }

    @MainActor func testBaselineSleepsAcrossDraftChangesProgressUndoAndDays() async throws {
        var (state, now) = fixture()
        let controller = CompressedScheduleController()
        controller.update(state: state, now: now)
        await controller.waitForCalculation()
        let captured = controller.plan?.capturedAt
        XCTAssertNotNil(captured)
        XCTAssertFalse(controller.calculating)
        state.tasks = [.init(courseID: state.courses[0].id, start: now, durationMinutes: 60)]
        controller.update(state: state, now: now.addingTimeInterval(60))
        XCTAssertEqual(controller.plan?.capturedAt, captured)
        XCTAssertFalse(controller.calculating)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        controller.update(state: state, now: tomorrow)
        await controller.waitForCalculation()
        XCTAssertEqual(controller.plan?.capturedAt, captured)
        try state.confirm(taskID: state.tasks[0].id, actualMinutes: 30, now: tomorrow)
        controller.update(state: state, now: tomorrow)
        XCTAssertEqual(controller.plan?.capturedAt, captured)
        XCTAssertEqual(controller.plan?.courses.first?.remainingMinutes, 60)
        state.tasks[0].confirmedAt = nil
        state.tasks[0].status = .planned
        state.completions = []
        controller.update(state: state, now: tomorrow.addingTimeInterval(86400))
        XCTAssertEqual(controller.plan?.capturedAt, captured)
        XCTAssertFalse(controller.calculating)
    }

    @MainActor func testPresentationAndOrdinarySchedulingSettingsDoNotWakeBaseline() async {
        var (state, now) = fixture()
        state.fixedEvents = [.init(title: "固定课", startMinute: 660, endMinute: 720, startDate: now, endDate: now)]
        let controller = CompressedScheduleController()
        controller.update(state: state, now: now)
        await controller.waitForCalculation()
        state.courses[0].name = "新标题"; state.courses[0].notes = "备注"
        state.courses[0].color = "red"; state.courses[0].priority = 5
        state.courses[0].dailyStudyWeight = 3; state.courses[0].autoScheduleEnabled = false
        state.courses[0].deadline = now.addingTimeInterval(30 * 86400)
        state.courses[0].startDate = now.addingTimeInterval(86400)
        state.fixedEvents[0].title = "固定课新标题"; state.fixedEvents[0].notes = "备注"
        state.settings.availability.reverse()
        for i in state.settings.availability.indices { state.settings.availability[i].id = UUID() }
        state.settings.minimumScheduleUnit = 15 // Course uses its own 60-minute blocks.
        controller.update(state: state, now: now.addingTimeInterval(60))
        XCTAssertFalse(controller.calculating)
        XCTAssertEqual(controller.plan?.capturedAt, now)
    }

    @MainActor func testStructuralEditUsesCurrentRemainingWorkThenSleepsAgain() async throws {
        var (state, now) = fixture()
        state.courses[0].type = .lessonBasedRecorded
        state.courses[0].totalMinutes = 180
        state.courses[0].manualLessons = ["a", "b", "c"].map { .init(id: $0, name: $0, durationMinutes: 60) }
        let controller = CompressedScheduleController()
        controller.update(state: state, now: now)
        await controller.waitForCalculation()
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60, lessonID: "a")
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 60, now: now.addingTimeInterval(3600))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        controller.update(state: state, now: tomorrow)
        XCTAssertEqual(controller.plan?.courses.first?.remainingMinutes, 180)
        state.courses[0].manualLessons?.removeAll { $0.id == "b" }
        state.courses[0].totalMinutes = 120
        controller.update(state: state, now: tomorrow)
        await controller.waitForCalculation()
        XCTAssertEqual(controller.plan?.capturedAt, tomorrow)
        XCTAssertEqual(controller.plan?.courses.first?.remainingMinutes, 60)
        XCTAssertEqual(controller.plan?.tasks.map(\.lessonID), ["c"])
        controller.update(state: state, now: tomorrow.addingTimeInterval(86400))
        XCTAssertFalse(controller.calculating)
        XCTAssertEqual(controller.plan?.capturedAt, tomorrow)
    }

    @MainActor func testFutureFixedChangesAndAvailabilityRecalculateButPastEditsDoNot() async {
        var (state, now) = fixture()
        let controller = CompressedScheduleController()
        controller.update(state: state, now: now)
        await controller.waitForCalculation()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        state.fixedEvents = [.init(title: "历史课", startMinute: 480, endMinute: 540, startDate: yesterday, endDate: yesterday)]
        controller.update(state: state, now: now.addingTimeInterval(60))
        XCTAssertFalse(controller.calculating)
        XCTAssertEqual(controller.plan?.capturedAt, now)
        state.fixedEvents.append(.init(title: "新增固定课", startMinute: 480, endMinute: 540, startDate: now, endDate: now))
        let edited = now.addingTimeInterval(120)
        controller.update(state: state, now: edited)
        await controller.waitForCalculation()
        XCTAssertEqual(controller.plan?.capturedAt, edited)
        XCTAssertEqual(controller.plan?.finish, now.addingTimeInterval(120 * 60))
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 600, endMinute: 720) }
        let later = edited.addingTimeInterval(60)
        controller.update(state: state, now: later)
        await controller.waitForCalculation()
        XCTAssertEqual(controller.plan?.capturedAt, later)
        XCTAssertEqual(controller.plan?.finish, now.addingTimeInterval(180 * 60))
    }

    @MainActor func testManualRecalculationUsesNewDateAndProgressAndSurvivesRelaunch() async throws {
        var (state, now) = fixture()
        state.courses[0].totalMinutes = 120
        let cache = CompressedScheduleRepository(inMemory: true)
        let controller = CompressedScheduleController(cache: cache)
        controller.update(state: state, now: now)
        await controller.waitForCalculation()
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 60, now: now.addingTimeInterval(3600))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let reopened = CompressedScheduleController(cache: cache)
        reopened.update(state: state, now: tomorrow)
        XCTAssertFalse(reopened.calculating)
        XCTAssertEqual(reopened.plan?.capturedAt, now)
        XCTAssertEqual(reopened.plan?.courses.first?.remainingMinutes, 120)
        reopened.recalculate(state: state, now: tomorrow)
        await reopened.waitForCalculation()
        XCTAssertEqual(reopened.plan?.capturedAt, tomorrow)
        XCTAssertEqual(reopened.plan?.courses.first?.remainingMinutes, 60)
        XCTAssertEqual(reopened.plan?.finish, tomorrow.addingTimeInterval(3600))
        let again = CompressedScheduleController(cache: cache)
        again.update(state: state, now: tomorrow.addingTimeInterval(86400))
        XCTAssertFalse(again.calculating)
        XCTAssertEqual(again.plan?.capturedAt, tomorrow)
        XCTAssertEqual(again.sharedPreview, reopened.sharedPreview)
    }

    @MainActor func testStoreRunsIndependentPreviewWithoutSavingOrChangingOfficialSchedule() async {
        final class Repository: PlannerRepository {
            var saves = 0
            func load() throws -> PlannerState { PlannerState() }
            func save(_ state: PlannerState) throws { saves += 1 }
        }
        let (state, now) = fixture()
        let repository = Repository()
        let result = ScheduleEngine().generate(state: state, now: now)
        let store = PlannerStore(state: state, repository: repository, result: result)
        await store.compressedPlan.waitForCalculation()
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(store.result.tasks, result.tasks)
        XCTAssertEqual(repository.saves, 0)
        XCTAssertFalse(store.compressedPlan.calculating)
        XCTAssertFalse(store.syncBusy)
    }
}

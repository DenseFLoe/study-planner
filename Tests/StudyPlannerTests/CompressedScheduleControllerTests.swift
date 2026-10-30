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

    @MainActor func testStopsAfterCompletionIgnoresDraftChangesAndRefreshesNextDay() async {
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
        XCTAssertEqual(controller.plan?.capturedAt, tomorrow)
        XCTAssertFalse(controller.calculating)
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

import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class SavedScheduleAssessmentTests: XCTestCase {
    private final class Repository: PlannerRepository {
        var saved: PlannerState?
        var fails = false
        func load() throws -> PlannerState { saved ?? PlannerState() }
        func save(_ state: PlannerState) throws {
            if fails { throw CocoaError(.fileWriteUnknown) }
            saved = state
        }
    }

    private func fixture() throws -> (PlannerState, Date) {
        let calendar = Calendar.current
        let now = ScheduleEngine().instant(day: Date(), minute: 480)
        var state = PlannerState()
        var course = Course(name: "分段课程", totalMinutes: 90, startDate: now, deadline: now)
        course.type = .lessonBasedRecorded
        course.manualLessons = [.init(id: "selected", name: "选中课节", durationMinutes: 90)]
        state.courses = [course]
        let weekday = calendar.component(.weekday, from: now)
        state.settings.availability = [
            .init(weekday: weekday, startMinute: 480, endMinute: 540),
            .init(weekday: weekday, startMinute: 600, endMinute: 660)
        ]
        _ = try state.studyImmediately(courseID: course.id, now: now)
        var other = Course(name: "尚未排入的课程", totalMinutes: 60, startDate: now, deadline: now)
        other.minimumBlockMinutes = 60
        state.courses.append(other)
        return (state, now)
    }

    @MainActor func testEarlyFullConfirmationKeepsSavedSlotsAndDoesNotHideUnscheduledWork() throws {
        let (state, now) = try fixture()
        let repository = Repository()
        let first = try XCTUnwrap(state.settings.immediateStudy?.task)
        let remaining = state.tasks.filter { $0.id != first.id }
        XCTAssertEqual(first.durationMinutes, 60)
        XCTAssertEqual(remaining.map(\.durationMinutes), [30])
        let store = PlannerStore(state: state, repository: repository,
                                 result: ScheduleEngine().assessSavedPlan(state: state, now: now))
        let confirmedAt = now.addingTimeInterval(20)
        XCTAssertTrue(store.confirm(first, minutes: 60, now: confirmedAt))
        let alternative = ScheduleEngine().generate(state: store.state, now: confirmedAt)
        XCTAssertEqual(ScheduleHealthAnalyzer().assess(state: store.state, result: alternative, now: confirmedAt)?.unscheduledMinutes, 0)
        XCTAssertEqual(store.state.tasks.filter(\.isUnconfirmed), remaining)
        XCTAssertEqual(store.result.tasks, remaining)
        XCTAssertEqual(repository.saved, store.state)
        let health = try XCTUnwrap(ScheduleHealthAnalyzer().assess(state: store.state, result: store.result, now: confirmedAt))
        XCTAssertEqual(health.unscheduledMinutes, 60)
        XCTAssertEqual(health.status, .pending)
        XCTAssertEqual(health.dayPlans.reduce(0) { $0 + $1.plannedMinutes }, 30)
        XCTAssertEqual(store.result.risks.last?.unscheduledMinutes, 60)
        XCTAssertEqual(store.state.completedMinutes(for: state.courses[0]), 60)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testFailedConfirmationKeepsProgressTimetableAndWarning() throws {
        let (state, now) = try fixture()
        let repository = Repository()
        repository.fails = true
        let result = ScheduleEngine().assessSavedPlan(state: state, now: now)
        let store = PlannerStore(state: state, repository: repository, result: result)
        XCTAssertFalse(store.confirm(try XCTUnwrap(state.settings.immediateStudy?.task), minutes: 60, now: now.addingTimeInterval(20)))
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(store.result.tasks, result.tasks)
        XCTAssertEqual(store.result.risks, result.risks)
        XCTAssertNil(repository.saved)
    }

    func testFloatingTaskStaysBookedUntilItsWholeConfirmationWindowEnds() throws {
        let (initial, now) = try fixture()
        var state = initial
        state.settings.immediateStudy = nil
        state.courses = [state.courses[1]]
        var task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60)
        task.floatingWindowStart = now
        task.floatingWindowEnd = now.addingTimeInterval(3 * 3600)
        state.tasks = [task]
        let duringWindow = now.addingTimeInterval(90 * 60)
        let saved = state
        let result = ScheduleEngine().assessSavedPlan(state: state, now: duringWindow)
        XCTAssertEqual(result.tasks, [task])
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(state, saved)
        let ended = ScheduleEngine().assessSavedPlan(state: state, now: task.planningEnd)
        XCTAssertTrue(ended.tasks.isEmpty)
        XCTAssertEqual(ended.risks.last?.unscheduledMinutes, 60)
    }

    @MainActor func testSyncOnlyRefreshAssessesLoadedTimetableInsteadOfAnotherDraft() async throws {
        var (state, now) = try fixture()
        state.settings.immediateStudy = nil
        // Move the snapshot to tomorrow so this case is independent of wall-clock time.
        let day = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let shift = day.timeIntervalSince(now)
        for index in state.courses.indices {
            state.courses[index].startDate = day
            state.courses[index].deadline = day
        }
        state.settings.availability = (1...7).flatMap { weekday in
            [DailyAvailability(weekday: weekday, startMinute: 480, endMinute: 540),
             DailyAvailability(weekday: weekday, startMinute: 600, endMinute: 660)]
        }
        for index in state.tasks.indices { state.tasks[index].start.addTimeInterval(shift) }
        state.tasks.removeLast()
        let peer = state
        let store = PlannerStore(state: peer, repository: Repository(),
                                 result: ScheduleEngine().assessSavedPlan(state: peer, now: Date()))
        store.beginCloudSync(operation: { throw URLError(.cancelled) }, snapshot: { (peer, SyncLedger()) })
        await store.syncTask?.value
        XCTAssertEqual(store.state.tasks, peer.tasks)
        XCTAssertEqual(store.result.tasks, peer.tasks)
        let health = try XCTUnwrap(ScheduleHealthAnalyzer().assess(state: store.state, result: store.result, now: Date()))
        XCTAssertEqual(health.unscheduledMinutes, 90)
        XCTAssertNil(store.errorMessage)
    }
}

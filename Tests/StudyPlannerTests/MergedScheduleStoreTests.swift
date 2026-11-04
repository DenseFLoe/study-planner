import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class MergedScheduleStoreTests: XCTestCase {
    @MainActor func testMergedPlanPublishedByStoreMatchesDurableTasks() async throws {
        let now = Date(), calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var baseline = PlannerState()
        baseline.courses = [Course(name: "Concurrent", totalMinutes: 120, startDate: day, deadline: day, minimumBlockMinutes: 0)]
        baseline.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 660) }
        let result = baseline.replan(now: now)
        let repository = try LocalRepository(inMemory: true)
        try repository.save(baseline)
        let store = PlannerStore(state: baseline, repository: repository, result: result)
        var remote = baseline
        remote.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 780, endMinute: 960) }
        _ = remote.replan(now: now)
        try repository.save(remote)
        let saved = await store.change(now: now) { $0.settings.minimumScheduleUnit = 30 }
        XCTAssertTrue(saved)
        XCTAssertEqual(store.state.tasks.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertEqual(store.result.tasks, store.state.tasks)
        XCTAssertEqual(try repository.load().tasks, store.state.tasks)
        XCTAssertEqual(try repository.loadLedger().materialize().tasks, store.state.tasks)
        XCTAssertTrue(store.result.diagnostics.isEmpty)
    }
}

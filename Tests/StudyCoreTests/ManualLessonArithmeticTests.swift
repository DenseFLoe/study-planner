import XCTest
@testable import StudyCore

final class ManualLessonArithmeticTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func course(_ lengths: [Int], total: Int = 120, baseline: Int = 0) -> Course {
        var value = Course(name: "Manual lessons", totalMinutes: total,
                           startDate: now, deadline: now.addingTimeInterval(86_400))
        value.type = .lessonBasedRecorded
        value.initialCompletedMinutes = baseline
        value.manualLessons = lengths.enumerated().map {
            .init(id: "lesson-\($0.offset)", name: "Lesson \($0.offset)", durationMinutes: $0.element)
        }
        return value
    }

    private func roundTrip(_ state: PlannerState) throws -> PlannerState {
        let before = state
        var ledger = SyncLedger()
        try ledger.capture(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let captured = try encoder.encode(ledger)
        let restored = try ledger.materialize()
        _ = try CloudArchive(ledger: ledger).validated()
        XCTAssertEqual(state, before)
        XCTAssertEqual(try encoder.encode(ledger), captured)
        return restored
    }

    func testOverflowUsesExistingWholeCourseFallbackAfterSync() throws {
        for lengths in [[Int.max, 1], [Int.max, Int.max, 122]] {
            var input = PlannerState()
            input.courses = [course(lengths)]
            let state = try roundTrip(input)
            let saved = try XCTUnwrap(state.courses.first)
            let before = state
            XCTAssertTrue(state.lessonWorkItems(for: saved).isEmpty)
            XCTAssertEqual(state.completedMinutes(for: saved), 0)
            XCTAssertEqual(state.remainingMinutes(for: saved), 120)
            XCTAssertEqual(saved.manualLessons, input.courses[0].manualLessons)
            XCTAssertEqual(state, before)
        }
    }

    func testRepresentableMaximumStillUsesManualLessons() throws {
        var input = PlannerState()
        input.courses = [course([Int.max - 1, 1], total: Int.max, baseline: 20)]
        let state = try roundTrip(input)
        let saved = try XCTUnwrap(state.courses.first)
        let before = state
        let items = state.lessonWorkItems(for: saved)
        XCTAssertEqual(items.map(\.durationMinutes), [Int.max - 1, 1])
        XCTAssertEqual(items.map(\.remainingMinutes), [Int.max - 21, 1])
        XCTAssertEqual(state.completedMinutes(for: saved), 20)
        XCTAssertEqual(state.remainingMinutes(for: saved), Int.max - 20)
        XCTAssertEqual(state, before)
    }

    func testMismatchedAndNonpositiveManualDurationsStillFallback() throws {
        for lengths in [[60, 59], [0, 120], [-1, 121], [Int.max, 0], []] {
            var input = PlannerState()
            input.courses = [course(lengths, baseline: 20)]
            let state = try roundTrip(input)
            let saved = try XCTUnwrap(state.courses.first)
            XCTAssertTrue(state.lessonWorkItems(for: saved).isEmpty)
            XCTAssertEqual(state.completedMinutes(for: saved), 20)
            XCTAssertEqual(state.remainingMinutes(for: saved), 100)
            XCTAssertEqual(saved.manualLessons, input.courses[0].manualLessons)
        }
    }

    func testNestedOverflowFallbackPreservesPrefixesAndSourceBaseline() throws {
        let leaf = course([Int.max, 1], baseline: 20)
        var branch = course([], baseline: 20)
        branch.manualLessons = nil
        branch.mergedSources = [leaf]
        let sibling = course([60], total: 60)
        var root = course([], total: 180, baseline: 20)
        root.manualLessons = nil
        root.mergedSources = [branch, sibling]
        var input = PlannerState()
        input.courses = [root]
        let state = try roundTrip(input)
        let saved = try XCTUnwrap(state.courses.first)
        let before = state
        let items = state.lessonWorkItems(for: saved)
        let fallbackID = "\(branch.id)/\(leaf.id)/whole"
        let siblingID = "\(sibling.id)/lesson-0"
        XCTAssertEqual(Set(items.map(\.id)), [fallbackID, siblingID])
        let fallback = try XCTUnwrap(items.first { $0.id == fallbackID })
        XCTAssertEqual(fallback.durationMinutes, 120)
        XCTAssertEqual(fallback.remainingMinutes, 100)
        XCTAssertEqual(items.first { $0.id == siblingID }?.remainingMinutes, 60)
        XCTAssertEqual(state.completedMinutes(for: saved), 20)
        XCTAssertEqual(state.remainingMinutes(for: saved), 160)
        XCTAssertEqual(state, before)
    }

    func testNormalConfirmationKeepsItsLessonProgress() throws {
        var input = PlannerState()
        let manual = course([60, 60], baseline: 10)
        input.courses = [manual]
        let task = ScheduledTask(courseID: manual.id, start: now.addingTimeInterval(-3600),
                                 durationMinutes: 60, lessonID: "lesson-1")
        input.tasks = [task]
        try input.confirm(taskID: task.id, actualMinutes: 20, now: now)
        let state = try roundTrip(input)
        let saved = try XCTUnwrap(state.courses.first)
        let before = state
        let items = state.lessonWorkItems(for: saved)
        XCTAssertEqual(items.map(\.id), ["lesson-0", "lesson-1"])
        XCTAssertEqual(items.map(\.remainingMinutes), [50, 40])
        XCTAssertEqual(state.completedMinutes(for: saved), 30)
        XCTAssertEqual(state.remainingMinutes(for: saved), 90)
        XCTAssertEqual(state.completions, input.completions)
        XCTAssertEqual(state, before)
    }
}

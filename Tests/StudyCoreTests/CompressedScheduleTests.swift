import XCTest
@testable import StudyCore

final class CompressedScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))! }
    private func time(_ minute: Int, day offset: Int = 0) -> Date {
        ScheduleEngine(calendar: calendar).instant(day: calendar.date(byAdding: .day, value: offset, to: day)!, minute: minute)
    }
    private func fixture(_ lessons: [[Int]], length: Int = 10) -> PlannerState {
        var state = PlannerState()
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 480 + length) }
        state.courses = lessons.enumerated().map { index, durations in
            var course = Course(name: "课程\(index)", totalMinutes: durations.reduce(0, +), startDate: day, deadline: day)
            course.type = .lessonBasedRecorded
            course.manualLessons = durations.enumerated().map { .init(id: "\(index)-\($0.offset)", name: "第\($0.offset)节", durationMinutes: $0.element) }
            return course
        }
        return state
    }
    private func checkWholeLessons(_ plan: CompressedSchedule, state: PlannerState, file: StaticString = #filePath, line: UInt = #line) {
        for course in state.courses where !course.isArchived {
            let expected = state.lessonWorkItems(for: course).filter { $0.remainingMinutes > 0 }
            let actual = plan.tasks.filter { $0.courseID == course.id }
            XCTAssertEqual(actual.map(\.lessonID), expected.map { Optional($0.id) }, file: file, line: line)
            XCTAssertEqual(actual.map(\.durationMinutes), expected.map(\.remainingMinutes), file: file, line: line)
        }
        for pair in zip(plan.tasks, plan.tasks.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.end, pair.1.start, file: file, line: line) }
        for task in plan.tasks {
            XCTAssertTrue(calendar.isDate(task.start, inSameDayAs: task.end.addingTimeInterval(-1)), file: file, line: line)
            XCTAssertFalse(plan.fixed.contains { $0.start < task.end && $0.end > task.start }, file: file, line: line)
        }
    }

    func testInterleavesWholeLessonsToMinimizeLatestCourseFinish() throws {
        let state = fixture([[6, 6], [4, 4]])
        let before = state
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        XCTAssertEqual(plan.finish, time(490, day: 1))
        XCTAssertEqual(plan.courses.compactMap(\.finish).max(), plan.finish)
        XCTAssertEqual(state, before)
        checkWholeLessons(plan, state: state)
    }

    func testBacktracksOutOfLongestFirstPackingTrapAndPreservesCourseOrder() throws {
        let state = fixture([[8], [6, 6], [4, 4, 2]])
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        XCTAssertEqual(plan.finish, time(490, day: 2))
        checkWholeLessons(plan, state: state)
    }

    func testCannotSplitAcrossFixedAppointmentOrAcrossDays() throws {
        var state = fixture([[5]])
        state.fixedEvents = [.init(title: "固定课", startMinute: 484, endMinute: 486, startDate: day, endDate: day)]
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        XCTAssertEqual(plan.tasks.first?.start, time(480, day: 1))
        XCTAssertEqual(plan.finish, time(485, day: 1))
        checkWholeLessons(plan, state: state)
    }

    func testJointlyMovesFloatingFixedEventToFinishCourseEarlier() throws {
        var state = fixture([[6]])
        var event = FixedEvent(title: "浮动课", startMinute: 480, endMinute: 490, startDate: day, endDate: day)
        event.floatingDurationMinutes = 4
        state.fixedEvents = [event]
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        XCTAssertEqual(plan.finish, time(486))
        XCTAssertEqual(plan.fixed.first?.start, time(486))
        checkWholeLessons(plan, state: state)
    }

    func testIgnoresOldDeadlinesStartDatesWeightsAndPausedFlagButKeepsProgress() throws {
        var state = fixture([[6, 4], [5]])
        state.courses[0].initialCompletedMinutes = 6
        state.courses[0].startDate = time(480, day: 30)
        state.courses[0].deadline = time(480, day: 31)
        state.courses[0].dailyStudyWeight = 3
        state.courses[0].autoScheduleEnabled = false
        state.courses[1].deadline = time(480, day: -1)
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        XCTAssertEqual(plan.finish, time(489))
        XCTAssertEqual(plan.tasks.reduce(0) { $0 + $1.durationMinutes }, 9)
        checkWholeLessons(plan, state: state)
    }

    func testOverlappingDailyWindowsDoNotDoubleCapacityAndUsesCeilingOfNow() throws {
        var state = fixture([[6], [6]])
        state.settings.availability += (1...7).map { .init(weekday: $0, startMinute: 485, endMinute: 490) }
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480).addingTimeInterval(1))
        XCTAssertEqual(plan.tasks.first?.start, time(481))
        XCTAssertEqual(plan.finish, time(486, day: 1))
        checkWholeLessons(plan, state: state)
    }

    func testLastSecondsBeforeMidnightDoNotLeavePastFloatingEventsPending() throws {
        var state = fixture([[5]])
        var event = FixedEvent(title: "今天的浮动事项", startMinute: 480, endMinute: 490, startDate: day, endDate: day)
        event.floatingDurationMinutes = 3
        state.fixedEvents = [event]
        let now = time(1440).addingTimeInterval(-1)
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: now)
        XCTAssertEqual(plan.finish, time(485, day: 1))
        XCTAssertTrue(plan.fixed.isEmpty)
        checkWholeLessons(plan, state: state)
    }

    func testEmptyAndCompletedCoursesNeedNoSearchAndInvalidSettingsGiveExplanation() throws {
        var state = fixture([[5]])
        state.courses[0].initialCompletedMinutes = 5
        state.settings.availability = []
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        XCTAssertNil(plan.finish)
        XCTAssertNil(plan.courses[0].finish)
        XCTAssertTrue(plan.tasks.isEmpty)
        state.courses[0].initialCompletedMinutes = 0
        XCTAssertThrowsError(try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))) {
            XCTAssertNotNil(($0 as? CompressedScheduleError)?.errorDescription)
        }
    }

    func testNonLessonCourseUsesExistingWholeBlocks() throws {
        var state = fixture([])
        state.courses = [Course(name: "普通课程", totalMinutes: 17, startDate: day, deadline: day, minimumBlockMinutes: 6)]
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        XCTAssertEqual(plan.tasks.map(\.durationMinutes), [6, 6, 5])
        XCTAssertEqual(plan.finish, time(485, day: 2))
    }

    func testSearchMatchesIndependentExhaustivePackingOracle() throws {
        // Enumerate full chronological course orders independently. Each job takes
        // the next whole slot, without the production bounds or dominance table.
        func oracle(_ queues: [[Int]], length: Int) -> Int {
            var best = Int.max
            func visit(_ positions: [Int], _ cursor: Int) {
                if queues.indices.allSatisfy({ positions[$0] == queues[$0].count }) { best = min(best, cursor); return }
                for c in queues.indices where positions[c] < queues[c].count {
                    let duration = queues[c][positions[c]]
                    let at = cursor % length + duration <= length ? cursor : ((cursor / length) + 1) * length
                    var next = positions; next[c] += 1
                    visit(next, at + duration)
                }
            }
            visit(queues.map { _ in 0 }, 0)
            return best
        }
        for a in 2...5 {
            for b in 2...5 {
                let queues = [[a, b], [6 - a, 6 - b], [3]]
                let state = fixture(queues, length: 6)
                let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
                let expected = oracle(queues, length: 6)
                // A completion at a slot boundary belongs to the preceding day.
                let days = (expected - 1) / 6, minute = (expected - 1) % 6 + 1
                XCTAssertEqual(plan.finish, time(480 + minute, day: days), "\(queues)")
                checkWholeLessons(plan, state: state)
            }
        }
    }

    func testJointFloatingSearchMatchesIndependentMinutePlacementOracle() throws {
        for duration in 1...3 {
            var state = fixture([[2, 1], [2]], length: 8)
            var first = FixedEvent(title: "浮动一", startMinute: 480, endMinute: 485, startDate: day, endDate: day)
            first.floatingDurationMinutes = duration
            var second = FixedEvent(title: "浮动二", startMinute: 483, endMinute: 488, startDate: day, endDate: day)
            second.floatingDurationMinutes = 2
            state.fixedEvents = [first, second]
            var best = Int.max
            for a in 0...(5 - duration) {
                for b in 3...6 where a + duration <= b || b + 2 <= a {
                    let busy = Set(a..<(a + duration)).union(b..<(b + 2))
                    let queues = [[2, 1], [2]]
                    func visit(_ positions: [Int], _ cursor: Int) {
                        if queues.indices.allSatisfy({ positions[$0] == queues[$0].count }) { best = min(best, cursor); return }
                        for c in queues.indices where positions[c] < queues[c].count {
                            let minutes = queues[c][positions[c]]
                            var start = cursor
                            while start % 8 + minutes > 8 || (start..<(start + minutes)).contains(where: { $0 < 8 && busy.contains($0) }) { start += 1 }
                            var next = positions; next[c] += 1
                            visit(next, start + minutes)
                        }
                    }
                    visit([0, 0], 0)
                }
            }
            let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
            XCTAssertEqual(plan.finish, time(480 + (best - 1) % 8 + 1, day: (best - 1) / 8))
            checkWholeLessons(plan, state: state)
            for event in plan.fixed {
                XCTAssertGreaterThanOrEqual(event.start, time(event.event.startMinute))
                XCTAssertLessThanOrEqual(event.end, time(event.event.endMinute))
            }
            for pair in zip(plan.fixed, plan.fixed.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.end, pair.1.start) }
        }
    }

    func testLargeImportDoesNotDependOnRecursiveThreadStack() throws {
        let state = fixture(Array(repeating: Array(repeating: 60, count: 250), count: 4), length: 600)
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        XCTAssertEqual(plan.tasks.count, 1000)
        XCTAssertEqual(plan.finish, time(1080, day: 99))
        checkWholeLessons(plan, state: state)
    }

    func testUnplaceableWholeLessonReturnsHorizonMessageRatherThanSplittingIt() {
        let state = fixture([[11]])
        XCTAssertThrowsError(try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))) {
            guard case CompressedScheduleError.horizon = $0 else { return XCTFail("Unexpected error") }
        }
    }

    func testCancellationStopsSearchCooperatively() async {
        let state = fixture([[5]])
        let now = time(480), calendar = calendar
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: now)
        }
        do { _ = try await task.value; XCTFail("Cancellation must stop the calculation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

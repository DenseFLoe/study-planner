import XCTest
@testable import StudyCore

final class RetainedHistoryIntervalTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 8))!
    }

    private func fixture(confirmed: Bool, extreme: Bool) throws -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "Today's lessons", totalMinutes: 120,
                            startDate: now, deadline: now.addingTimeInterval(86_400))
        course.type = .lessonBasedRecorded
        course.manualLessons = [
            .init(id: "first", name: "First", durationMinutes: 60),
            .init(id: "second", name: "Second", durationMinutes: 60)
        ]
        var historicalCourse = Course(name: "History", totalMinutes: 60,
                                      startDate: now.addingTimeInterval(-86_400), deadline: now)
        historicalCourse.autoScheduleEnabled = false
        state.courses = [course, historicalCourse]
        state.settings.availability = (1...7).map {
            .init(weekday: $0, startMinute: 480, endMinute: 1200)
        }
        // Keep the display date on yesterday so swapping today's tasks does not
        // move this historical block, and an actual-start anchor does not discard it.
        var history = ScheduledTask(courseID: historicalCourse.id,
                                    start: now.addingTimeInterval(-9 * 3600), durationMinutes: 60)
        history.floatingWindowStart = extreme
            ? Date(timeIntervalSinceReferenceDate: -1e300)
            : now.addingTimeInterval(-10 * 3600)
        history.floatingWindowEnd = now.addingTimeInterval(confirmed ? 12 * 3600 : -600)
        if confirmed {
            history.confirmedAt = now
            history.completedMinutes = 20
            history.status = .partial
        }
        state.tasks = [history]

        // These are accepted imported states, not dates constructed only inside a consumer.
        let data = try JSONEncoder().encode(PlannerBackup(state: state, reason: "History endpoint regression"))
        let backup = try JSONDecoder().decode(PlannerBackup.self, from: data).validated()
        var ledger = SyncLedger()
        try ledger.capture(backup.state)
        _ = try CloudArchive(ledger: ledger).validated()
        return try ledger.materialize()
    }

    private func earliestStart(confirmed: Bool) -> Date {
        now.addingTimeInterval(confirmed ? 900 : 300)
    }

    func testImportedHistoryRetainsBothEndpoints() throws {
        for confirmed in [false, true] {
            for extreme in [false, true] {
                let state = try fixture(confirmed: confirmed, extreme: extreme)
                let history = try XCTUnwrap(state.tasks.first)
                let interval = history.retainedHistoryInterval
                XCTAssertEqual(interval.start, history.planningStart)
                XCTAssertEqual(interval.end, confirmed ? now : now.addingTimeInterval(-600))
            }
        }
    }

    func testGenerateReservesHistoryThroughItsEndAndRest() throws {
        for confirmed in [false, true] {
            for extreme in [false, true] {
                let state = try fixture(confirmed: confirmed, extreme: extreme)
                let result = ScheduleEngine(calendar: calendar).generate(state: state, now: now)
                XCTAssertEqual(result.tasks.map(\.durationMinutes).reduce(0, +), 120)
                XCTAssertEqual(result.tasks.first?.start, earliestStart(confirmed: confirmed))
                XCTAssertTrue(result.tasks.allSatisfy { $0.start >= earliestStart(confirmed: confirmed) })
            }
        }
    }

    func testDailySwapReservesHistoricalEndAndPreservesRequestedOrder() throws {
        for confirmed in [false, true] {
            for extreme in [false, true] {
                var state = try fixture(confirmed: confirmed, extreme: extreme)
                let history = try XCTUnwrap(state.tasks.first)
                let course = try XCTUnwrap(state.courses.first { $0.type == .lessonBasedRecorded })
                let first = ScheduledTask(courseID: course.id, start: now, durationMinutes: 60, lessonID: "first")
                let second = ScheduledTask(courseID: course.id, start: now.addingTimeInterval(4500),
                                           durationMinutes: 60, lessonID: "second")
                state.tasks += [first, second]
                try state.swapDailyTasks(first.id, second.id, now: now, calendar: calendar)
                let moved = state.tasks.filter { $0.courseID == course.id }.sorted { $0.start < $1.start }
                XCTAssertEqual(moved.map(\.id), [second.id, first.id])
                XCTAssertEqual(moved.map(\.durationMinutes), [60, 60])
                XCTAssertEqual(moved.first?.start, earliestStart(confirmed: confirmed))
                XCTAssertEqual(moved.last?.start, earliestStart(confirmed: confirmed).addingTimeInterval(4500))
                XCTAssertEqual(state.tasks.first { $0.id == history.id }, history)
            }
        }
    }

    func testImmediateStudyValidityHonorsHistoryRestAndExactBoundary() throws {
        for confirmed in [false, true] {
            for extreme in [false, true] {
                var state = try fixture(confirmed: confirmed, extreme: extreme)
                let course = try XCTUnwrap(state.courses.first { $0.type == .lessonBasedRecorded })
                for start in [now, earliestStart(confirmed: confirmed).addingTimeInterval(-1)] {
                    state.settings.immediateStudy = .init(task: .init(courseID: course.id, start: start,
                        durationMinutes: 60, lessonID: "first"))
                    XCTAssertNil(state.validImmediateStudyTask(now: start, calendar: calendar))
                }
                let start = earliestStart(confirmed: confirmed)
                let task = ScheduledTask(courseID: course.id, start: start, durationMinutes: 60, lessonID: "first")
                state.settings.immediateStudy = .init(task: task)
                XCTAssertEqual(state.validImmediateStudyTask(now: start, calendar: calendar), task)
            }
        }
    }

    func testImmediateStudyRejectsHistoryRestWithoutMutatingState() throws {
        for confirmed in [false, true] {
            var state = try fixture(confirmed: confirmed, extreme: true)
            let before = state
            let course = try XCTUnwrap(state.courses.first { $0.type == .lessonBasedRecorded })
            XCTAssertThrowsError(try state.studyImmediately(courseID: course.id,
                                                            now: now, calendar: calendar)) {
                XCTAssertEqual($0 as? ImmediateStudyError, .noSpace)
            }
            XCTAssertEqual(state, before)
        }
    }

    func testEarlyConfirmationStillClampsBothEndpoints() {
        var task = ScheduledTask(courseID: UUID(), start: now, durationMinutes: 60)
        task.floatingWindowStart = now.addingTimeInterval(3600)
        task.floatingWindowEnd = now.addingTimeInterval(7200)
        for offset in [0.0, 5400, 10800] {
            let confirmation = now.addingTimeInterval(offset)
            task.confirmedAt = confirmation
            XCTAssertEqual(task.retainedHistoryInterval.start, min(task.planningStart, confirmation))
            XCTAssertEqual(task.retainedHistoryInterval.end, min(task.planningEnd, confirmation))
        }
    }
}

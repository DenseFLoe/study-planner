import XCTest
@testable import StudyCore

final class ContinueStudyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private func date(_ day: Int = 4, _ hour: Int = 8, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }
    private func fixture(lessons: Bool = true) -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "首课", totalMinutes: 150, startDate: date(4, 0), deadline: date(6, 0))
        if lessons {
            course.type = .lessonBasedRecorded
            course.manualLessons = [.init(id: "first", name: "第一节", durationMinutes: 60),
                                    .init(id: "second", name: "第二节", durationMinutes: 90)]
        }
        let other = Course(name: "后续课程", totalMinutes: 60, startDate: date(4, 0), deadline: date(6, 0))
        state.courses = [course, other]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1080) }
        // Deliberately unsorted, and the visible first lesson differs from the course queue.
        state.tasks = [ScheduledTask(courseID: other.id, start: date(4, 12), durationMinutes: 60),
                       ScheduledTask(courseID: course.id, start: date(), durationMinutes: 45,
                                     lessonID: lessons ? "second" : nil, lessonName: lessons ? "第二节" : nil)]
        return state
    }
    private func assertValid(_ result: ScheduleResult, state: PlannerState,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.risks.isEmpty, file: file, line: line)
        XCTAssertTrue(result.tasks.allSatisfy { $0.durationMinutes > 0 }, file: file, line: line)
        for (a, b) in zip(result.tasks, result.tasks.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end.addingTimeInterval(900), b.start, file: file, line: line)
        }
        for course in state.courses {
            XCTAssertEqual(result.tasks.filter { $0.courseID == course.id }.reduce(0) { $0 + $1.durationMinutes },
                           state.remainingMinutes(for: course), file: file, line: line)
        }
    }

    func testMovesVisibleFirstLessonFromElapsedDraftWithoutCreditingProgress() throws {
        var state = fixture()
        let originalCourses = state.courses
        let oldIDs = Set(state.tasks.map(\.id))
        let result = try state.continueStudying(on: date(), now: date(4, 10, 0, 17), calendar: calendar)
        let first = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(first.courseID, originalCourses[0].id)
        XCTAssertEqual(first.lessonID, "second")
        XCTAssertEqual(first.start, date(4, 10, 1))
        XCTAssertEqual(first.durationMinutes, 45)
        XCTAssertEqual(result.tasks.filter { $0.courseID == first.courseID }.map(\.lessonID), ["second", "second", "first"])
        XCTAssertEqual(state.courses, originalCourses)
        XCTAssertTrue(state.completions.isEmpty)
        XCTAssertTrue(oldIDs.isDisjoint(with: state.tasks.map(\.id)))
        assertValid(result, state: state)
    }

    func testOrdinaryBlockCanConsumeMultipleNewUnitsAndSurvivesReloadAndRepeatedContinue() throws {
        var state = fixture(lessons: false)
        state.settings.minimumScheduleUnit = 20
        let result = try state.continueStudying(on: date(), now: date(4, 9), calendar: calendar)
        XCTAssertNil(result.tasks.first?.lessonID)
        XCTAssertEqual(result.tasks.first?.durationMinutes, 45)
        assertValid(result, state: state)
        state = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        let reopened = state.replan(now: date(4, 9, 5), calendar: calendar)
        XCTAssertEqual(reopened.tasks.first, result.tasks.first)
        assertValid(reopened, state: state)
        let repeated = try state.continueStudying(on: date(), now: date(4, 9, 10), calendar: calendar)
        XCTAssertEqual(repeated.tasks.first?.start, date(4, 9, 10))
        XCTAssertEqual(repeated.tasks.first?.durationMinutes, 45)
        XCTAssertFalse(state.tasks.contains { $0.id == result.tasks.first?.id })
        XCTAssertTrue(state.completions.isEmpty)
        assertValid(repeated, state: state)
    }

    func testSelectedDayAndConfirmedHistoryAreRespected() throws {
        var state = fixture()
        let course = state.courses[0]
        let history = ScheduledTask(courseID: course.id, start: date(4, 6), durationMinutes: 60, lessonID: "first")
        state.tasks.append(history)
        try state.confirm(taskID: history.id, actualMinutes: 60, now: date(4, 7), calendar: calendar)
        let completions = state.completions
        let savedHistory = state.tasks.first { $0.id == history.id }
        let tomorrow = ScheduledTask(courseID: state.courses[1].id, start: date(5, 8), durationMinutes: 30)
        state.tasks.append(tomorrow)
        state.fixedEvents = [.init(title: "固定事项", startMinute: 660, endMinute: 720, startDate: date(), endDate: date())]
        let fixed = state.fixedEvents
        let result = try state.continueStudying(on: date(5), now: date(4, 9), calendar: calendar)
        XCTAssertEqual(result.tasks.first?.courseID, tomorrow.courseID)
        XCTAssertEqual(result.tasks.first?.durationMinutes, 30)
        XCTAssertEqual(result.tasks.first?.start, date(4, 9))
        XCTAssertEqual(state.tasks.first { $0.id == history.id }, savedHistory)
        XCTAssertEqual(state.completions, completions)
        XCTAssertEqual(state.fixedEvents, fixed)
        XCTAssertTrue(result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date()) }
            .allSatisfy { $0.end <= date(4, 11) || $0.start >= date(4, 12) })
        assertValid(result, state: state)
    }

    func testFirstRowSelectionSkipsConfirmedAndArchivedRowsWithStableTieBreak() {
        var state = fixture()
        var confirmed = state.tasks[1]
        confirmed.id = UUID(); confirmed.start = date(4, 6); confirmed.status = .missed; confirmed.confirmedAt = date(4, 7)
        var archived = state.courses[0]
        archived.id = UUID(); archived.isArchived = true
        state.courses.append(archived)
        let archivedTask = ScheduledTask(courseID: archived.id, start: date(4, 7), durationMinutes: 30)
        state.tasks += [confirmed, archivedTask]
        let expected = state.tasks[1]
        XCTAssertEqual(state.firstUnconfirmedTask(on: date(), calendar: calendar), expected)
        var tied = expected
        tied.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        state.tasks.append(tied)
        XCTAssertEqual(state.firstUnconfirmedTask(on: date(), calendar: calendar), tied)
    }

    func testRejectedContinueLeavesEntireStateUntouched() throws {
        for kind in 0..<8 {
            var state = fixture()
            var selectedDay = date()
            switch kind {
            case 0: state.tasks = []
            case 1: selectedDay = date(3)
            case 2: state.settings.availability = []
            case 3: state.fixedEvents = [.init(title: "固定事项", startMinute: 540, endMinute: 600, startDate: date(), endDate: date())]
            case 4: state.fixedEvents = [.init(title: "空档不足整块", startMinute: 560, endMinute: 600, startDate: date(), endDate: date())]
            case 5: state.courses[0].autoScheduleEnabled = false
            case 6: state.courses[0].startDate = date(5, 0)
            default:
                let history = ScheduledTask(courseID: state.courses[0].id, start: date(), durationMinutes: 60, lessonID: "first")
                state.tasks.append(history)
                try state.confirm(taskID: history.id, actualMinutes: 60, now: date(4, 9), calendar: calendar)
            }
            let original = state
            XCTAssertThrowsError(try state.continueStudying(on: selectedDay, now: date(4, 9), calendar: calendar), "case \(kind)")
            XCTAssertEqual(state, original, "case \(kind)")
        }
    }

    func testContinueReplacesPreviousImmediateRequestAndFloatingReservation() throws {
        var state = fixture()
        _ = try state.studyImmediately(courseID: state.courses[0].id, lessonID: "second", now: date(), calendar: calendar)
        let oldRequest = try XCTUnwrap(state.settings.immediateStudy)
        var event = FixedEvent(title: "浮动事项", startMinute: 540, endMinute: 720, startDate: date(), endDate: date())
        event.floatingDurationMinutes = 45
        state.fixedEvents = [event]
        let result = try state.continueStudying(on: date(), now: date(4, 9), calendar: calendar)
        let first = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(first.start, date(4, 9))
        XCTAssertEqual(first.durationMinutes, oldRequest.task.durationMinutes)
        XCTAssertEqual(first.lessonID, oldRequest.task.lessonID)
        XCTAssertNotEqual(first.id, oldRequest.task.id)
        XCTAssertEqual(state.settings.immediateStudy?.task, first)
        let reservation = try XCTUnwrap(state.immediateStudyReservation(first, calendar: calendar).nominalEvent)
        XCTAssertNotNil(FloatingPlacement.reserve([event, reservation]))
        assertValid(result, state: state)
    }
}

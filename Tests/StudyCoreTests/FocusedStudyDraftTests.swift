import XCTest
@testable import StudyCore

final class FocusedStudyDraftTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!; return value
    }
    private func date(_ day: Int = 12, _ hour: Int = 20, _ minute: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        var focus = Course(name: "合成目标课程", totalMinutes: 153, startDate: date(12, 0, 0), deadline: date(15, 0, 0))
        focus.type = .lessonBasedRecorded
        focus.manualLessons = [79, 14, 60].enumerated().map { .init(id: "lesson-\($0.offset)", name: "合成课节\($0.offset)", durationMinutes: $0.element) }
        state.courses = [focus, Course(name: "合成其他课程", totalMinutes: 600, startDate: date(12, 0, 0), deadline: date(15, 0, 0))]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 540, endMinute: 1280) }
        _ = state.replan(now: date(12, 9, 0), calendar: calendar)
        return state
    }
    func testFillsRemainingTimeAndMovesOtherCoursesAsOneDraftWithoutChangingSettingsOrProgress() throws {
        let state = fixture(), focus = state.courses[0]
        let draft = try FocusedStudyDraft(state: state, courseID: focus.id, now: date(), calendar: calendar)
        XCTAssertEqual(draft.todayTasks.map(\.durationMinutes), [77])
        XCTAssertEqual(draft.todayTasks.first?.start, date())
        XCTAssertEqual(draft.todayTasks.first?.end, date(12, 21, 20))
        XCTAssertEqual(draft.todayTasks.first?.lessonID, "lesson-0")
        XCTAssertEqual(draft.preview.courses, state.courses)
        XCTAssertEqual(draft.preview.fixedEvents, state.fixedEvents)
        XCTAssertEqual(draft.preview.completions, state.completions)
        XCTAssertEqual(draft.preview.settings.availability, state.settings.availability)
        XCTAssertEqual(draft.preview.settings.schedulePriorities, state.settings.schedulePriorities)
        let remaining = draft.preview.tasks.filter { $0.courseID == focus.id && $0.isUnconfirmed }
        XCTAssertEqual(remaining.reduce(0) { $0 + $1.durationMinutes }, 153)
        XCTAssertEqual(remaining.filter { $0.lessonID == "lesson-0" }.map(\.durationMinutes), [77, 2])
        XCTAssertTrue(draft.preview.tasks.filter { $0.courseID != focus.id && $0.isUnconfirmed }.allSatisfy { $0.start >= date(13, 0, 0) })
        XCTAssertFalse(ScheduleEngine(calendar: calendar).hasInvalidSavedTasks(state: draft.preview, now: date()))
        XCTAssertTrue(draft.assessment.risks.isEmpty)
        XCTAssertTrue(draft.assessment.dayPlans.allSatisfy { $0.plannedMinutes <= $0.availableMinutes })
    }
    func testCompletedHistoryFixedEventsAndRestSurviveAndReopenDoesNotReplan() throws {
        var state = fixture()
        let completed = ScheduledTask(courseID: state.courses[0].id, start: date(12, 10, 0), durationMinutes: 20, lessonID: "lesson-0")
        state.tasks = [completed]
        try state.confirm(taskID: completed.id, actualMinutes: 20, now: date(12, 10, 20))
        state.fixedEvents = [FixedEvent(title: "合成固定事项", startMinute: 1230, endMinute: 1245, startDate: date(), endDate: date())]
        let draft = try FocusedStudyDraft(state: state, courseID: state.courses[0].id, now: date(), calendar: calendar)
        XCTAssertEqual(draft.preview.tasks.first { $0.id == completed.id }, state.tasks.first)
        XCTAssertEqual(draft.preview.completions, state.completions)
        XCTAssertEqual(draft.preview.fixedEvents, state.fixedEvents)
        XCTAssertTrue(draft.todayTasks.allSatisfy { $0.end <= date(12, 20, 30) || $0.start >= date(12, 20, 45) })
        for (a, b) in zip(draft.todayTasks, draft.todayTasks.dropFirst()) { XCTAssertLessThanOrEqual(a.end.addingTimeInterval(900), b.start) }
        var reopened = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(draft.preview))
        XCTAssertFalse(reopened.reconcileSavedSchedule(now: date(), calendar: calendar))
        XCTAssertEqual(reopened, draft.preview)
    }
    func testDeadlineShortfallIsReportedAndNoSpaceNeverMutatesSource() throws {
        var state = fixture()
        state.courses[1].deadline = date(12, 0, 0)
        let draft = try FocusedStudyDraft(state: state, courseID: state.courses[0].id, now: date(), calendar: calendar)
        XCTAssertTrue(draft.assessment.risks.contains { $0.unscheduledMinutes >= 600 })
        XCTAssertEqual(draft.preview.courses[1].deadline, state.courses[1].deadline)
        state.settings.availability = []
        let original = state
        XCTAssertThrowsError(try FocusedStudyDraft(state: state, courseID: state.courses[0].id, now: date(), calendar: calendar))
        XCTAssertEqual(state, original)
    }
    func testFloatingEventsHaveJointSpaceAndCourseLessonsRemainOrdered() throws {
        var state = fixture()
        var event = FixedEvent(title: "合成浮动事项", startMinute: 1203, endMinute: 1280, startDate: date(), endDate: date())
        event.floatingDurationMinutes = 20; state.fixedEvents = [event]
        let draft = try FocusedStudyDraft(state: state, courseID: state.courses[0].id, now: date(), calendar: calendar)
        XCTAssertLessThanOrEqual(draft.todayTasks.reduce(0) { $0 + $1.durationMinutes }, 57)
        XCTAssertFalse(ScheduleEngine(calendar: calendar).hasInvalidSavedTasks(state: draft.preview, now: date()))
        let lessons = draft.preview.tasks.filter { $0.courseID == state.courses[0].id }.compactMap(\.lessonID)
        XCTAssertEqual(lessons, lessons.sorted())
    }
    func testReviewDelayDoesNotDiscardAnActiveImmediateLessonOrCrossMidnight() throws {
        var state = fixture()
        state.courses[0].manualLessons = [.init(id: "short", name: "合成短课节", durationMinutes: 1)]
        state.courses[0].totalMinutes = 1
        _ = try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: calendar)
        XCTAssertThrowsError(try FocusedStudyDraft(state: state, courseID: state.courses[0].id,
            now: date(), earliestStart: date().addingTimeInterval(120), calendar: calendar)) { error in
            XCTAssertEqual(error as? FocusedStudyError, .activeStudy)
        }
        XCTAssertThrowsError(try FocusedStudyDraft(state: fixture(), courseID: state.courses[0].id,
            now: date(12, 23, 59), earliestStart: date(13, 0, 1), calendar: calendar))
    }
}

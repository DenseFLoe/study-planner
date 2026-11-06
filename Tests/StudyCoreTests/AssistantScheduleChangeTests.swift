import XCTest
@testable import StudyCore

final class AssistantScheduleChangeTests: XCTestCase {
    private func fixture() -> (PlannerState, Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: .init(year: 2026, month: 11, day: 6, hour: 8))!
        var state = PlannerState()
        state.courses = [.init(name: "合成课程", totalMinutes: 60, startDate: now, deadline: now + 86400)]
        return (state, now, calendar)
    }
    func testDraftIsPureAndExactPreviewIsAppliedOnce() throws {
        let (state, now, calendar) = fixture()
        let draft = try AssistantScheduleChange(state: state, action: "auto_schedule", courseID: state.courses[0].id, value: "false", now: now, calendar: calendar)
        XCTAssertTrue(state.courses[0].autoScheduleEnabled)
        var target = state; try draft.apply(to: &target, now: now)
        XCTAssertEqual(target, draft.preview); XCTAssertFalse(target.courses[0].autoScheduleEnabled)
        XCTAssertThrowsError(try draft.apply(to: &target, now: now))
    }
    func testConcurrentChangeExpiryAndUnsupportedActionRejectWithoutMutation() throws {
        let (state, now, calendar) = fixture()
        let draft = try AssistantScheduleChange(state: state, action: "replan", courseID: nil, value: "", now: now, calendar: calendar)
        var target = state; target.courses[0].notes = "新的本地数据"
        let before = target
        XCTAssertThrowsError(try draft.apply(to: &target, now: now)); XCTAssertEqual(target, before)
        target = state
        XCTAssertThrowsError(try draft.apply(to: &target, now: now + 301)); XCTAssertEqual(target, state)
        for action in ["delete", "sync", "shell"] {
            XCTAssertThrowsError(try AssistantScheduleChange(state: state, action: action, courseID: state.courses[0].id, value: "", now: now, calendar: calendar))
        }
        for weight in ["NaN", "0.5", "4", "inf"] {
            XCTAssertThrowsError(try AssistantScheduleChange(state: state, action: "daily_weight", courseID: state.courses[0].id, value: weight, now: now, calendar: calendar))
        }
    }
    func testDeadlineAndMultiplierUseDomainEngineAndKeepCompletedHistory() throws {
        var (state, now, calendar) = fixture()
        let course = state.courses[0]
        var task = ScheduledTask(courseID: course.id, start: now - 3600, durationMinutes: 20)
        task.status = .completed
        state.tasks = [task]
        let draft = try AssistantScheduleChange(state: state, action: "deadline", courseID: course.id, value: "2026-11-09", now: now, calendar: calendar)
        XCTAssertTrue(draft.preview.tasks.contains(task))
        XCTAssertEqual(draft.preview.completions, state.completions)
        XCTAssertEqual(draft.preview.fixedEvents, state.fixedEvents)
        let weighted = try AssistantScheduleChange(state: state, action: "daily_weight", courseID: course.id, value: "2", now: now, calendar: calendar)
        XCTAssertEqual(weighted.preview.courses[0].dailyWeight, 2)
    }
}

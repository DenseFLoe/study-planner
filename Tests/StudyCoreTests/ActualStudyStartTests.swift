import XCTest
@testable import StudyCore

final class ActualStudyStartTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func date(_ day: Int = 3, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func fixture(minutes: Int = 240, deadline: Int = 4, endMinute: Int = 18 * 60) -> PlannerState {
        var state = PlannerState()
        state.courses = [.init(name: "数学", totalMinutes: minutes, startDate: date(2), deadline: date(deadline))]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: endMinute) }
        return state
    }
    private func total(_ tasks: [ScheduledTask]) -> Int { tasks.reduce(0) { $0 + $1.durationMinutes } }

    func testPastActualStartRemainsTheAnchorAfterReopeningAndReplanning() throws {
        var state = fixture()
        _ = state.replan(now: date(3, 8), calendar: calendar)
        try state.recordActualStudyStart(minute: 630, now: date(3, 14), calendar: calendar)
        let result = state.replan(now: date(3, 14), calendar: calendar)
        XCTAssertEqual(result.tasks.first?.start, date(3, 10, 30))
        XCTAssertEqual(total(result.tasks), 240)
        XCTAssertEqual(state.tasks, result.tasks)
        let reopened = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        state = reopened
        let again = state.replan(now: date(3, 16), calendar: calendar)
        XCTAssertEqual(again.tasks, result.tasks)
        XCTAssertEqual(Set(state.tasks.map(\.id)).count, state.tasks.count)
    }

    func testBalancingUsesFirstAvailableWindowAfterActualStart() throws {
        var state = fixture()
        state.settings.availability = (1...7).flatMap {
            [DailyAvailability(weekday: $0, startMinute: 480, endMinute: 600),
             DailyAvailability(weekday: $0, startMinute: 840, endMinute: 1080)]
        }
        try state.recordActualStudyStart(minute: 510, now: date(3, 16), calendar: calendar)
        let result = state.replan(now: date(3, 16), calendar: calendar)
        XCTAssertEqual(result.tasks.first?.start, date(3, 8, 30))
        XCTAssertEqual(total(result.tasks), 240)
        XCTAssertTrue(result.risks.isEmpty)
        for task in result.tasks {
            XCTAssertTrue(task.end <= date(3, 10) || task.start >= date(3, 14))
        }
    }

    func testLateStartSpillsIntoFutureDaysWithoutChangingTheirAvailability() throws {
        var state = fixture(minutes: 240, endMinute: 12 * 60)
        try state.recordActualStudyStart(minute: 660, now: date(3, 10), calendar: calendar)
        let result = state.replan(now: date(3, 10), calendar: calendar)
        XCTAssertTrue(result.risks.isEmpty)
        let today = result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date()) }
        let tomorrow = result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date(4)) }
        XCTAssertEqual(total(today), 60)
        XCTAssertEqual(today.first?.start, date(3, 11))
        XCTAssertEqual(total(tomorrow), 180)
        XCTAssertEqual(tomorrow.first?.start, date(4, 8))
    }

    func testUnavailableStartUsesNextWindowAndReportsInsufficientCapacity() throws {
        var state = fixture(minutes: 120, deadline: 3, endMinute: 10 * 60)
        try state.recordActualStudyStart(minute: 7 * 60, now: date(3, 9), calendar: calendar)
        let early = state.replan(now: date(3, 9), calendar: calendar)
        XCTAssertEqual(early.tasks.first?.start, date(3, 8))
        try state.recordActualStudyStart(minute: 23 * 60 + 59, now: date(3, 9), calendar: calendar)
        let late = state.replan(now: date(3, 9), calendar: calendar)
        XCTAssertTrue(late.tasks.isEmpty)
        XCTAssertEqual(late.risks.first?.unscheduledMinutes, 120)
    }

    func testPreservesHistoryConfirmedProgressAndFixedAppointments() throws {
        var state = fixture()
        let course = state.courses[0]
        let yesterday = ScheduledTask(courseID: course.id, start: date(2, 8), durationMinutes: 60)
        let done = ScheduledTask(courseID: course.id, start: date(3, 8), durationMinutes: 60)
        let obsolete = ScheduledTask(courseID: course.id, start: date(3, 9, 15), durationMinutes: 60)
        state.tasks = [yesterday, done, obsolete]
        try state.confirm(taskID: done.id, actualMinutes: 60, now: date(3, 9))
        let completions = state.completions
        let event = FixedEvent(title: "午饭", startMinute: 600, endMinute: 720, startDate: date(), endDate: date())
        state.fixedEvents = [event]
        try state.recordActualStudyStart(minute: 630, now: date(3, 14), calendar: calendar)
        let result = state.replan(now: date(3, 14), calendar: calendar)
        XCTAssertTrue(state.tasks.contains(yesterday))
        XCTAssertEqual(state.tasks.first { $0.id == done.id }?.status, .completed)
        XCTAssertFalse(state.tasks.contains { $0.id == obsolete.id })
        XCTAssertEqual(state.completions, completions)
        XCTAssertEqual(state.fixedEvents, [event])
        XCTAssertEqual(total(result.tasks), 180)
        XCTAssertTrue(result.tasks.allSatisfy { $0.start >= date(3, 12) })
        for pair in zip(result.tasks, result.tasks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.start.timeIntervalSince(pair.0.end), 15 * 60)
        }
    }

    func testTomorrowExpiresOverrideAndKeepsYesterdayScheduleAsHistory() throws {
        var state = fixture()
        try state.recordActualStudyStart(minute: 660, now: date(3, 10), calendar: calendar)
        _ = state.replan(now: date(3, 10), calendar: calendar)
        let yesterday = state.tasks.filter { calendar.isDate($0.start, inSameDayAs: date()) }
        let result = state.replan(now: date(4, 7), calendar: calendar)
        XCTAssertNil(state.settings.actualStudyStart(on: date(4), calendar: calendar))
        XCTAssertEqual(result.tasks.first?.start, date(4, 8))
        XCTAssertTrue(yesterday.allSatisfy { state.tasks.contains($0) })
    }

    func testConfirmedTaskAtAnchorRetainsBreakAndDeductsProgress() throws {
        var state = fixture(minutes: 120, deadline: 3)
        try state.recordActualStudyStart(minute: 600, now: date(3, 10), calendar: calendar)
        _ = state.replan(now: date(3, 10), calendar: calendar)
        let first = try XCTUnwrap(state.tasks.first)
        try state.confirm(taskID: first.id, actualMinutes: 60, now: date(3, 11))
        let result = state.replan(now: date(3, 12), calendar: calendar)
        XCTAssertEqual(result.tasks.first?.start, date(3, 11, 15))
        XCTAssertEqual(total(result.tasks), 60)
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 60)
    }

    func testChangedStartReplacesPriorDraftAndInvalidInputDoesNotMutate() throws {
        var state = fixture()
        try state.recordActualStudyStart(minute: 600, now: date(3, 14), calendar: calendar)
        _ = state.replan(now: date(3, 14), calendar: calendar)
        try state.recordActualStudyStart(minute: 900, now: date(3, 14), calendar: calendar)
        let result = state.replan(now: date(3, 14), calendar: calendar)
        XCTAssertEqual(result.tasks.first?.start, date(3, 15))
        XCTAssertEqual(state.tasks, result.tasks)
        let saved = state
        for minute in [-1, 1440] {
            XCTAssertThrowsError(try state.recordActualStudyStart(minute: minute, now: date(), calendar: calendar))
            XCTAssertEqual(state, saved)
        }
    }

    func testHomepageStartImmediatelyInvalidatesExistingDuplicateLessonDrafts() throws {
        var state = fixture(minutes: 120, deadline: 3, endMinute: 22 * 60)
        state.courses[0].type = .lessonBasedRecorded
        state.courses[0].manualLessons = [
            .init(id: "english", name: "第一节", durationMinutes: 60),
            .init(id: "politics", name: "商品经济", durationMinutes: 60)
        ]
        let courseID = state.courses[0].id
        state.tasks = [15, 17, 19].map {
            ScheduledTask(courseID: courseID, start: date(3, $0), durationMinutes: 60, lessonID: "english")
        }
        try state.recordActualStudyStart(minute: 19 * 60 + 10, now: date(3, 19, 35), calendar: calendar)
        XCTAssertTrue(state.tasks.isEmpty, "首页确认新起点时，旧的未确认课表应立即失效")
        let result = state.replan(now: date(3, 19, 35), calendar: calendar)
        XCTAssertEqual(state.tasks, result.tasks)
        XCTAssertEqual(state.tasks.count, 2)
        XCTAssertEqual(total(state.tasks), 120)
        XCTAssertEqual(state.tasks.first?.start, date(3, 19, 10))
        let settingsEditorSnapshot = fixture().settings
        state.updateStudySettings(settingsEditorSnapshot, now: date(3, 20), calendar: calendar)
        XCTAssertEqual(state.settings.actualStudyStart, date(3, 19, 10))
    }

    func testDailyWindowChangeReplacesEndedLessonDraftsWithoutDuplicatingWork() throws {
        var state = fixture(minutes: 120, deadline: 3, endMinute: 22 * 60)
        state.courses[0].type = .lessonBasedRecorded
        state.courses[0].manualLessons = [
            .init(id: "english", name: "第一节", durationMinutes: 60),
            .init(id: "politics", name: "商品经济", durationMinutes: 60)
        ]
        _ = state.replan(now: date(3, 8), calendar: calendar)
        let oldIDs = Set(state.tasks.map(\.id))
        var settings = state.settings
        settings.availability = (1...7).map { .init(weekday: $0, startMinute: 19 * 60, endMinute: 22 * 60) }
        state.updateStudySettings(settings, now: date(3, 19), calendar: calendar)
        let result = state.replan(now: date(3, 19), calendar: calendar)
        XCTAssertTrue(oldIDs.isDisjoint(with: state.tasks.map(\.id)))
        XCTAssertEqual(state.tasks.count, 2)
        XCTAssertEqual(total(state.tasks), 120)
        XCTAssertEqual(Set(state.tasks.compactMap(\.lessonID)).count, 2)
        XCTAssertEqual(state.tasks, result.tasks)
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 0)
        state = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        _ = state.replan(now: date(3, 21), calendar: calendar)
        XCTAssertEqual(state.tasks, result.tasks)
    }

    func testWindowChangeKeepsConfirmedProgressAndPreviousDayHistory() throws {
        var state = fixture(minutes: 240, deadline: 3, endMinute: 22 * 60)
        let yesterday = ScheduledTask(courseID: state.courses[0].id, start: date(2, 8), durationMinutes: 60)
        let completed = ScheduledTask(courseID: state.courses[0].id, start: date(3, 8), durationMinutes: 60)
        state.tasks = [yesterday, completed]
        try state.confirm(taskID: completed.id, actualMinutes: 30, now: date(3, 9))
        let history = state.tasks
        let completions = state.completions
        let event = FixedEvent(title: "固定课", startMinute: 19 * 60, endMinute: 20 * 60, startDate: date(), endDate: date())
        state.fixedEvents = [event]
        var settings = state.settings
        settings.availability = (1...7).map { .init(weekday: $0, startMinute: 17 * 60, endMinute: 24 * 60) }
        state.updateStudySettings(settings, now: date(3, 17), calendar: calendar)
        let result = state.replan(now: date(3, 17), calendar: calendar)
        XCTAssertTrue(history.allSatisfy { state.tasks.contains($0) })
        XCTAssertEqual(state.completions, completions)
        XCTAssertEqual(state.fixedEvents, [event])
        XCTAssertEqual(total(result.tasks), 210)
        XCTAssertTrue(result.tasks.allSatisfy { $0.end <= date(3, 19) || $0.start >= date(3, 20) })
    }

    func testUnchangedWindowsDoNotResetHistoryAndStaleEditorKeepsLatestStart() throws {
        var state = fixture()
        var settings = state.settings
        // Fresh IDs or reordered rows do not change the actual weekly windows.
        settings.availability = state.settings.availability.reversed().map {
            .init(weekday: $0.weekday, startMinute: $0.startMinute, endMinute: $0.endMinute)
        }
        settings.notificationMinute = 22 * 60
        state.updateStudySettings(settings, now: date(3, 14), calendar: calendar)
        XCTAssertNil(state.settings.actualStudyStart)
        try state.recordActualStudyStart(minute: 630, now: date(3, 14), calendar: calendar)
        settings.availability[0].endMinute -= 60
        state.updateStudySettings(settings, now: date(3, 15), calendar: calendar)
        XCTAssertEqual(state.settings.actualStudyStart, date(3, 10, 30))
        XCTAssertEqual(state.settings.notificationMinute, 22 * 60)
    }

    func testOldSettingsDecodeAndOverrideSurvivesSync() throws {
        let old = Data(#"{"minimumScheduleUnit":60,"notificationMinute":1260,"availability":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: old).actualStudyStart)
        var state = fixture()
        try state.recordActualStudyStart(minute: 630, now: date(3, 14), calendar: calendar)
        var mac = SyncLedger(), phone = SyncLedger()
        try mac.capture(state)
        try phone.merge(mac.changes(after: 0))
        XCTAssertEqual(try phone.materialize().settings.actualStudyStart, date(3, 10, 30))
    }
}

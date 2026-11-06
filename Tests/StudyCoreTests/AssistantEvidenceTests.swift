import XCTest
@testable import StudyCore

final class AssistantEvidenceTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var day: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "机密课程名称", totalMinutes: 300, startDate: day,
                            deadline: day.addingTimeInterval(3 * 86400))
        course.notes = "秘密备注和账号"; course.initialCompletedMinutes = 60
        state.courses = [course]
        state.tasks = [.init(courseID: course.id, start: day.addingTimeInterval(3600), durationMinutes: 60)]
        var event = FixedEvent(title: "秘密事项", startMinute: 480, endMinute: 540, startDate: day, endDate: day)
        event.notes = "秘密网址 https://private.example/token"
        state.fixedEvents = [event]
        return state
    }
    func testAllowlistDoesNotMutateStateOrSendNamesNotesIDsAndSources() {
        let state = fixture(), before = state
        let evidence = AssistantEvidence.build(state: state, day: day, now: day, calendar: calendar)
        XCTAssertEqual(state, before)
        for secret in ["机密课程名称", "秘密备注", "秘密事项", "private.example", state.courses[0].id.uuidString] {
            XCTAssertFalse(evidence.text.contains(secret), secret)
        }
        XCTAssertEqual(evidence.courseAliases, ["课程1 = 机密课程名称"])
        XCTAssertTrue(evidence.text.contains("总量300分钟"))
        XCTAssertTrue(evidence.text.contains("有效完成60分钟"))
        XCTAssertTrue(evidence.text.contains("剩余240分钟"))
        XCTAssertTrue(evidence.text.contains("差额180分钟"))
    }
    func testExplicitNameConsentOnlyIncludesSelectedCourseName() {
        var state = fixture()
        state.courses.append(Course(name: "未选课程秘密", totalMinutes: 60, startDate: day, deadline: day))
        let evidence = AssistantEvidence.build(state: state, day: day, courseID: state.courses[0].id,
                                               includeNames: true, now: day, calendar: calendar)
        XCTAssertTrue(evidence.text.contains("机密课程名称"))
        XCTAssertFalse(evidence.text.contains("未选课程秘密"))
        XCTAssertFalse(evidence.text.contains("秘密备注"))
        XCTAssertFalse(evidence.text.contains("秘密事项"))
    }
    func testDeletedSelectionDoesNotFallBackToAllCourses() {
        let evidence = AssistantEvidence.build(state: fixture(), day: day, courseID: UUID(), now: day, calendar: calendar)
        XCTAssertTrue(evidence.text.contains("所选课程已删除或归档"))
        XCTAssertFalse(evidence.text.contains("总量300"))
    }
    func testUnknownOrMissingEvidenceReferencesAreFlagged() {
        let evidence = AssistantEvidence.build(state: fixture(), day: day, now: day, calendar: calendar)
        XCTAssertNil(evidence.citationWarning(in: "依据[E1]与[E2]。"))
        XCTAssertNotNil(evidence.citationWarning(in: "一定是这样。"))
        XCTAssertNotNil(evidence.citationWarning(in: "根据[E99999]。"))
        XCTAssertNotNil(evidence.citationWarning(in: "根据[E0]。"))
    }
    func testActualStudyDayAndEffectiveProgressAreNotConfused() {
        var state = fixture()
        state.completions = [.init(courseID: state.courses[0].id, taskID: UUID(), minutes: 30,
                                   recordedAt: day.addingTimeInterval(86400), studyDate: day)]
        let evidence = AssistantEvidence.build(state: state, day: day, now: day, calendar: calendar)
        XCTAssertTrue(evidence.text.contains("有效完成90分钟"))
        XCTAssertTrue(evidence.text.contains("1条确认，合计30分钟"))
        XCTAssertTrue(evidence.text.contains("不是每日上限"))
        XCTAssertTrue(evidence.text.contains("不是历史排课决策轨迹"))
    }
    func testCurrentDemandAndDailyWarningKeepTheirDistinctMeaning() {
        let state = fixture()
        let result = ScheduleResult(tasks: state.tasks, risks: [],
                                    demands: [state.courses[0].id: .init(remainingMinutes: 240, learnableDays: 2)], diagnostics: [],
                                    dayPlans: [.init(date: day, availableMinutes: 300, plannedMinutes: 180)])
        let evidence = AssistantEvidence.build(state: state, day: day, now: day, calendar: calendar,
                                               result: result, dailyWarningMinutes: 120)
        XCTAssertTrue(evidence.text.contains("超过负担提醒线60分钟"))
        XCTAssertTrue(evidence.text.contains("界面每日均摊120.0分钟"))
        XCTAssertTrue(evidence.text.contains("不是单门课的排程硬上限"))
    }
    func testLargeContextIsBoundedAndOmissionsAreExplicit() {
        var state = fixture()
        for i in 0..<100 { state.courses.append(Course(name: "课程\(i)", totalMinutes: 60, startDate: day, deadline: day)) }
        for _ in 0..<100 { state.tasks.append(state.tasks[0]) }
        let overview = AssistantEvidence.build(state: state, day: day, now: day, calendar: calendar)
        XCTAssertEqual(overview.courseAliases.count, 12)
        XCTAssertTrue(overview.text.contains("包含 12/101"))
        let selected = AssistantEvidence.build(state: state, day: day, courseID: state.courses[0].id, now: day, calendar: calendar)
        XCTAssertTrue(selected.text.contains("77条当日安排未列出"))
        XCTAssertLessThan(overview.text.utf8.count, 60000)
    }
}

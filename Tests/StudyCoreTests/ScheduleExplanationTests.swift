import XCTest
@testable import StudyCore

final class ScheduleExplanationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private var today: Date { calendar.date(from: .init(year: 2026, month: 9, day: 14))! }
    private func state() -> PlannerState {
        var state = PlannerState()
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1080) }
        state.courses = [600, 60, 60].enumerated().map { index, amount in
            Course(name: "模拟课程\(index)", totalMinutes: amount, startDate: today,
                   deadline: calendar.date(byAdding: .day, value: index == 0 ? 0 : 1, to: today)!)
        }
        return state
    }
    func testExplanationIdentifiesAnActualDeadlineFallbackWithoutClaimingItIsNecessary() {
        let state = state()
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: today)
        XCTAssertTrue(result.adjustments.contains(ScheduleExplanation.deadlineFallback))
        let lines = ScheduleExplanation.lines(state: state, result: result, calendar: calendar)
        XCTAssertTrue(lines[0].contains("整份课表"))
        XCTAssertTrue(lines[0].contains("不代表只有集中排课才能按期完成"))
        XCTAssertTrue(lines[1].contains("模拟课程0（9月14日）"))
        XCTAssertTrue(lines.contains { $0.contains("没有每日加量") })
        XCTAssertTrue(lines.last!.contains("没有限制同一门连续几节"))
        var adjusted = result
        adjusted.adjustments.append("已联合调整浮动事项在原窗口内的位置与课程分配，保持截止日期和整节课顺序。")
        XCTAssertTrue(ScheduleExplanation.lines(state: state, result: adjusted).contains { $0.contains("后续调整：已联合调整") })
    }
    func testNonFallbackAndSubTripleBoostUseSavedCourseSettingsWithoutMutation() {
        var state = state()
        for i in state.courses.indices { state.courses[i].totalMinutes = 60 }
        state.courses[1].dailyStudyWeight = 1.5
        var paused = state.courses[1]
        paused.id = UUID(); paused.name = "暂停三倍"; paused.dailyStudyWeight = 3; paused.autoScheduleEnabled = false
        state.courses.append(paused)
        let before = state
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: today)
        let lines = ScheduleExplanation.lines(state: state, result: result, calendar: calendar)
        XCTAssertTrue(lines[0].contains("没有触发"))
        XCTAssertTrue(lines.contains { $0.contains("模拟课程1 1.5 倍") && $0.contains("没有 3 倍课程") })
        XCTAssertFalse(lines.joined().contains("暂停三倍"))
        XCTAssertEqual(state, before)
    }
    func testTripleExceptionExplanationRespectsCustomRuleOrder() {
        var state = state()
        state.courses[0].dailyStudyWeight = 3
        var result = ScheduleEngine(calendar: calendar).generate(state: state, now: today)
        XCTAssertTrue(ScheduleExplanation.lines(state: state, result: result).joined().contains("默认规则允许"))
        state.settings.schedulePriorities = SchedulePriorities(levels: ["coursePriority": 1, "diversity": 4])
        result = ScheduleEngine(calendar: calendar).generate(state: state, now: today)
        XCTAssertTrue(ScheduleExplanation.lines(state: state, result: result).joined().contains("不启用默认的 3 倍集中例外"))
    }
    func testEmptyStateDoesNotInventSchedulingCauses() {
        let state = PlannerState()
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: today)
        XCTAssertEqual(ScheduleExplanation.lines(state: state, result: result), ["当前没有需要自动排课的剩余课程。"])
    }
}

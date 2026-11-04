import XCTest
@testable import StudyCore

final class DayAgendaTextTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 11, day: 4))! }
    private func at(_ minute: Int) -> Date { day.addingTimeInterval(Double(minute) * 60) }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "数学\n二", totalMinutes: 240, startDate: day, deadline: at(1440))
        course.notes = "private-course-note https://private.invalid"
        state.courses = [course]
        state.tasks = [.init(courseID: course.id, start: at(600), durationMinutes: 60, lessonName: "第一讲\t极限")]
        var event = FixedEvent(title: "实验", startMinute: 540, endMinute: 570, startDate: day, endDate: day)
        event.notes = "private-event-note"
        state.fixedEvents = [event]
        return state
    }
    private func text(_ state: PlannerState) -> String { DayAgendaText.make(day: day, state: state, calendar: calendar) }

    func testMixedAgendaIsChronologicalAndOmitsNotesWithoutChangingState() {
        let state = fixture(), before = state, result = text(state)
        XCTAssertTrue(result.hasPrefix("学习日程 · 2026-11-04 星期三\n时区：Asia/Shanghai"))
        XCTAssertTrue(result.contains("09:00–09:30 · 实验 · 固定事项\n• 10:00–11:00 · 数学 二 / 第一讲 极限 · 计划 60 分钟 · 未确认"))
        XCTAssertFalse(result.contains("private"))
        XCTAssertEqual(state, before)
    }
    func testArchivedAndMissingCoursesKeepOnlyRecordedHistory() {
        var state = fixture(); state.courses[0].isArchived = true
        let original = state.tasks[0]
        for status in [TaskStatus.completed, .partial, .missed] {
            var task = original; task.id = UUID(); task.status = status
            task.completedMinutes = status == .completed ? 60 : status == .partial ? 20 : 0
            task.confirmedAt = at(1200); state.tasks.append(task)
        }
        let archived = text(state)
        XCTAssertFalse(archived.contains("未确认"))
        XCTAssertTrue(archived.contains("已确认 60 分钟")); XCTAssertTrue(archived.contains("已确认 20 分钟"))
        XCTAssertTrue(archived.contains(" · 未完成"))
        XCTAssertTrue(archived.contains("完成记录按原计划日期列出，不代表当天实际学习总量。"))
        state.courses = []
        XCTAssertTrue(text(state).contains("已删除课程 / 第一讲 极限"))
        XCTAssertFalse(text(state).contains("未确认"))
    }
    func testFloatingWindowsAndSkippedRulesRemainDistinct() {
        var state = fixture()
        state.tasks[0].floatingWindowStart = at(600); state.tasks[0].floatingWindowEnd = at(780)
        state.fixedEvents[0].endMinute = 600; state.fixedEvents[0].floatingDurationMinutes = 30
        var skipped = state.fixedEvents[0]; skipped.id = UUID(); skipped.title = "已跳过"
        skipped.excludedDates = [at(100)]; state.fixedEvents.append(skipped)
        let result = text(state)
        XCTAssertTrue(result.contains("预估 10:00–11:00"))
        XCTAssertTrue(result.contains("完成窗口：10:00–13:00"))
        XCTAssertTrue(result.contains("09:00–10:00 · 实验 · 浮动窗口，需 30 分钟"))
        XCTAssertTrue(result.contains("本日已临时移除\n• 09:00–10:00 · 已跳过 · 浮动窗口，需 30 分钟 · 本日不占用时间"))
        XCTAssertEqual(result.components(separatedBy: "已跳过").count, 2)
    }
    func testDayFilteringAndMidnightUseLocalDates() {
        var state = fixture(); state.tasks[0].start = at(1410)
        var next = state.tasks[0]; next.id = UUID(); next.start = at(1440); next.lessonName = "明日课程"
        state.tasks.append(next)
        state.fixedEvents[0].endMinute = 1440
        let result = text(state)
        XCTAssertTrue(result.contains("23:30–2026-11-05 00:30"))
        XCTAssertTrue(result.contains("09:00–24:00"))
        XCTAssertFalse(result.contains("明日课程"))
        let tomorrow = DayAgendaText.make(day: at(1440), state: state, calendar: calendar)
        XCTAssertTrue(tomorrow.contains("明日课程")); XCTAssertFalse(tomorrow.contains("实验"))
        XCTAssertEqual(text(PlannerState()).components(separatedBy: "\n").last, "这一天没有待进行的安排")
    }
    func testDaylightSavingRepeatIncludesBothOffsets() {
        var cal = calendar; cal.timeZone = TimeZone(identifier: "America/New_York")!
        let start = ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z")!
        var state = fixture(); state.fixedEvents = []
        state.tasks[0].start = start
        let result = DayAgendaText.make(day: start, state: state, calendar: cal)
        XCTAssertTrue(result.contains("01:30 -04:00–01:30 -05:00"))
        XCTAssertTrue(result.contains("2026-11-01 星期日"))
    }
    func testEqualTimeOrderingIsStableAcrossInputOrderAndRecurringDays() {
        var state = fixture()
        var second = state.tasks[0]; second.id = UUID(); second.lessonName = "第二讲"
        state.tasks.append(second)
        var later = state.fixedEvents[0]; later.id = UUID(); later.title = "下次实验"
        later.weekdays = [5]; later.endDate = at(7 * 1440); state.fixedEvents.append(later)
        let expected = text(state)
        XCTAssertFalse(expected.contains("下次实验"))
        state.tasks.reverse(); state.fixedEvents.reverse()
        XCTAssertEqual(text(state), expected)
    }
}

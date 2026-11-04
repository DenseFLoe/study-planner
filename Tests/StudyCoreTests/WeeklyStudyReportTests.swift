import XCTest
@testable import StudyCore

final class WeeklyStudyReportTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    private var monday: Date { calendar.date(from: .init(year: 2026, month: 11, day: 2))! }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.courses = [Course(name: "化工\n 原理", totalMinutes: 120, startDate: monday, deadline: monday + 86400 * 14),
                         Course(name: "化工 原理", totalMinutes: 120, startDate: monday, deadline: monday + 86400 * 14)]
        state.courses[0].notes = "private-source-note"
        return state
    }
    func testAndroidReportFixturesMatchExactly() throws {
        struct Sample: Decodable { let state: PlannerState; let selectedDay: Date; let expected: String }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Android/build/tests/weekly-study-report-parity.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Run Android/test.sh to generate weekly report fixtures") }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
        XCTAssertEqual(samples.count, 4)
        for sample in samples {
            XCTAssertEqual(try WeeklyStudyReport.make(day: sample.selectedDay, state: sample.state, calendar: calendar).text, sample.expected)
        }
    }
    func testReportIsDetachedPrivateAndIndependentOfCourseStorageOrder() throws {
        var state = fixture()
        state.tasks = state.courses.map { ScheduledTask(courseID: $0.id, start: monday, durationMinutes: 60) }
        let original = state, report = try WeeklyStudyReport.make(day: monday + 6 * 86400, state: state, calendar: calendar)
        XCTAssertEqual(report.rangeLabel, "2026-11-02 至 2026-11-08")
        XCTAssertTrue(report.text.contains("化工 原理（同名 1/2）")); XCTAssertTrue(report.text.contains("化工 原理（同名 2/2）"))
        XCTAssertFalse(report.text.contains("private-source")); XCTAssertFalse(report.text.contains(state.courses[0].id.uuidString))
        XCTAssertEqual(state, original)
        state.courses.reverse()
        XCTAssertEqual(try WeeklyStudyReport.make(day: monday, state: state, calendar: calendar).text, report.text)
        state.courses[0].name = "Changed"; state.tasks[0].durationMinutes = 90
        XCTAssertTrue(report.text.contains("课表计划：120 分钟")); XCTAssertFalse(report.text.contains("Changed"))
    }
    func testOverflowAndNegativeMinutesFailWithoutChangingRecords() throws {
        var state = fixture()
        state.tasks = [ScheduledTask(courseID: state.courses[0].id, start: monday, durationMinutes: Int.max),
                       ScheduledTask(courseID: state.courses[1].id, start: monday + 86400, durationMinutes: 1)]
        let original = state
        XCTAssertThrowsError(try WeeklyStudyReport.make(day: monday, state: state, calendar: calendar))
        XCTAssertEqual(state, original)
        state.tasks.removeLast()
        XCTAssertTrue(try WeeklyStudyReport.make(day: monday, state: state, calendar: calendar).text.contains("课表计划：\(Int.max) 分钟"))
        state.tasks[0].durationMinutes = -1
        XCTAssertThrowsError(try WeeklyStudyReport.make(day: monday, state: state, calendar: calendar))
        state.tasks = []
        for dated in [false, true] {
            state.completions = [CompletionRecord(courseID: state.courses[0].id, taskID: UUID(), minutes: Int.max, recordedAt: monday, studyDate: dated ? monday : nil),
                                 CompletionRecord(courseID: state.courses[1].id, taskID: UUID(), minutes: 1, recordedAt: monday, studyDate: dated ? monday : nil)]
            let before = state
            XCTAssertThrowsError(try WeeklyStudyReport.make(day: monday, state: state, calendar: calendar))
            XCTAssertEqual(state, before)
        }
        state.completions = [CompletionRecord(courseID: state.courses[0].id, taskID: UUID(), minutes: -1, recordedAt: monday, studyDate: monday)]
        XCTAssertThrowsError(try WeeklyStudyReport.make(day: monday, state: state, calendar: calendar))
    }
    func testExplicitStudyDatesAndUncertainHistoryKeepDistinctMeanings() throws {
        var state = fixture()
        let task = ScheduledTask(courseID: state.courses[0].id, start: monday, durationMinutes: 60)
        let later = ScheduledTask(courseID: task.courseID, start: monday + 7200, durationMinutes: 60)
        state.tasks = [task, later]
        state.completions = [CompletionRecord(courseID: task.courseID, taskID: task.id, minutes: 20, recordedAt: monday + 3600),
                             CompletionRecord(courseID: later.courseID, taskID: later.id, minutes: 10, recordedAt: monday + 86400),
                             CompletionRecord(courseID: UUID(), taskID: UUID(), minutes: 30, recordedAt: monday + 5 * 86400, studyDate: monday + 2 * 86400)]
        state.courses[0].isArchived = true
        let text = try WeeklyStudyReport.make(day: monday, state: state, calendar: calendar).text
        XCTAssertTrue(text.contains("实际已学：50 分钟"))
        XCTAssertTrue(text.contains("2026-11-04 周三 · 已学 30 分钟 / 计划 0 分钟"))
        XCTAssertTrue(text.contains("• 已删除课程 · 已学 30 分钟"))
        XCTAssertTrue(text.contains("全部历史中另有 10 分钟无法确定学习日期"))
    }
    func testSevenLocalDaysCoverSpringAndAutumnClockChanges() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for components in [DateComponents(year: 2026, month: 3, day: 2), DateComponents(year: 2026, month: 10, day: 26)] {
            let start = try XCTUnwrap(calendar.date(from: components))
            let sunday = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: start))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: start))
            let late = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: sunday))
            var state = PlannerState(); let course = Course(name: "DST", totalMinutes: 120, startDate: start, deadline: end); state.courses = [course]
            state.tasks = [ScheduledTask(courseID: course.id, start: late, durationMinutes: 30), ScheduledTask(courseID: course.id, start: end, durationMinutes: 60)]
            state.completions = [CompletionRecord(courseID: course.id, taskID: state.tasks[0].id, minutes: 20, recordedAt: end, studyDate: late)]
            let text = try WeeklyStudyReport.make(day: sunday, state: state, calendar: calendar).text
            XCTAssertTrue(text.contains("课表计划：30 分钟")); XCTAssertTrue(text.contains("实际已学：20 分钟"))
            XCTAssertTrue(text.contains("周日 · 已学 20 分钟 / 计划 30 分钟")); XCTAssertTrue(text.contains("时区：America/Los_Angeles"))
        }
    }
}

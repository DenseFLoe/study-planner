import XCTest
@testable import StudyCore

final class WeeklyActualStudySeriesTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    private var monday: Date { calendar.date(from: .init(year: 2026, month: 11, day: 2))! }
    private func summary(_ state: PlannerState) -> WeeklyActualStudySeries.Summary {
        WeeklyActualStudySeries.summary(state: state, weekStart: monday, calendar: calendar)
    }
    private func record(_ course: UUID, minutes: Int, day: Date?) -> CompletionRecord {
        CompletionRecord(courseID: course, taskID: UUID(), minutes: minutes, recordedAt: monday + 6 * 86400, studyDate: day)
    }

    func testAndroidWeeklyReportFixturesAgreeWithChartDailyTotals() throws {
        struct Sample: Decodable { let state: PlannerState; let selectedDay: Date; let expected: String }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Android/build/tests/weekly-study-report-parity.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Run Android/test.sh to generate weekly report fixtures") }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
        XCTAssertEqual(samples.count, 4)
        for sample in samples {
            let offset = (calendar.component(.weekday, from: sample.selectedDay) + 5) % 7
            let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: sample.selectedDay))
            let actual = WeeklyActualStudySeries.summary(state: sample.state, weekStart: start, calendar: calendar)
            XCTAssertTrue(sample.expected.contains("实际已学：\(try XCTUnwrap(actual.chart.totalMinutes)) 分钟"))
            let dailyLines = sample.expected.split(separator: "\n").filter { $0.contains(" · 已学") && !$0.hasPrefix("•") }
            XCTAssertEqual(dailyLines.count, 7)
            for day in 0..<7 {
                let total = actual.chart.segments.filter { $0.dayIndex == day }.reduce(0) { $0 + $1.minutes }
                XCTAssertTrue(dailyLines[day].contains("· 已学 \(total) 分钟 /"))
            }
            let undated = try XCTUnwrap(actual.undatedMinutes)
            if undated > 0 { XCTAssertTrue(sample.expected.contains("全部历史中另有 \(undated) 分钟")) }
            else { XCTAssertFalse(sample.expected.contains("无法确定学习日期")) }
        }
    }

    func testBackfillAndLegacyAttributionPreserveArchivedAndMissingCourses() {
        var state = PlannerState()
        var course = Course(name: "Archived", totalMinutes: 600, startDate: monday, deadline: monday + 10 * 86400)
        course.isArchived = true; state.courses = [course]
        let sameDay = ScheduledTask(courseID: course.id, start: monday, durationMinutes: 60)
        let ambiguous = ScheduledTask(courseID: course.id, start: monday, durationMinutes: 60)
        state.tasks = [sameDay, ambiguous]
        let missing = UUID()
        state.completions = [CompletionRecord(courseID: course.id, taskID: sameDay.id, minutes: 20, recordedAt: monday + 3600),
                             CompletionRecord(courseID: course.id, taskID: ambiguous.id, minutes: 10, recordedAt: monday + 86400),
                             record(course.id, minutes: 30, day: monday + 2 * 86400), record(missing, minutes: 40, day: monday + 3 * 86400),
                             record(course.id, minutes: 50, day: monday - 86400), record(course.id, minutes: 60, day: monday + 7 * 86400)]
        let before = state, value = summary(state)
        XCTAssertEqual(value.chart.totalMinutes, 90); XCTAssertEqual(value.undatedMinutes, 10)
        XCTAssertEqual(value.chart.segments.map(\.dayIndex), [0, 2, 3])
        XCTAssertEqual(value.chart.segments.map(\.minutes), [20, 30, 40])
        XCTAssertEqual(value.chart.segments.last?.courseName, "已删除课程")
        XCTAssertEqual(value.chart.segments.last?.courseID, missing)
        XCTAssertEqual(state, before)
    }

    func testOverflowAndInvalidValuesNeverTurnIntoPartialGraphs() {
        var state = PlannerState(); let first = UUID(), second = UUID()
        state.completions = [record(first, minutes: Int.max, day: monday)]
        XCTAssertEqual(summary(state).chart.totalMinutes, Int.max)
        for day in [monday, monday + 86400] {
            for course in [first, second] {
                state.completions = [record(first, minutes: Int.max, day: monday), record(course, minutes: 1, day: day), record(first, minutes: 5, day: nil)]
                let before = state, value = summary(state)
                XCTAssertNil(value.chart.totalMinutes); XCTAssertTrue(value.chart.segments.isEmpty)
                XCTAssertEqual(value.undatedMinutes, 5); XCTAssertEqual(state, before)
            }
        }
        state.completions = [record(first, minutes: 20, day: monday), record(first, minutes: Int.max, day: nil), record(second, minutes: 1, day: nil)]
        XCTAssertEqual(summary(state).chart.totalMinutes, 20); XCTAssertNil(summary(state).undatedMinutes)
        state.completions = [record(first, minutes: -1, day: monday)]
        XCTAssertNil(summary(state).chart.totalMinutes)
        state.completions = [record(first, minutes: -1, day: nil)]
        XCTAssertEqual(summary(state).chart.totalMinutes, 0); XCTAssertNil(summary(state).undatedMinutes)
    }

    func testPendingMissedAndSameNamedCoursesKeepSeparateMeaningAndIdentity() {
        var state = PlannerState()
        let first = Course(name: "同名", totalMinutes: 120, startDate: monday, deadline: monday + 86400)
        let second = Course(name: "同名", totalMinutes: 120, startDate: monday, deadline: monday + 86400)
        state.courses = [first, second]
        state.tasks = [ScheduledTask(courseID: first.id, start: monday, durationMinutes: 60)]
        state.completions = [record(first.id, minutes: 0, day: monday)]
        XCTAssertEqual(summary(state).chart.totalMinutes, 0); XCTAssertTrue(summary(state).chart.segments.isEmpty)
        state.completions += [record(first.id, minutes: 20, day: monday), record(second.id, minutes: 30, day: monday)]
        let value = summary(state)
        XCTAssertEqual(value.chart.totalMinutes, 50)
        XCTAssertEqual(Set(WeeklyChartSeries.ids(in: value.chart.segments)), [first.id, second.id])
        state.courses.reverse(); state.completions.reverse()
        XCTAssertEqual(summary(state).chart.segments, value.chart.segments)
        state.courses[0].name = "Renamed"
        XCTAssertEqual(Set(summary(state).chart.segments.map(\.id)), Set(value.chart.segments.map(\.id)))
        XCTAssertTrue(value.chart.segments.allSatisfy { $0.courseName == "同名" })
    }

    func testStudyDaysCoverDaylightSavingTransitionsWithoutFixedLengthWeeks() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for components in [DateComponents(year: 2026, month: 3, day: 2), DateComponents(year: 2026, month: 10, day: 26)] {
            let start = try XCTUnwrap(calendar.date(from: components)), course = UUID()
            let sunday = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: start))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: start))
            let late = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: sunday))
            var state = PlannerState(); state.completions = [record(course, minutes: 30, day: late), record(course, minutes: 60, day: end)]
            let value = WeeklyActualStudySeries.summary(state: state, weekStart: start, calendar: calendar)
            XCTAssertEqual(value.chart.totalMinutes, 30); XCTAssertEqual(value.chart.segments.map(\.dayIndex), [6])
        }
    }
}

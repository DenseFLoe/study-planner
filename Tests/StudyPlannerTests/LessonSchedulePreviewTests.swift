import AppKit
import SwiftUI
import XCTest
@testable import StudyCore
@testable import StudyPlanner

final class LessonSchedulePreviewTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int = 5, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func fixture(deadline: Int = 6, endMinute: Int = 540) -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "预览验证课程", totalMinutes: 90, startDate: date(), deadline: date(deadline))
        course.type = .lessonBasedRecorded
        course.manualLessons = [.init(id: "lesson", name: "第一节：90 分钟合成课节", durationMinutes: 90)]
        state.courses = [course]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: endMinute) }
        return state
    }
    private func summary(_ state: PlannerState, result: ScheduleResult? = nil) -> LessonSchedulePreviewSummary {
        let course = state.courses[0]
        return .init(lessons: state.lessonWorkItems(for: course), course: course,
                     result: result ?? ScheduleEngine(calendar: calendar).generate(state: state, now: date(5, 8)))
    }
    private func immediate(_ state: inout PlannerState) throws {
        _ = try state.studyImmediately(courseID: state.courses[0].id, lessonID: "lesson",
                                       now: date(5, 8), calendar: calendar)
    }

    func testWholeLessonIsFullyScheduled() throws {
        let value = summary(fixture(endMinute: 660))
        let row = try XCTUnwrap(value.entries["lesson"])
        XCTAssertEqual(row.status, .fullyScheduled)
        XCTAssertEqual(row.scheduledMinutes, 90)
        XCTAssertEqual(row.missingMinutes, 0)
        XCTAssertEqual(row.segmentCount, 1)
        XCTAssertEqual(row.firstStart, date(5, 8))
        XCTAssertEqual(row.lastEnd, date(5, 9, 30))
        XCTAssertEqual(value.fullyScheduledCount, 1)
        XCTAssertEqual(value.partiallyScheduledCount, 0)
        XCTAssertEqual(value.unscheduledCount, 0)
        XCTAssertNil(value.warning)
    }

    func testSameDaySegmentsAreAggregated() throws {
        var state = fixture()
        state.settings.availability += (1...7).map { .init(weekday: $0, startMinute: 600, endMinute: 660) }
        try immediate(&state)
        let value = summary(state)
        let row = try XCTUnwrap(value.entries["lesson"])
        XCTAssertEqual(row.status, .fullyScheduled)
        XCTAssertEqual(row.segmentCount, 2)
        XCTAssertEqual(row.scheduledMinutes, 90)
        XCTAssertEqual(row.firstStart, date(5, 8))
        XCTAssertEqual(row.lastEnd, date(5, 10, 30))
        XCTAssertEqual(value.fullyScheduledCount, 1)
        XCTAssertNil(value.warning)
    }

    func testCrossDaySegmentsShowFirstStartAndLastEndRegardlessOfTaskOrder() throws {
        var state = fixture()
        try immediate(&state)
        let original = state
        var result = ScheduleEngine(calendar: calendar).generate(state: state, now: date(5, 8))
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [60, 30])
        for tasks in [result.tasks, result.tasks.reversed()] {
            result.tasks = Array(tasks)
            let value = summary(state, result: result)
            let row = try XCTUnwrap(value.entries["lesson"])
            XCTAssertEqual(row.firstStart, date(5, 8))
            XCTAssertEqual(row.lastEnd, date(6, 8, 30))
            XCTAssertEqual(row.segmentCount, 2)
            XCTAssertEqual(row.scheduledMinutes, 90)
            XCTAssertEqual(row.status, .fullyScheduled)
            let timing = try XCTUnwrap(row.timingText(calendar: calendar, locale: Locale(identifier: "zh_CN")))
            XCTAssertTrue(timing.hasPrefix("2 段 · 2026年11月5日"))
            XCTAssertTrue(timing.contains("至 2026年11月6日"))
            XCTAssertNil(value.warning)
        }
        XCTAssertEqual(state, original, "A preview must not write the plan or progress")
    }

    func testOnlyFirstSegmentIsPartialAndAlwaysWarnsAboutMissingMinutes() throws {
        var state = fixture(deadline: 5)
        try immediate(&state)
        let original = state
        var result = ScheduleEngine(calendar: calendar).generate(state: state, now: date(5, 8))
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [60])
        XCTAssertEqual(result.risks.count, 1)
        // Coverage must still warn even if no diagnostic is supplied.
        for _ in 0..<2 {
            let value = summary(state, result: result)
            let row = try XCTUnwrap(value.entries["lesson"])
            XCTAssertEqual(row.status, .partiallyScheduled)
            XCTAssertEqual(row.scheduledMinutes, 60)
            XCTAssertEqual(row.missingMinutes, 30)
            XCTAssertEqual(row.coverageText, "已排入 60 / 90 分钟 · 尚缺 30 分钟")
            XCTAssertEqual(value.countText, "完整排入 0 节 · 部分排入 1 节 · 未排入 0 节")
            XCTAssertNotNil(value.warning)
            result.risks = []
            result.conflicts = []
        }
        XCTAssertEqual(state, original)
    }

    func testNoSegmentsAreUnscheduled() throws {
        var state = fixture()
        state.settings.availability = []
        let value = summary(state)
        let row = try XCTUnwrap(value.entries["lesson"])
        XCTAssertEqual(row.status, .unscheduled)
        XCTAssertEqual(row.missingMinutes, 90)
        XCTAssertEqual(row.coverageText, "未排入 · 尚缺 90 分钟")
        XCTAssertEqual(row.segmentCount, 0)
        XCTAssertNil(row.firstStart)
        XCTAssertNil(row.lastEnd)
        XCTAssertNil(row.timingText())
        XCTAssertEqual(value.unscheduledCount, 1)
        XCTAssertEqual(value.partiallyScheduledCount, 0)
        XCTAssertEqual(value.fullyScheduledCount, 0)
        XCTAssertNotNil(value.warning)
    }

    func testCompletedLessonIsExcludedFromPendingCounts() throws {
        var state = fixture()
        state.courses[0].initialCompletedMinutes = 90
        let value = summary(state)
        let row = try XCTUnwrap(value.entries["lesson"])
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.scheduledMinutes, 0)
        XCTAssertEqual(row.missingMinutes, 0)
        XCTAssertEqual(value.pendingCount, 0)
        XCTAssertEqual(value.fullyScheduledCount, 0)
        XCTAssertEqual(value.unscheduledCount, 0)
        XCTAssertEqual(value.countText, "没有待排课节")
        XCTAssertNil(value.warning)
    }

    func testPartiallyCompletedLessonOnlyRequiresRemainingMinutes() throws {
        var state = fixture()
        state.courses[0].initialCompletedMinutes = 30
        let row = try XCTUnwrap(summary(state).entries["lesson"])
        XCTAssertEqual(row.status, .fullyScheduled)
        XCTAssertEqual(row.remainingMinutes, 60)
        XCTAssertEqual(row.scheduledMinutes, 60)
        XCTAssertEqual(row.coverageText, "已排齐 60 / 60 分钟")
    }

    func testOtherCoursesAndConfirmedHistoryCannotFillTheMissingRemainder() throws {
        var state = fixture(deadline: 5)
        try immediate(&state)
        var result = ScheduleEngine(calendar: calendar).generate(state: state, now: date(5, 8))
        let task = try XCTUnwrap(result.tasks.first)
        var otherCourse = task
        otherCourse.courseID = UUID()
        var confirmed = task
        confirmed.confirmedAt = date(4, 8)
        confirmed.start = date(4, 8)
        var completed = task
        completed.status = .completed
        var empty = task
        empty.durationMinutes = 0
        result.tasks += [otherCourse, confirmed, completed, empty]
        let row = try XCTUnwrap(summary(state, result: result).entries["lesson"])
        XCTAssertEqual(row.status, .partiallyScheduled)
        XCTAssertEqual(row.scheduledMinutes, 60)
        XCTAssertEqual(row.segmentCount, 1)
        XCTAssertEqual(row.firstStart, date(5, 8))
        XCTAssertEqual(row.lastEnd, date(5, 9))
    }

    func testMixedLessonsKeepCompletePartialMissingAndFinishedCountsSeparate() throws {
        var state = fixture()
        state.courses[0].manualLessons = [20, 90, 45, 30].enumerated().map {
            .init(id: "\($0.offset)", name: "第\($0.offset + 1)节", durationMinutes: $0.element)
        }
        state.courses[0].totalMinutes = 185
        state.courses[0].initialCompletedMinutes = 20
        let course = state.courses[0]
        let result = ScheduleResult(tasks: [
            .init(courseID: course.id, start: date(5, 8), durationMinutes: 60, lessonID: "1"),
            .init(courseID: course.id, start: date(6, 8), durationMinutes: 30, lessonID: "1"),
            .init(courseID: course.id, start: date(6, 9), durationMinutes: 20, lessonID: "2")
        ], risks: [], demands: [:], diagnostics: [])
        let value = summary(state, result: result)
        XCTAssertEqual(value.pendingCount, 3)
        XCTAssertEqual(value.fullyScheduledCount, 1)
        XCTAssertEqual(value.partiallyScheduledCount, 1)
        XCTAssertEqual(value.unscheduledCount, 1)
        XCTAssertEqual(value.entries["0"]?.status, .completed)
        XCTAssertEqual(value.entries["2"]?.missingMinutes, 25)
        XCTAssertNotNil(value.warning)
    }

    func testArchivedAndPausedCoursesExplainWhyLessonsAreMissing() {
        var state = fixture()
        state.courses[0].isArchived = true
        XCTAssertEqual(summary(state).warning, "此课程已归档，当前不会自动排程。")
        state.courses[0].isArchived = false
        state.courses[0].autoScheduleEnabled = false
        XCTAssertEqual(summary(state).warning, "此课程已暂停自动排程。")
    }

    func testEngineRiskRemainsVisibleEvenWhenRowsAppearCovered() {
        let state = fixture(endMinute: 660)
        var result = ScheduleEngine(calendar: calendar).generate(state: state, now: date(5, 8))
        result.risks = [.init(deadline: date(6), requiredMinutes: 120, availableMinutes: 90,
                              unscheduledMinutes: 30, courseNames: [state.courses[0].name])]
        let value = summary(state, result: result)
        XCTAssertEqual(value.fullyScheduledCount, 1)
        XCTAssertNotNil(value.warning)
    }

    /// Optional visual evidence, using only in-memory synthetic states. Never
    /// creates a PlannerStore or opens the user's database or installed app.
    @MainActor func testRenderSyntheticPreviewsWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["LESSON_PREVIEW_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LESSON_PREVIEW_SNAPSHOT_DIR to render synthetic preview images")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var split = fixture()
        try immediate(&split)
        var partial = fixture(deadline: 5)
        try immediate(&partial)
        var missing = fixture()
        missing.settings.availability = []
        var completed = fixture()
        completed.courses[0].initialCompletedMinutes = 90
        var longTitle = split
        longTitle.courses[0].manualLessons?[0].name = "第一节：复合函数的求导与微分应用——较长课节名称换行验证，使用合成数据"
        for (name, state, dark) in [("cross-day", split, false), ("partial", partial, false),
                                     ("missing", missing, false), ("completed", completed, false),
                                     ("long-title", longTitle, false), ("partial-dark", partial, true)] {
            let content = LessonSchedulePreviewContent(items: state.lessonWorkItems(for: state.courses[0]),
                                                        course: state.courses[0], summary: summary(state))
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.calendar, calendar)
                .environment(\.timeZone, calendar.timeZone)
                .environment(\.colorScheme, dark ? .dark : .light)
                .padding(16)
                .frame(width: 362)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1000)
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}

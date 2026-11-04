import XCTest
@testable import StudyCore

final class CompletionDayIndexTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 11, day: 4))! }
    func testIndexedLookupPreservesKnownLegacyAndAmbiguousAttribution() {
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        var state = PlannerState()
        let same = ScheduledTask(courseID: UUID(), start: day + 3600, durationMinutes: 60)
        let overnight = ScheduledTask(courseID: same.courseID, start: day - 1800, durationMinutes: 60)
        state.tasks = [same, overnight]
        let records: [CompletionRecord] = [
            .init(courseID: same.courseID, taskID: same.id, minutes: 30, recordedAt: day + 7200),
            .init(courseID: same.courseID, taskID: overnight.id, minutes: 30, recordedAt: day + 1800),
            .init(courseID: same.courseID, taskID: UUID(), minutes: 30, recordedAt: day + 7200),
            .init(courseID: same.courseID, taskID: overnight.id, minutes: 30, recordedAt: day + 1800, studyDate: day - 86400)
        ]
        let indexed = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0) })
        for record in records {
            let old = analyzer.effectiveDay(record, state: state), new = analyzer.effectiveDay(record, task: indexed[record.taskID])
            XCTAssertEqual(new?.date, old?.date); XCTAssertEqual(new?.legacy, old?.legacy)
        }
        XCTAssertEqual(analyzer.effectiveDay(records[0], task: same)?.date, day)
        XCTAssertNil(analyzer.effectiveDay(records[1], task: overnight))
        XCTAssertNil(analyzer.effectiveDay(records[2], task: nil))
    }
    func testMismatchedTaskCannotInventALegacyDayButExplicitDatesRemainAuthoritative() {
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        let task = ScheduledTask(courseID: UUID(), start: day, durationMinutes: 30)
        var record = CompletionRecord(courseID: task.courseID, taskID: UUID(), minutes: 30, recordedAt: day)
        XCTAssertNil(analyzer.effectiveDay(record, task: task))
        record.studyDate = day - 86400
        XCTAssertEqual(analyzer.effectiveDay(record, task: task)?.date, day - 86400)
        XCTAssertEqual(analyzer.effectiveDay(record, task: nil)?.legacy, false)
    }
    func testLargeHistoryCountsOnlyCertainStudyDaysWithoutMutation() throws {
        var state = PlannerState(); let course = UUID()
        for index in 0..<10000 {
            let task = ScheduledTask(courseID: course, start: day + 3600, durationMinutes: 1)
            state.tasks.append(task)
            state.completions.append(.init(courseID: course, taskID: task.id, minutes: 1,
                recordedAt: index % 2 == 0 ? day + 7200 : day + 86400))
        }
        state.completions.append(.init(courseID: course, taskID: UUID(), minutes: 7, recordedAt: day + 86400, studyDate: day))
        state.tasks.reverse(); let before = state
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        XCTAssertEqual(try analyzer.confirmed(on: day, state: state), 5007)
        XCTAssertEqual(try analyzer.confirmed(on: day + 86400, state: state), 0)
        XCTAssertEqual(state, before)
    }
    func testDuplicateTaskFallbackMatchesTheExistingFirstRecordPolicy() throws {
        var state = PlannerState()
        let first = ScheduledTask(courseID: UUID(), start: day, durationMinutes: 60)
        var duplicate = first; duplicate.start = day - 86400
        state.tasks = [first, duplicate]
        state.completions = [.init(courseID: first.courseID, taskID: first.id, minutes: 20, recordedAt: day + 3600)]
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        XCTAssertEqual(try analyzer.confirmed(on: day, state: state), 20)
        state.tasks.reverse()
        XCTAssertEqual(try analyzer.confirmed(on: day, state: state), 0)
    }
}

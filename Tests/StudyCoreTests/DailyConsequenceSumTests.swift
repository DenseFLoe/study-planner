import XCTest
@testable import StudyCore

final class DailyConsequenceSumTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 11, day: 3))! }
    private var now: Date { day.addingTimeInterval(8 * 3600) }
    private var analyzer: DailyConsequenceAnalyzer { .init(calendar: calendar) }
    private var emptyPlan: ScheduleResult { .init(tasks: [], risks: [], demands: [:], diagnostics: []) }
    private func entry() throws -> DailyConsequenceDay {
        try analyzer.capture(state: PlannerState(), result: emptyPlan, now: now, warningMinutes: 480)
    }
    private func progress(_ values: [Int], offsets: [Int]? = nil) -> PlannerState {
        var state = PlannerState()
        for (index, value) in values.enumerated() {
            let course = Course(name: "Synthetic daily sum", totalMinutes: 120, startDate: day, deadline: day)
            state.courses.append(course)
            let actual = calendar.date(byAdding: .day, value: offsets?[index] ?? 0, to: day)!
            state.completions.append(.init(courseID: course.id, taskID: UUID(), minutes: value, recordedAt: now, studyDate: actual))
        }
        return state
    }
    private func assertOverflow<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(String(describing: $0), "unrepresentableMinutes", file: file, line: line)
        }
    }

    func testAcceptedSameDayCourseTotalsFailExplicitlyWithoutMutation() throws {
        let state = progress([Int.max, 1])
        var ledger = SyncLedger()
        try ledger.capture(state)
        _ = try CloudArchive(ledger: ledger).validated()
        let restored = try ledger.materialize(), before = restored
        assertOverflow { try analyzer.confirmed(on: day, state: restored) }
        assertOverflow { try analyzer.capture(state: restored, result: emptyPlan, now: now, warningMinutes: 480) }
        XCTAssertEqual(restored, before)
    }

    func testSeparateDaysAndExactlyRepresentableTotalsAreNotCapped() throws {
        let separate = progress([Int.max, 1], offsets: [0,1]), before = separate
        XCTAssertEqual(try analyzer.confirmed(on: day, state: separate), Int.max)
        XCTAssertEqual(try analyzer.confirmed(on: calendar.date(byAdding: .day, value: 1, to: day)!, state: separate), 1)
        XCTAssertEqual(separate, before)
        XCTAssertEqual(try analyzer.confirmed(on: day, state: progress([Int.max - 1, 1])), Int.max)
        let entry = try analyzer.capture(state: progress([Int.max]), result: emptyPlan, now: now, warningMinutes: 480)
        XCTAssertEqual(entry.goalMinutes, Int.max)
        XCTAssertEqual(entry.confirmedAtCapture, Int.max)
    }

    func testCaptureRejectsCreditPlusPendingOverflowBeforeProducingEntry() throws {
        let state = progress([Int.max]), before = state
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 1)
        var plan = emptyPlan; plan.tasks = [task]
        assertOverflow { try analyzer.capture(state: state, result: plan, now: now, warningMinutes: 480) }
        XCTAssertEqual(state, before)
        XCTAssertEqual(plan.tasks, [task])
    }

    func testCaptureRejectsUnrepresentablePlannedSum() throws {
        let state = progress([0]), before = state
        var plan = emptyPlan
        plan.tasks = [Int.max, 1].map { ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: $0) }
        let tasks = plan.tasks
        assertOverflow { try analyzer.capture(state: state, result: plan, now: now, warningMinutes: 480) }
        XCTAssertEqual(state, before)
        XCTAssertEqual(plan.tasks, tasks)
    }

    func testCapturedEvidenceRejectsOverflowingExtraCredit() throws {
        var state = progress([Int.max]), captured = try entry()
        state.completions.append(.init(courseID: state.courses[0].id, taskID: UUID(), minutes: 1, recordedAt: now, studyDate: day))
        captured.baseline.courses = state.courses
        let before = state, oldEntry = captured
        assertOverflow { try analyzer.capturedEvidenceIsValid(captured, state: state) }
        XCTAssertEqual(state, before)
        XCTAssertEqual(captured, oldEntry)
    }

    func testRealityRejectsOverflowingPlannedTargets() throws {
        var captured = try entry()
        let owner = UUID()
        captured.plannedToday = [Int.max, 1].map { ScheduledTask(courseID: owner, start: now, durationMinutes: $0) }
        let before = captured
        assertOverflow { try analyzer.reality(captured, state: PlannerState()) }
        XCTAssertEqual(captured, before)
    }

    func testRealityRejectsOverflowingReviewedDurations() throws {
        var state = progress([0])
        state.completions = []
        for duration in [Int.max, 1] {
            let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: duration)
            state.tasks.append(task)
            state.completions.append(.init(courseID: task.courseID, taskID: task.id, minutes: 0, recordedAt: now, studyDate: day))
        }
        let captured = try entry(), before = state
        assertOverflow { try analyzer.reality(captured, state: state) }
        XCTAssertEqual(state, before)
    }

    func testRealityRejectsOverflowingProjectionLessonTotals() throws {
        let state = progress([1]), before = state
        var captured = try entry(), course = state.courses[0]
        course.manualLessons = [.init(id: "one", name: "One", durationMinutes: Int.max),
                                .init(id: "two", name: "Two", durationMinutes: 1),
                                .init(id: "three", name: "Three", durationMinutes: 1)]
        captured.baseline.courses = [course]
        let oldEntry = captured
        assertOverflow { try analyzer.reality(captured, state: state) }
        XCTAssertEqual(state, before)
        XCTAssertEqual(captured, oldEntry)
    }

    func testForecastRejectsUnrepresentableRequestedDifference() throws {
        var captured = try entry()
        captured.goalMinutes = Int.max
        captured.confirmedAtCapture = Int.min
        let before = captured
        assertOverflow { try analyzer.forecast(captured, fraction: 1000, horizon: 1) }
        XCTAssertEqual(captured, before)
    }

    func testForecastRetainsRepresentableOutOfRangeFractionTargets() throws {
        var captured = try entry()
        captured.goalMinutes = 120
        captured.confirmedAtCapture = 1000
        XCTAssertEqual(try analyzer.forecast(captured, fraction: -250, horizon: 1)?.todayMinutes, -30)
        XCTAssertEqual(try analyzer.forecast(captured, fraction: 2000, horizon: 1)?.todayMinutes, 240)
        assertOverflow { try analyzer.forecast(captured, fraction: Int.max, horizon: 1) }
    }

    func testLegacyAndAmbiguousDatesKeepTheirExistingInclusionRules() throws {
        var state = progress([7,11,13])
        state.completions[0].studyDate = nil
        state.completions[1].studyDate = nil
        state.completions[2].studyDate = nil
        var matching = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 30)
        matching.id = state.completions[0].taskID
        var different = ScheduledTask(courseID: state.courses[1].id, start: day.addingTimeInterval(-86400), durationMinutes: 30)
        different.id = state.completions[1].taskID
        state.tasks = [matching,different]
        let before = state
        XCTAssertEqual(try analyzer.confirmed(on: day, state: state), 7)
        XCTAssertEqual(try analyzer.confirmed(on: day.addingTimeInterval(-86400), state: state), 0)
        XCTAssertEqual(state, before)
    }

    func testSeededAndroidDailySumsRemainIndependentAcrossDates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Android/build/tests/daily-consequence-sums.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run ./Android/test.sh to generate daily sum controls") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let rows = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 256)
        for row in rows {
            let values = try XCTUnwrap(row["values"] as? [Int]), offsets = try XCTUnwrap(row["days"] as? [Int])
            XCTAssertEqual(values.count, offsets.count)
            let state = progress(values, offsets: offsets), before = state
            XCTAssertEqual(try analyzer.confirmed(on: day, state: state), row["day0"] as? Int)
            XCTAssertEqual(try analyzer.confirmed(on: day.addingTimeInterval(86400), state: state), row["day1"] as? Int)
            XCTAssertEqual(state, before)
        }
    }
}

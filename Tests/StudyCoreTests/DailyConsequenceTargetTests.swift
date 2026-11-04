import XCTest
@testable import StudyCore

final class DailyConsequenceTargetTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 11, day: 3, hour: 8))! }
    private func entry(goal: Int) throws -> DailyConsequenceDay {
        let state = PlannerState()
        let plan = ScheduleEngine(calendar: calendar).generate(state: state, now: now)
        var value = try DailyConsequenceAnalyzer(calendar: calendar).capture(state: state, result: plan, now: now, warningMinutes: 480)
        value.goalMinutes = goal
        return value
    }

    func testMaximumGoalTargetsMatchExactLiteralExpectations() throws {
        let value = try entry(goal: Int.max)
        let fractions = [0,1,250,500,750,999,1000]
        let expected = [0,9_223_372_036_854_775,2_305_843_009_213_693_951,4_611_686_018_427_387_903,
                        6_917_529_027_641_081_855,9_214_148_664_817_921_031,Int.max]
        XCTAssertEqual(fractions.map { value.target(for: $0) }, expected)
        let neighbor = try entry(goal: Int.max - 1)
        XCTAssertEqual(neighbor.target(for: 750), 6_917_529_027_641_081_854)
        XCTAssertEqual(neighbor.target(for: 999), 9_214_148_664_817_921_030)
        XCTAssertEqual(neighbor.target(for: 1000), Int.max - 1)
    }

    func testSignedGoalsKeepIntegerTruncationWithoutIntermediateOverflow() throws {
        let value = try entry(goal: Int.min)
        XCTAssertEqual([0,1,250,500,750,999,1000].map { value.target(for: $0) },
                       [0,-9_223_372_036_854_775,-2_305_843_009_213_693_952,-4_611_686_018_427_387_904,
                        -6_917_529_027_641_081_856,-9_214_148_664_817_921_032,Int.min])
        for (goal, targets) in [(1001,[250,500,750,999,1001]),(-1001,[-250,-500,-750,-999,-1001])] {
            let uneven = try entry(goal: goal)
            XCTAssertEqual([250,500,750,999,1000].map { uneven.target(for: $0) }, targets)
        }
    }

    func testPreviouslyRepresentableOutOfRangeFractionsAreNotClamped() throws {
        for (goal, fraction, expected) in [
            (120,-250,-30),(120,2000,240),(-120,2000,-240),(-120,-250,30),
            (1001,-2000,-2002),(0,Int.min,0),(0,Int.max,0),
            (1,Int.max,9_223_372_036_854_775),(1,Int.min,-9_223_372_036_854_775),
            (Int.max,-1,-9_223_372_036_854_775),(Int.min,1,-9_223_372_036_854_775)
        ] {
            XCTAssertEqual(try entry(goal: goal).target(for: fraction), expected)
        }
    }

    func testSmallGoalDedupAndStrictAchievementThresholdsStayUnchanged() throws {
        for (goal, expected) in [(0,[0,1000]),(1,[0,1000]),(3,[0,500,750,1000]),(4,[0,250,500,750,1000])] {
            XCTAssertEqual(try entry(goal: goal).fractions, expected)
        }
        let ordinary = try entry(goal: 120)
        XCTAssertFalse(ordinary.achieved(0, confirmed: 0))
        XCTAssertTrue(ordinary.achieved(0, confirmed: 1))
        XCTAssertFalse(ordinary.achieved(250, confirmed: 30))
        XCTAssertTrue(ordinary.achieved(250, confirmed: 31))
        XCTAssertFalse(ordinary.achieved(1000, confirmed: 119))
        XCTAssertTrue(ordinary.achieved(1000, confirmed: 120))
        XCTAssertFalse(try entry(goal: 0).achieved(1000, confirmed: 1))
    }

    func testMaximumGoalThresholdsStayExactAndFullGoalDoesNotAddOne() throws {
        let value = try entry(goal: Int.max)
        for (fraction, target) in [(0,0),(250,2_305_843_009_213_693_951),
                                    (500,4_611_686_018_427_387_903),(750,6_917_529_027_641_081_855)] {
            XCTAssertEqual(value.threshold(for: fraction), target + 1)
            XCTAssertFalse(value.achieved(fraction, confirmed: target))
            XCTAssertTrue(value.achieved(fraction, confirmed: target + 1))
        }
        XCTAssertEqual(value.threshold(for: 1000), Int.max)
        XCTAssertFalse(value.achieved(1000, confirmed: Int.max - 1))
        XCTAssertTrue(value.achieved(1000, confirmed: Int.max))
    }

    func testMaximumGoalJournalCanReopenAndEvaluateWithoutChangingFields() throws {
        var journal = DailyConsequenceJournal()
        journal.days = [try entry(goal: Int.max)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-daily-target-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(journal).write(to: url)
        let reopened = try JSONDecoder().decode(DailyConsequenceJournal.self, from: Data(contentsOf: url))
        XCTAssertEqual(reopened, journal)
        let day = try XCTUnwrap(reopened.days.first)
        XCTAssertEqual(day.fractions, [0,250,500,750,1000])
        XCTAssertEqual(day.target(for: 250), 2_305_843_009_213_693_951)
        XCTAssertEqual(reopened, journal)
    }

    func testAcceptedLargeOrphanProgressCanCaptureAndReopenTheDailyGoal() throws {
        let day = calendar.startOfDay(for: now), analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        var state = PlannerState()
        let course = Course(name: "Synthetic large legacy credit", totalMinutes: 120, startDate: day, deadline: day)
        state.courses = [course]
        state.completions = [.init(courseID: course.id, taskID: UUID(), minutes: Int.max / 2, recordedAt: now, studyDate: day)]
        var ledger = SyncLedger()
        try ledger.capture(state)
        _ = try CloudArchive(ledger: ledger).validated()
        let restored = try ledger.materialize(), before = restored
        let plan = ScheduleEngine(calendar: calendar).generate(state: restored, now: now)
        XCTAssertTrue(plan.tasks.isEmpty)
        let captured = try analyzer.capture(state: restored, result: plan, now: now, warningMinutes: 480)
        XCTAssertEqual(captured.goalMinutes, 4_611_686_018_427_387_903)
        XCTAssertEqual(captured.confirmedAtCapture, captured.goalMinutes)
        XCTAssertEqual(captured.capturedRecords, restored.completions)
        XCTAssertEqual(captured.celebrated, [0,250,500,750,1000])
        let reopened = try JSONDecoder().decode(DailyConsequenceDay.self, from: JSONEncoder().encode(captured))
        XCTAssertEqual(reopened, captured)
        XCTAssertTrue(try analyzer.capturedEvidenceIsValid(reopened, state: restored))
        let forecast = try XCTUnwrap(analyzer.forecast(reopened, fraction: 250, horizon: 1))
        XCTAssertEqual(forecast.todayMinutes, 1_152_921_504_606_846_975)
        XCTAssertEqual(forecast.evaluatedDays, 0)
        XCTAssertEqual(restored, before)
    }

    func testJavaScalarTargetsThresholdsAndBandsStayInParity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Android/build/tests/daily-consequence-target.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run ./Android/test.sh to generate daily target controls") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 87)
        for row in rows {
            let value = try entry(goal: try XCTUnwrap(row["goal"] as? Int)), before = value
            let fraction = try XCTUnwrap(row["fraction"] as? Int)
            let target = try XCTUnwrap(row["target"] as? Int), threshold = try XCTUnwrap(row["threshold"] as? Int)
            XCTAssertEqual(value.target(for: fraction), target)
            XCTAssertEqual(value.threshold(for: fraction), threshold)
            XCTAssertEqual(value.achieved(fraction, confirmed: target), row["achievedAtTarget"] as? Bool)
            XCTAssertEqual(value.achieved(fraction, confirmed: threshold), row["achievedAtThreshold"] as? Bool)
            XCTAssertEqual(value.fractions, row["fractions"] as? [Int])
            XCTAssertEqual(value, before)
        }
    }
}

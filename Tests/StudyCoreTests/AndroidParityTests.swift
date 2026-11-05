import XCTest
@testable import StudyCore

final class AndroidParityTests: XCTestCase {
    func testAndroidBackfillDatesRemainActualStudyDatesOnMac() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Android/build/tests/daily-consequence-parity.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Run ./Android/test.sh to generate the synthetic Android backfill fixture")
        }
        let state = try JSONDecoder().decode(PlannerState.self, from: Data(contentsOf: url))
        let actualDay = calendar.date(from: .init(year: 2026, month: 9, day: 14))!
        let recordedDay = calendar.date(byAdding: .day, value: 1, to: actualDay)!
        XCTAssertFalse(state.completions.isEmpty)
        XCTAssertTrue(state.completions.allSatisfy { $0.studyDate == actualDay })
        XCTAssertTrue(state.completions.allSatisfy { calendar.isDate($0.recordedAt, inSameDayAs: recordedDay) })
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        XCTAssertEqual(try analyzer.confirmed(on: actualDay, state: state), 30)
        XCTAssertEqual(try analyzer.confirmed(on: recordedDay, state: state), 0)
    }
    func testAndroidImmediateRequestSurvivesMacReplanning() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Android/build/tests/immediate-parity.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Run Android parity additions first") }
        var state = try JSONDecoder().decode(PlannerState.self, from: Data(contentsOf: url))
        let request = try XCTUnwrap(state.settings.immediateStudy)
        let now = request.task.start.addingTimeInterval(-8)
        _ = state.replan(now: now, calendar: calendar)
        XCTAssertTrue(state.tasks.contains { $0.id == request.task.id && $0.start == request.task.start && $0.lessonID == "B" })
        XCTAssertEqual(state.tasks.filter(\.isUnconfirmed).reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertTrue(state.completions.isEmpty)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("Android/build/tests/immediate-mac-roundtrip.json"))
    }
    private func fixture() throws -> PlannerState {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(PlannerState.self, from: Data(contentsOf: root.appendingPathComponent("Android/tests/fixtures/desktop-parity.json")))
    }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    func testAndroidImportsAndDailyOrderDecodeOnMac() throws {
        let state = try fixture()
        XCTAssertEqual(state.courses.count, 2)
        XCTAssertEqual(state.settings.dailyTaskOrders?.count, 1)
        let netdisk = try XCTUnwrap(state.courses.first { $0.netdisk != nil })
        XCTAssertEqual(netdisk.netdisk?.videoCount, 3)
        XCTAssertEqual(netdisk.netdiskLessons?.count, 3)
        XCTAssertEqual(netdisk.netdisk?.shareTitle, "模拟分享")
        for course in state.courses {
            XCTAssertEqual(state.lessonWorkItems(for: course).reduce(0) { $0 + $1.remainingMinutes }, state.remainingMinutes(for: course))
            XCTAssertEqual(course.lessonOrder, course.webCourse?.timedLessons.map(\.id))
        }
        let decoded = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }
    func testMacReplanRestoresOrderWrittenByAndroid() throws {
        var state = try fixture()
        let now = calendar.date(from: .init(year: 2026, month: 10, day: 7, hour: 8))!
        let original = state.tasks.filter { calendar.isDate($0.start, inSameDayAs: now) }
        let expected = original.map { "\($0.courseID)|\($0.lessonID ?? "")|\($0.durationMinutes)" }
        _ = state.replan(now: now, calendar: calendar)
        let result = state.tasks.filter { calendar.isDate($0.start, inSameDayAs: now) }
        XCTAssertEqual(result.map { "\($0.courseID)|\($0.lessonID ?? "")|\($0.durationMinutes)" }, expected)
        XCTAssertEqual(result.map(\.durationMinutes).reduce(0,+), original.map(\.durationMinutes).reduce(0,+))
    }
}

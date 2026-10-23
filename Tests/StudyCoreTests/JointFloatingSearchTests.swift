import XCTest
@testable import StudyCore

final class JointFloatingSearchTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ minute: Int = 480) -> Date {
        calendar.date(from: .init(year: 2026, month: 9, day: 14))!.addingTimeInterval(Double(minute * 60))
    }
    private func state(end: Int, events: [[Int]]) -> PlannerState {
        var value = PlannerState()
        var course = Course(name: "联合排程合成课程", totalMinutes: 210, startDate: date(), deadline: date())
        course.type = .lessonBasedRecorded
        course.manualLessons = [120,90].enumerated().map { .init(id: "unit\($0.offset)", name: "合成课节", durationMinutes: $0.element) }
        value.courses = [course]
        value.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: end)]
        value.fixedEvents = events.enumerated().map { index, row in
            var event = FixedEvent(title: "合成浮动\(index)", startMinute: row[0], endMinute: row[1], startDate: date(), endDate: date())
            event.id = stablePlannerID("joint-floating-\(index)")
            event.floatingDurationMinutes = row[2]
            return event
        }
        return value
    }
    func testTwoFloatingEventsCanMoveTogetherToFitWholeLessons() {
        let value = state(end: 780, events: [[540,720,60], [750,780,15]])
        let result = ScheduleEngine(calendar: calendar).generate(state: value, now: date())
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [120,90])
        XCTAssertEqual(result.tasks.map(\.start), [date(480), date(660)])
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.adjustments.contains { $0.contains("已联合调整浮动事项") })
    }
    func testFiveMinuteEventCanUseBreakWithoutShorteningIt() {
        let value = state(end: 705, events: [[540,705,5]])
        let result = ScheduleEngine(calendar: calendar).generate(state: value, now: date())
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [120,90])
        XCTAssertEqual(result.tasks.map(\.start), [date(480), date(615)])
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.adjustments.contains { $0.contains("已联合调整浮动事项") })
    }
    func testSeveralShortEventsPreserveUnelapsedRest() throws {
        let queue = ScheduleFeasibilitySearch.Queue(courseID: UUID(), start: 480, end: 615,
            work: [.init(minutes: 60, lessonID: "a", lessonName: "A"), .init(minutes: 60, lessonID: "b", lessonName: "B")])
        let windows = [ScheduleFeasibilitySearch.Window(start: 480, end: 615)]
        let events = (0..<2).map { _ in ScheduleFeasibilitySearch.Floating(key: date(0), start: 540, end: 555, minutes: 5) }
        let result = try XCTUnwrap(ScheduleFeasibilitySearch.find(queues: [queue], study: windows, eventWindows: windows,
            floating: events, floor: 480, initial: 0))
        XCTAssertEqual(result.tasks.map { Int($0.start.timeIntervalSinceReferenceDate / 60) }, [480,555])
        XCTAssertEqual(Set(result.floatingStarts.values), [540,545])
    }
    func testOversizedDayRemainsUnknownWithoutPartialReplacement() {
        let queue = ScheduleFeasibilitySearch.Queue(courseID: UUID(), start: 0, end: 120,
            work: [.init(minutes: 30, lessonID: "a", lessonName: "A")])
        let windows = [ScheduleFeasibilitySearch.Window(start: 0, end: 120)]
        let events = (0..<9).map { _ in ScheduleFeasibilitySearch.Floating(key: date(0), start: 0, end: 120, minutes: 5) }
        XCTAssertNil(ScheduleFeasibilitySearch.find(queues: [queue], study: windows, eventWindows: windows,
            floating: events, floor: 0, initial: 0))
    }
    private func fixtures() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Android/build/tests/joint-floating-parity.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run ./Android/test.sh to generate joint-floating fixtures") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    func testEngineMatchesAndroidAcrossAllRuleOrders() throws {
        let rows = try XCTUnwrap(fixtures()["engine"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 48)
        for row in rows {
            let value = try JSONDecoder().decode(PlannerState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["state"])))
            let expected = try JSONDecoder().decode([ScheduledTask].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["tasks"])))
            let result = ScheduleEngine(calendar: calendar).generate(state: value, now: date())
            XCTAssertEqual(result.tasks, expected)
            XCTAssertTrue(result.risks.isEmpty)
            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertTrue(result.diagnostics.isEmpty)
            XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 210)
        }
    }
    // Independent small-instance oracle: enumerate every activity order, trying
    // integer start minutes directly. It uses no production search or pruning.
    private func exhaustive(lengths: [[Int]], study: [[Int]], slots: [[Int]], events: [[Int]], floor: Int, days: Int) -> Bool {
        func firstMinute(_ earliest: Int, _ latest: Int, _ duration: Int, _ windows: [[Int]]) -> Int? {
            guard earliest <= latest else { return nil }
            for at in earliest...latest where windows.contains(where: { at >= $0[0] && at + duration <= $0[1] }) { return at }
            return nil
        }
        func visit(_ positions: [Int], _ done: Int, _ end: Int, _ lastStudyEnd: Int) -> Bool {
            if zip(positions, lengths).allSatisfy({ $0 == $1.count }) && done == (1 << events.count) - 1 { return true }
            for c in lengths.indices where positions[c] < lengths[c].count {
                let duration = lengths[c][positions[c]]
                if let at = firstMinute(max(floor, end, lastStudyEnd + 15), days * 1440 - duration, duration, study) {
                    var next = positions; next[c] += 1
                    if visit(next, done, at + duration, at + duration) { return true }
                }
            }
            for f in events.indices where done & (1 << f) == 0 {
                let event = events[f]
                if let at = firstMinute(max(end, event[0]), event[1] - event[2], event[2], slots),
                   visit(positions, done | (1 << f), at + event[2], lastStudyEnd) { return true }
            }
            return false
        }
        return visit(lengths.map { _ in 0 }, 0, 0, -10_000)
    }
    func testDirectSearchMatchesAndroidAndIndependentExhaustion() throws {
        let rows = try XCTUnwrap(fixtures()["direct"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 74)
        let base = Int(date(0).timeIntervalSinceReferenceDate / 60)
        for row in rows {
            let lengths = try XCTUnwrap(row["lengths"] as? [[Int]])
            let study = try XCTUnwrap(row["study"] as? [[Int]])
            let slots = try XCTUnwrap(row["eventWindows"] as? [[Int]])
            let events = try XCTUnwrap(row["events"] as? [[Int]])
            let floor = try XCTUnwrap(row["floor"] as? Int), days = try XCTUnwrap(row["days"] as? Int)
            let number = try XCTUnwrap(row["number"] as? Int)
            let ids = lengths.indices.map { stablePlannerID("floating-direct-course-\($0)") }
            let queues = lengths.enumerated().map { c, values in
                ScheduleFeasibilitySearch.Queue(courseID: ids[c], start: base, end: base + days * 1440,
                    work: values.enumerated().map { .init(minutes: $0.element, lessonID: "unit\($0.offset)", lessonName: "合成课节") })
            }
            let studyWindows = study.map { ScheduleFeasibilitySearch.Window(start: base + $0[0], end: base + $0[1]) }
            let eventWindows = slots.map { ScheduleFeasibilitySearch.Window(start: base + $0[0], end: base + $0[1]) }
            let floating = events.map { ScheduleFeasibilitySearch.Floating(key: calendar.startOfDay(for: date($0[0])),
                start: base + $0[0], end: base + $0[1], minutes: $0[2]) }
            let result = ScheduleFeasibilitySearch.find(queues: queues, study: studyWindows, eventWindows: eventWindows,
                floating: floating, floor: base + floor, initial: base)
            let exact = exhaustive(lengths: lengths, study: study, slots: slots, events: events, floor: floor, days: days)
            XCTAssertEqual(result != nil, exact, "Exact feasibility case \(number)")
            XCTAssertEqual(result != nil, row["found"] as? Bool, "Android feasibility case \(number)")
            guard let result else { continue }
            let tasks = result.tasks.map { task -> [Int] in
                [ids.firstIndex(of: task.courseID)!, Int(task.lessonID!.dropFirst(4))!,
                 Int(task.start.timeIntervalSinceReferenceDate / 60) - base, task.durationMinutes]
            }
            XCTAssertEqual(tasks, row["tasks"] as? [[Int]], "Android tasks case \(number)")
            XCTAssertEqual(events.indices.map { result.floatingStarts[$0]! - base }, row["floating"] as? [Int], "Android events case \(number)")
            // Independently validate the complete witness, including separate
            // same-day events, exact obstacles and breaks across midnight.
            var occupied: [[Int]] = []
            for (i, task) in tasks.enumerated() {
                let start = task[2], end = start + task[3]
                XCTAssertTrue(study.contains { start >= $0[0] && end <= $0[1] })
                XCTAssertGreaterThanOrEqual(start, floor)
                if i > 0 { XCTAssertGreaterThanOrEqual(start - tasks[i-1][2] - tasks[i-1][3], 15) }
                occupied.append([start,end])
            }
            for f in events.indices {
                let start = try XCTUnwrap(result.floatingStarts[f]) - base, end = start + events[f][2]
                XCTAssertGreaterThanOrEqual(start, events[f][0]); XCTAssertLessThanOrEqual(end, events[f][1])
                XCTAssertTrue(slots.contains { start >= $0[0] && end <= $0[1] })
                occupied.append([start,end])
            }
            occupied.sort { $0[0] < $1[0] }
            for (a,b) in zip(occupied, occupied.dropFirst()) { XCTAssertLessThanOrEqual(a[1], b[0]) }
        }
    }
}

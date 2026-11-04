import XCTest
@testable import StudyCore

final class FloatingCapacityBoundTests: XCTestCase {
    private func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }
    private func event(_ serial: Int, _ start: Int, _ end: Int, _ duration: Int?) -> FixedEvent {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        var value = FixedEvent(title: "Synthetic bound", startMinute: start, endMinute: end, startDate: date, endDate: date)
        value.id = id(serial)
        value.floatingDurationMinutes = duration
        return value
    }
    private func assertWitness(_ events: [FixedEvent], study: Set<Int> = [], expected: [UUID: Int]?,
                               file: StaticString = #filePath, line: UInt = #line) {
        let before = events
        XCTAssertEqual(FloatingPlacement.reserve(events, studyMinutes: study), expected, file: file, line: line)
        XCTAssertEqual(events, before, file: file, line: line)
    }

    func testRecordedSuccessfulWitnessesPreserveLatestAndStudyCostPreferences() {
        assertWitness([event(1,540,720,60)], expected: [id(1):660])
        assertWitness([event(1,540,660,60),event(2,540,780,120)], study: Set(600..<660), expected: [id(1):540,id(2):660])
        assertWitness([event(1,540,720,60)], study: Set(600..<720), expected: [id(1):540])
        assertWitness([event(1,540,660,60),event(2,600,720,60)], expected: [id(1):600,id(2):660])
    }

    func testFloatingWindowUnionDoesNotDoubleCountOverlapOrUnrelatedMinutes() {
        assertWitness([event(1,540,660,90),event(2,540,660,90)], expected: nil)
        assertWitness([event(1,540,600,60),event(2,660,720,60),event(3,600,660,nil)], expected: [id(1):540,id(2):660])
        assertWitness([event(1,540,600,60),event(2,660,720,60),event(3,540,600,1)], expected: nil)
    }

    func testExactUnionOnlySubtractsCoveredFloatingMinutesOnce() {
        assertWitness([event(1,540,720,60),event(2,540,600,nil),event(3,540,600,nil),event(4,565,585,nil)], expected: [id(1):660])
        assertWitness([event(1,540,600,60),event(2,0,540,nil),event(3,600,1440,nil)], expected: [id(1):540])
        assertWitness([event(1,540,720,90),event(2,540,720,75),event(3,600,630,nil)], expected: nil)
    }

    func testPassingTheAggregateBoundDoesNotGuaranteeOneContinuousPlacement() {
        // The free union has135minutes, but its60/75-minute pieces cannot hold120.
        assertWitness([event(1,540,720,120),event(2,600,630,nil),event(3,615,645,nil)], expected: nil)
    }

    func testNominalDayBoundaryAndPositiveDemandRemainSafe() {
        assertWitness([event(1,0,1440,1440)], expected: [id(1):0])
        assertWitness([event(1,0,1440,1440),event(2,0,1,nil)], expected: nil)
        assertWitness([event(1,0,1440,720),event(2,0,1440,721)], expected: nil)
        assertWitness((1...1441).map { event($0,0,1,1) }, expected: nil)
        assertWitness([event(1,540,720,nil),event(2,600,780,nil)], expected: [:])
        assertWitness([], expected: [:])
    }

    func testExistingInvalidDurationPreflightIsUnchanged() {
        for duration in [0,-1,61,Int.max] { assertWitness([event(1,540,600,duration)], expected: nil) }
    }

    func testExactOnlyFastPathStillValidatesEveryWindow() {
        for (start, end) in [(600,600),(600,540),(-1,60),(0,1441)] {
            assertWitness([event(1,start,end,nil)], expected: nil)
        }
    }

    func testNominalFailureStillAllowsTheExistingRepeatedHourActualFallback() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let date = cal.date(from: .init(year: 2026, month: 11, day: 1))!
        var first = event(1,60,120,60), second = event(2,60,120,60)
        first.startDate = date; first.endDate = date
        second.startDate = date; second.endDate = date
        XCTAssertNil(FloatingPlacement.reserve([first, second]))
        var state = PlannerState()
        try state.updateFixedEvent(first, now: date, calendar: cal)
        try state.updateFixedEvent(second, now: date, calendar: cal)
        XCTAssertEqual(state.fixedEvents, [first, second])
    }

    func testAndroidDeterministicWitnessParity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Android/build/tests/floating-capacity-bound.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run ./Android/test.sh to generate floating bound controls") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 16)
        for row in rows {
            let events = try JSONDecoder().decode([FixedEvent].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["events"])))
            let study = Set(try XCTUnwrap(row["studyMinutes"] as? [Int]))
            let expected: [UUID: Int]?
            if row["placements"] is NSNull { expected = nil }
            else {
                let values = try XCTUnwrap(row["placements"] as? [String: Int])
                expected = try Dictionary(uniqueKeysWithValues: values.map { (try XCTUnwrap(UUID(uuidString: $0.key)), $0.value) })
            }
            assertWitness(events, study: study, expected: expected)
        }
    }
}

import XCTest
@testable import StudyCore

final class FixedEventActualOverlapTests: XCTestCase {
    private func calendar(_ zone: String = "Australia/Lord_Howe") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func day(_ cal: Calendar, month: Int = 10, number: Int = 4) -> Date {
        cal.date(from: .init(year: 2026, month: month, day: number))!
    }
    private func event(_ start: Int, _ end: Int, _ duration: Int? = nil, day: Date) -> FixedEvent {
        var value = FixedEvent(title: "Synthetic actual overlap", startMinute: start, endMinute: end, startDate: day, endDate: day)
        value.floatingDurationMinutes = duration
        return value
    }
    private func span(_ event: FixedEvent, day: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let engine = ScheduleEngine(calendar: calendar)
        return (engine.instant(day: day, minute: event.startMinute), engine.instant(day: day, minute: event.endMinute))
    }
    private func overlap(_ a: FixedEvent, _ b: FixedEvent, day: Date, calendar: Calendar) -> Double {
        let a = span(a, day: day, calendar: calendar), b = span(b, day: day, calendar: calendar)
        return max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start))) / 60
    }
    private func conflicts(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> [FixedEventConflict] {
        do { try body(); XCTFail("Expected a fixed conflict", file: file, line: line) }
        catch let PlannerError.fixedConflict(values) { return values }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
        return []
    }

    func testNominallyDisjointExactEventsUseTheirActualIntersection() throws {
        for zone in ["Australia/Lord_Howe", "UTC", "Asia/Shanghai"] {
            let cal = calendar(zone), date = day(cal)
            let old = event(105, 120, day: date), requested = event(150, 270, day: date)
            var state = PlannerState()
            try state.updateFixedEvent(old, now: date, calendar: cal)
            let before = state, minutes = overlap(old, requested, day: date, calendar: cal)
            if minutes > 0 {
                let values = conflicts { try state.updateFixedEvent(requested, now: date, calendar: cal) }
                XCTAssertEqual(values.map(\.eventID), [old.id])
                XCTAssertEqual(values.map(\.reason), [.overlap])
                if let value = values.first {
                    XCTAssertEqual(value.explanation, "按实际时间重叠 \(String(format: "%g", minutes)) 分钟")
                    XCTAssertEqual(value.timeDescription, "01:45–02:00")
                    XCTAssertEqual(value.requestedStartMinute, 150)
                    XCTAssertEqual(value.requestedEndMinute, 270)
                    XCTAssertEqual(value.date, date)
                }
                XCTAssertEqual(state, before)
            } else {
                try state.updateFixedEvent(requested, now: date, calendar: cal)
                XCTAssertEqual(state.fixedEvents, [old, requested])
            }
        }
    }

    func testActualExactBlockJoinsAFloatingComponent() throws {
        let cal = calendar(), date = day(cal)
        let old = event(105, 120, day: date), requested = event(150, 270, 45, day: date)
        var state = PlannerState()
        try state.updateFixedEvent(old, now: date, calendar: cal)
        let before = state
        if overlap(old, requested, day: date, calendar: cal) > 0 {
            let values = conflicts { try state.updateFixedEvent(requested, now: date, calendar: cal) }
            XCTAssertEqual(values.map(\.eventID), [old.id])
            XCTAssertEqual(values.map(\.reason), [.floatingCapacity])
            XCTAssertEqual(state, before)
        } else {
            try state.updateFixedEvent(requested, now: date, calendar: cal)
            XCTAssertEqual(state.fixedEvents, [old, requested])
        }
    }

    func testRestoringAnActualOverlapKeepsTheExclusionAtomically() throws {
        let cal = calendar(), date = day(cal)
        let old = event(105, 120, day: date)
        var requested = event(150, 270, day: date), state = PlannerState()
        requested.excludedDates = [date]
        state.fixedEvents = [old, requested]
        let before = state
        if overlap(old, requested, day: date, calendar: cal) > 0 {
            let values = conflicts { try state.setFixedEventSkipped(id: requested.id, on: date, skipped: false, now: date, calendar: cal) }
            XCTAssertEqual(values.map(\.eventID), [old.id])
            XCTAssertEqual(values.map(\.reason), [.overlap])
            XCTAssertEqual(state, before)
        } else {
            try state.setFixedEventSkipped(id: requested.id, on: date, skipped: false, now: date, calendar: cal)
            XCTAssertEqual(state.fixedEvents.last?.excludedDates, [])
        }
    }

    func testActualConflictSkipChoicesKeepOriginalRuleFields() throws {
        let cal = calendar(), date = day(cal)
        let old = event(105, 120, day: date), requested = event(150, 270, day: date)
        for skipIncoming in [false, true] {
            var state = PlannerState()
            state.fixedEvents = [old]
            try state.updateFixedEvent(requested, now: date, calendar: cal,
                                       skippingDates: skipIncoming ? [date] : [], skippingExistingDates: [date])
            var expectedOld = old, expectedNew = requested
            if skipIncoming { expectedNew.excludedDates = [date] }
            else if overlap(old, requested, day: date, calendar: cal) > 0 { expectedOld.excludedDates = [date] }
            XCTAssertEqual(state.fixedEvents, [expectedOld, expectedNew])
        }
    }

    func testMixedConnectivityDoesNotFillTheNominalGap() throws {
        let cal = calendar(), date = day(cal)
        let earlier = event(105, 120, day: date), middle = event(125, 140, day: date)
        let middleOverlap = event(130, 135, day: date), requested = event(150, 270, 45, day: date)
        let earlierSpan = span(earlier, day: date, calendar: cal), middleSpan = span(middle, day: date, calendar: cal)
        // Nonexistent-time mapping differs between Foundation platforms. The
        // disconnected middle controls apply when it maps beyond the first end.
        guard overlap(earlier, requested, day: date, calendar: cal) > 0,
              earlierSpan.end <= middleSpan.start,
              overlap(middle, requested, day: date, calendar: cal) == 0 else { return }
        var state = PlannerState()
        state.fixedEvents = [earlier, middle, middleOverlap]
        let before = state
        let values = conflicts { try state.updateFixedEvent(requested, now: date, calendar: cal) }
        XCTAssertEqual(values.map(\.eventID), [earlier.id])
        XCTAssertEqual(state, before)
        try state.updateFixedEvent(requested, now: date, calendar: cal, skippingExistingDates: [date])
        XCTAssertEqual(state.fixedEvents[1], middle)
        XCTAssertEqual(state.fixedEvents[2], middleOverlap)
        XCTAssertEqual(state.fixedEvents[0].excludedDates, [date])
        XCTAssertEqual(state.fixedEvents.last, requested)
    }

    func testActualAndNominalEdgesFormOneTransitiveComponent() throws {
        let cal = calendar(), date = day(cal)
        let early = event(100, 110, day: date), bridge = event(105, 120, day: date)
        let requested = event(150, 270, 45, day: date)
        var state = PlannerState()
        state.fixedEvents = [early, bridge]
        let before = state
        if overlap(bridge, requested, day: date, calendar: cal) > 0 {
            let values = conflicts { try state.updateFixedEvent(requested, now: date, calendar: cal) }
            XCTAssertEqual(Set(values.map(\.eventID)), [early.id, bridge.id])
            XCTAssertEqual(state, before)
        } else {
            try state.updateFixedEvent(requested, now: date, calendar: cal)
            XCTAssertEqual(state.fixedEvents, [early, bridge, requested])
        }
    }

    func testClockChangeExplanationUsesElapsedOverlapAndOrdinaryTextStaysUnchanged() throws {
        for zone in ["America/New_York", "UTC"] {
            let cal = calendar(zone), date = day(cal, month: 3, number: 8)
            let old = event(60, 180, day: date), requested = event(90, 210, day: date)
            var state = PlannerState()
            state.fixedEvents = [old]
            let before = state
            let values = conflicts { try state.updateFixedEvent(requested, now: date, calendar: cal) }
            XCTAssertEqual(values.map(\.eventID), [old.id])
            XCTAssertEqual(values.first?.explanation, zone == "UTC" ? "重叠 01:30–03:00（90 分钟）" : "按实际时间重叠 30 分钟")
            XCTAssertEqual(state, before)
        }
    }

    func testUnrelatedInvalidImportedWindowIsNotMappedOrRepaired() throws {
        let cal = calendar("UTC"), date = day(cal)
        let invalid = event(Int.min, -1, day: date), requested = event(480, 540, day: date)
        var state = PlannerState()
        state.fixedEvents = [invalid]
        try state.updateFixedEvent(requested, now: date, calendar: cal)
        XCTAssertEqual(state.fixedEvents, [invalid, requested])
    }

    func testOrdinaryExactPairsMatchAndroidConflictMetadata() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Android/build/tests/fixed-event-actual-overlap.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run ./Android/test.sh to generate exact-overlap controls") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 6)
        let cal = calendar("Asia/Shanghai")
        for row in rows {
            var state = try JSONDecoder().decode(PlannerState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["state"])))
            let requested = try JSONDecoder().decode(FixedEvent.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["event"])))
            let events = try JSONDecoder().decode([FixedEvent].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["events"])))
            let now = Date(timeIntervalSinceReferenceDate: try XCTUnwrap(row["now"] as? Double)), before = state
            if try XCTUnwrap(row["succeeds"] as? Bool) {
                try state.updateFixedEvent(requested, now: now, calendar: cal)
                var expected = before
                expected.fixedEvents = events
                XCTAssertEqual(state, expected)
            } else {
                let values = conflicts { try state.updateFixedEvent(requested, now: now, calendar: cal) }
                XCTAssertEqual(values.count, 1)
                XCTAssertEqual(values.first?.eventID, before.fixedEvents.first?.id)
                XCTAssertEqual(values.first?.date, cal.startOfDay(for: now))
                XCTAssertEqual(values.first?.reason, .overlap)
                XCTAssertEqual(values.first?.explanation, row["explanation"] as? String)
                XCTAssertEqual(values.first?.timeDescription, row["description"] as? String)
                XCTAssertEqual(state, before)
            }
        }
    }
}

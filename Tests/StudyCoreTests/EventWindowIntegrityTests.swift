import XCTest
@testable import StudyCore

final class EventWindowIntegrityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func event(_ start: Int = 480, _ end: Int = 540, floating: Int? = nil) -> FixedEvent {
        var value = FixedEvent(title: "Window integrity", startMinute: start, endMinute: end,
                               startDate: now, endDate: now)
        value.floatingDurationMinutes = floating
        return value
    }

    private func state(_ event: FixedEvent) -> PlannerState {
        var value = PlannerState()
        value.fixedEvents = [event]
        return value
    }

    private func encoded(_ ledger: SyncLedger) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ledger)
    }

    private func wire(_ event: FixedEvent, payload: Data? = nil, deleted: Bool = false) throws -> SyncLedger {
        var ledger = SyncLedger()
        try ledger.capture(PlannerState())
        try ledger.merge([.init(kind: "fixedEvents", id: event.id.uuidString,
            payload: try payload ?? JSONEncoder().encode(event), deleted: deleted,
            version: 1, device: "event-window-fixture", sequence: 1)])
        return ledger
    }

    func testInvalidWindowsRejectBeforeChangingLedgerOrState() throws {
        var invalid: [FixedEvent] = []
        for (start, end) in [(-1, 60), (0, 1441), (60, 60), (61, 60), (Int.min, Int.max), (Int.max, Int.min)] {
            invalid.append(event(start, end))
            invalid.append(event(start, end, floating: 60))
        }
        for duration in [0, -1, 61, Int.min, Int.max] {
            invalid.append(event(0, 60, floating: duration))
        }
        for bad in invalid {
            let input = state(bad), before = input
            var ledger = SyncLedger()
            try ledger.capture(state(event()))
            let saved = try encoded(ledger)
            XCTAssertThrowsError(try ledger.capture(input)) {
                XCTAssertEqual($0 as? SyncFailure, .invalidData)
            }
            XCTAssertEqual(try encoded(ledger), saved)
            XCTAssertEqual(input, before)
            XCTAssertThrowsError(try PlannerBackup(state: input, reason: "Bad event window").validated())
            let imported = try wire(bad), wireBefore = try encoded(imported)
            XCTAssertThrowsError(try imported.materialize())
            XCTAssertThrowsError(try CloudArchive(ledger: imported).validated())
            XCTAssertEqual(try encoded(imported), wireBefore)
        }
    }

    func testExactAndFloatingDayBoundariesSurviveRoundTrip() throws {
        for valid in [event(0, 1), event(1439, 1440), event(0, 1440),
                      event(0, 1440, floating: 1), event(0, 1440, floating: 1440), event(floating: 60)] {
            let input = state(valid)
            _ = try PlannerBackup(state: input, reason: "Valid event window").validated()
            var ledger = SyncLedger()
            try ledger.capture(input)
            let before = try encoded(ledger)
            let restored = try ledger.materialize()
            XCTAssertEqual(restored.fixedEvents, [valid])
            XCTAssertTrue(try XCTUnwrap(restored.fixedEvents.first).validDuration)
            _ = try CloudArchive(ledger: ledger).validated()
            try ledger.capture(restored)
            XCTAssertEqual(try encoded(ledger), before)
        }
    }

    func testRequiredNumbersAndOptionalFloatingWireTypes() throws {
        let valid = event(floating: 60)
        for field in ["startMinute", "endMinute", "floatingDurationMinutes"] {
            var badValues: [Any] = ["60", true, 60.5, 1e300]
            if field != "floatingDurationMinutes" { badValues.append(NSNull()) }
            for value in badValues {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
                object[field] = value
                let imported = try wire(valid, payload: JSONSerialization.data(withJSONObject: object))
                let before = try encoded(imported)
                XCTAssertThrowsError(try imported.materialize())
                XCTAssertThrowsError(try CloudArchive(ledger: imported).validated())
                XCTAssertEqual(try encoded(imported), before)
            }
            if field != "floatingDurationMinutes" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
                object.removeValue(forKey: field)
                XCTAssertThrowsError(try wire(valid, payload: JSONSerialization.data(withJSONObject: object)).materialize())
            }
        }
        for floating in ["missing", "null", "6e1"] {
            let exact = event()
            var json = String(decoding: try JSONEncoder().encode(exact), as: UTF8.self)
            json = json.replacingOccurrences(of: "\"startMinute\":480", with: "\"startMinute\":4.8e2")
                .replacingOccurrences(of: "\"endMinute\":540", with: "\"endMinute\":540.0")
            XCTAssertTrue(json.contains("4.8e2") && json.contains("540.0"))
            if floating != "missing" { json = String(json.dropLast()) + ",\"floatingDurationMinutes\":\(floating)}" }
            let imported = try wire(exact, payload: Data(json.utf8))
            let saved = try XCTUnwrap(imported.materialize().fixedEvents.first)
            XCTAssertEqual(saved.startMinute, 480)
            XCTAssertEqual(saved.endMinute, 540)
            XCTAssertEqual(saved.floatingDurationMinutes, floating == "6e1" ? 60 : nil)
            _ = try CloudArchive(ledger: imported).validated()
        }
    }

    func testDeletedEventPayloadsRemainIgnored() throws {
        let bad = event(Int.min, Int.max, floating: 60)
        for payload in [try JSONEncoder().encode(bad), Data("not JSON".utf8)] {
            let ledger = try wire(bad, payload: payload, deleted: true)
            let before = try encoded(ledger)
            XCTAssertTrue(try ledger.materialize().fixedEvents.isEmpty)
            _ = try CloudArchive(ledger: ledger).validated()
            XCTAssertEqual(try encoded(ledger), before)
        }
    }

    func testWindowValidationDoesNotAddDateOrWeekdayRules() throws {
        var unusual = event()
        unusual.endDate = now.addingTimeInterval(-86_400)
        unusual.weekdays = [0, 8]
        var ledger = SyncLedger()
        try ledger.capture(state(unusual))
        XCTAssertEqual(try ledger.materialize().fixedEvents, [unusual])
        _ = try CloudArchive(ledger: ledger).validated()
    }
}

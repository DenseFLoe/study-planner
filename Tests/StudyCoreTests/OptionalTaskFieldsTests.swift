import XCTest
@testable import StudyCore

final class OptionalTaskFieldsTests: XCTestCase {
    func testNullOptionalTaskFieldsMatchMissingValues() throws {
        let task = ScheduledTask(courseID: UUID(), start: Date(timeIntervalSinceReferenceDate: 815_846_400), durationMinutes: 60)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(task)) as? [String: Any])
        for key in ["confirmedAt", "floatingWindowStart", "floatingWindowEnd"] { payload[key] = NSNull() }
        let restored = try decoder.decode(ScheduledTask.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(restored, task); XCTAssertTrue(restored.isUnconfirmed); XCTAssertFalse(restored.isFloating)
        XCTAssertEqual(restored.planningStart, task.start); XCTAssertEqual(restored.planningEnd, task.end)
    }
    func testOneSidedWindowAndZeroConfirmationTimeKeepTheirMeanings() throws {
        let task = ScheduledTask(courseID: UUID(), start: Date(timeIntervalSinceReferenceDate: 815_846_400), durationMinutes: 60)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        payload["floatingWindowStart"] = task.start.timeIntervalSinceReferenceDate - 3600
        payload["floatingWindowEnd"] = NSNull(); payload["confirmedAt"] = NSNull()
        var restored = try JSONDecoder().decode(ScheduledTask.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertTrue(restored.isUnconfirmed); XCTAssertFalse(restored.isFloating)
        XCTAssertEqual(restored.planningStart, task.start - 3600); XCTAssertEqual(restored.planningEnd, task.end)
        payload["confirmedAt"] = 0
        restored = try JSONDecoder().decode(ScheduledTask.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertFalse(restored.isUnconfirmed); XCTAssertEqual(restored.confirmedAt, Date(timeIntervalSinceReferenceDate: 0))
    }
}

import XCTest
@testable import StudyCore

final class SyncOptionalTimestampTests: XCTestCase {
    private func wireRow() -> [String: Any] {
        ["kind": "tasks", "id": stablePlannerID("optional-timestamp").uuidString,
         "payload": "e30=", "deleted": true, "version": 1, "device": "legacy", "sequence": 1]
    }

    private func decode(_ row: [String: Any]) throws -> SyncRecord {
        try JSONDecoder().decode(SyncRecord.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testOptionalNullMatchesMissingAndZeroForMergeOrdering() throws {
        let missing = try decode(wireRow())
        var raw = wireRow(); raw["modifiedAt"] = NSNull()
        let null = try decode(raw)
        raw["modifiedAt"] = 0
        let zero = try decode(raw)
        XCTAssertNil(null.modifiedAt)
        for other in [missing, zero] {
            XCTAssertFalse(null.wins(over: other))
            XCTAssertFalse(other.wins(over: null))
        }
        raw["version"] = 2
        let newer = try decode(raw)
        XCTAssertTrue(newer.wins(over: null))
        XCTAssertFalse(null.wins(over: newer))
        var ledger = SyncLedger()
        try ledger.merge([null])
        XCTAssertEqual(ledger.records[null.key]?.modifiedAt, nil)
        XCTAssertEqual(ledger.records.count, 1)
    }

    func testArchiveAcceptsExplicitNullOptionalTimestamp() throws {
        var ledger = SyncLedger()
        try ledger.capture(PlannerState())
        var raw = wireRow(); raw["modifiedAt"] = NSNull()
        try ledger.merge([decode(raw)])
        let encoded = try JSONEncoder().encode(CloudArchive(ledger: ledger))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let index = try XCTUnwrap(records.firstIndex { $0["kind"] as? String == "tasks" })
        records[index]["modifiedAt"] = NSNull(); object["records"] = records
        let archive = try JSONDecoder().decode(CloudArchive.self, from: JSONSerialization.data(withJSONObject: object))
        let validated = try archive.validated()
        XCTAssertEqual(validated.records.count, ledger.records.count)
        XCTAssertNil(validated.records.first { $0.kind == "tasks" }?.modifiedAt)
    }

    func testRequiredWireFieldsStillRejectNull() throws {
        for field in ["version", "sequence", "deleted"] {
            var raw = wireRow(); raw[field] = NSNull()
            XCTAssertThrowsError(try decode(raw), field)
        }
    }
}

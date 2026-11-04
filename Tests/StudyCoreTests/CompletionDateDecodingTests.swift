import XCTest
@testable import StudyCore

final class CompletionDateDecodingTests: XCTestCase {
    private func payload() throws -> [String: Any] {
        let record = CompletionRecord(courseID: UUID(), taskID: UUID(), minutes: 20, recordedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }
    func testMalformedDatePrimitivesAndMissingConfirmationTimeAreRejected() throws {
        for key in ["recordedAt", "studyDate"] {
            for value in ["800000000", "not a date", true, [String: String](), [String]()] as [Any] {
                var raw = try payload(); raw[key] = value
                let data = try JSONSerialization.data(withJSONObject: raw)
                XCTAssertThrowsError(try JSONDecoder().decode(CompletionRecord.self, from: data), "Accepted malformed \(key): \(value)")
            }
        }
        var raw = try payload(); raw["recordedAt"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(CompletionRecord.self, from: JSONSerialization.data(withJSONObject: raw)))
        raw.removeValue(forKey: "recordedAt")
        XCTAssertThrowsError(try JSONDecoder().decode(CompletionRecord.self, from: JSONSerialization.data(withJSONObject: raw)))
    }
    func testNullLegacyDateAndFractionalReferenceDatesRemainReadable() throws {
        var raw = try payload(); raw["studyDate"] = NSNull()
        let legacy = try JSONDecoder().decode(CompletionRecord.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(legacy.studyDate); XCTAssertEqual(legacy.minutes, 20)
        for value in [0.0, -1, 1.25, -1.25, 800_000_000.125] {
            raw["recordedAt"] = value; raw["studyDate"] = value
            let record = try JSONDecoder().decode(CompletionRecord.self, from: JSONSerialization.data(withJSONObject: raw))
            XCTAssertEqual(record.recordedAt.timeIntervalSinceReferenceDate, value)
            XCTAssertEqual(record.studyDate?.timeIntervalSinceReferenceDate, value)
        }
    }
}

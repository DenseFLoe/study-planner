import XCTest
@testable import StudyCore

final class TaskMetadataDecodingTests: XCTestCase {
    private func payload() throws -> [String: Any] {
        let task = ScheduledTask(courseID: UUID(), start: Date(timeIntervalSinceReferenceDate: 815_414_400), durationMinutes: 60)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
    }
    func testWrongOptionalMetadataTypesAreRejected() throws {
        var samples: [(String, Any)] = []
        for key in ["start", "confirmedAt", "floatingWindowStart", "floatingWindowEnd"] {
            for value in ["815414400", true, [String: String](), [String]()] as [Any] { samples.append((key, value)) }
        }
        samples.append(("start", NSNull()))
        for key in ["lessonID", "lessonName"] {
            for value in [1, true, [String: String](), [String]()] as [Any] { samples.append((key, value)) }
        }
        for value in ["true", 1, [String: String](), [String]()] as [Any] { samples.append(("replacesConfirmedBlock", value)) }
        for (key, value) in samples {
            var raw = try payload(); raw[key] = value
            let data = try JSONSerialization.data(withJSONObject: raw)
            XCTAssertThrowsError(try JSONDecoder().decode(ScheduledTask.self, from: data), "Accepted malformed \(key): \(value)")
        }
    }
    func testNullAndBooleanReplacementFlagsKeepTheirMeanings() throws {
        for value in [NSNull(), false, true] as [Any] {
            var raw = try payload(); raw["replacesConfirmedBlock"] = value
            let task = try JSONDecoder().decode(ScheduledTask.self, from: JSONSerialization.data(withJSONObject: raw))
            XCTAssertEqual(task.replacesConfirmedBlock, value as? Bool)
            XCTAssertTrue(task.isUnconfirmed)
        }
    }
}

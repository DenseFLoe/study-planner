import XCTest
@testable import StudyCore

final class NetdiskSourcePrivacyTests: XCTestCase {
    private let privateURL = "https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@pan.quark.cn:443/s/abc123?pwd=SYNTHETIC_PASS&token=SYNTHETIC_TOKEN#/list/share/abcd1234"
    private let publicURL = "https://pan.quark.cn/s/abc123#/list/share/abcd1234"
    private let now = Date(timeIntervalSince1970: 1_790_497_416)

    private func metadata() -> NetdiskSnapshot {
        NetdiskSnapshot(pwdID: "abc123", shareTitle: "课程", folderPath: "基础课", sourceURL: privateURL,
                        fetchedAt: now, videoCount: 3, totalBytes: 1234, unknownDurations: 1,
                        detection: "课程判定", duplicates: nil, sourcePackageIDs: ["quark:abc123:folder"])
    }

    func testPublicSourceRetainsOnlyShareAndValidatedFolderIdentity() {
        XCTAssertEqual(NetdiskLink.publicURL(privateURL), publicURL)
        XCTAssertEqual(NetdiskLink.publicURL("pan.quark.cn/s/abc123?passcode=SYNTHETIC_PASS"),
                       "https://pan.quark.cn/s/abc123")
        XCTAssertEqual(NetdiskLink.publicURL("https://pan.quark.cn/s/abc123#SYNTHETIC_FRAGMENT"),
                       "https://pan.quark.cn/s/abc123")
        XCTAssertEqual(NetdiskLink.publicURL("https://example.com/s/abc123?pwd=SYNTHETIC_PASS"), "")
        XCTAssertEqual(NetdiskLink.publicURL(publicURL), publicURL)
    }

    func testMetadataCleansLegacyDecodeAndDirectMutationBeforeEncoding() throws {
        let expected = metadata()
        XCTAssertEqual(expected.sourceURL, publicURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        object["sourceURL"] = privateURL
        let restored = try JSONDecoder().decode(NetdiskSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, expected)
        var mutated = expected
        mutated.sourceURL = privateURL
        let encoded = try JSONEncoder().encode(mutated)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("SYNTHETIC_"))
        XCTAssertEqual(try JSONDecoder().decode(NetdiskSnapshot.self, from: encoded), expected)
        object.removeValue(forKey: "sourcePackageIDs")
        XCTAssertNil(try JSONDecoder().decode(NetdiskSnapshot.self,
                                              from: JSONSerialization.data(withJSONObject: object)).sourcePackageIDs)
    }

    func testCourseRoundTripAndSyncPreserveProgressWhileCleaningSource() throws {
        var state = PlannerState()
        var course = Course(name: "课程", totalMinutes: 60, startDate: now, deadline: now)
        course.netdisk = metadata()
        course.netdisk?.sourceURL = privateURL
        course.lessonOrder = ["lesson2", "lesson1"]
        course.lessonOrderCustomized = true
        course.deletedLessonIDs = ["old-lesson"]
        state.courses = [course]
        let task = ScheduledTask(courseID: course.id, start: now, durationMinutes: 30)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now)
        var expected = state
        expected.courses[0].netdisk?.sourceURL = publicURL
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SYNTHETIC_"))
        XCTAssertEqual(try JSONDecoder().decode(PlannerState.self, from: data), expected)
        var ledger = SyncLedger()
        try ledger.capture(state, now: now)
        XCTAssertEqual(try ledger.materialize(), expected)
        for row in ledger.records.values {
            XCTAssertFalse(String(decoding: row.payload, as: UTF8.self).contains("SYNTHETIC_"))
        }
    }

    func testLegacyWireAndOutboxCleanNestedSourcesWithoutChangingVersionsOrFutureFields() throws {
        let payload: [String: Any] = ["id": "course", "futureField": ["keep": 42],
            "netdisk": ["sourceURL": privateURL, "futureCount": 17],
            "webCourse": ["sourceURL": privateURL, "netdisk": ["sourceURL": privateURL]],
            "mergedSources": [["netdisk": ["sourceURL": privateURL]]]]
        let raw = try JSONSerialization.data(withJSONObject: payload)
        let row = SyncRecord(kind: "courses", id: "course", payload: raw, deleted: true,
                             version: 7, device: "synthetic-device", sequence: 9, modifiedAt: 100)
        let encoded = try JSONDecoder().decode(SyncRecord.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(encoded.version, row.version)
        XCTAssertEqual(encoded.sequence, row.sequence)
        XCTAssertEqual(encoded.modifiedAt, row.modifiedAt)
        XCTAssertEqual(encoded.deleted, row.deleted)
        XCTAssertFalse(String(decoding: encoded.payload, as: UTF8.self).contains("SYNTHETIC_"))
        let clean = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded.payload) as? [String: Any])
        XCTAssertEqual(clean["futureField"] as? [String: Int], ["keep": 42])
        XCTAssertEqual((clean["netdisk"] as? [String: Any])?["sourceURL"] as? String, publicURL)
        XCTAssertEqual((clean["netdisk"] as? [String: Any])?["futureCount"] as? Int, 17)
        var ledger = SyncLedger(); ledger.records[row.key] = encoded
        let archive = CloudArchive(ledger: ledger)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var rows = try XCTUnwrap(object["records"] as? [[String: Any]])
        rows[0]["payload"] = raw.base64EncodedString(); object["records"] = rows
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json.gz")
        defer { try? FileManager.default.removeItem(at: file) }
        try CloudCompression.gzip(JSONSerialization.data(withJSONObject: object)).write(to: file)
        try CloudOutbox.sanitizeSourceURLsBeforeUpload(file)
        let safe = try Data(contentsOf: file)
        let restored = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(safe))
        XCTAssertEqual(restored.archiveID, archive.archiveID)
        XCTAssertEqual(restored.records, archive.records)
        try CloudOutbox.sanitizeSourceURLsBeforeUpload(file)
        XCTAssertEqual(try Data(contentsOf: file), safe)
    }
}

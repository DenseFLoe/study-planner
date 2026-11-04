import XCTest
import StudyCore
@testable import StudyPersistence

final class WebSourcePrivacyTests: XCTestCase {
    func testLegacyURLIsSanitizedBeforeBackupAndSyncWithoutChangingHistory() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshot = try XCTUnwrap(GenericCourseDigest.snapshots(from: [.init(url: "https://a.example/api?token=SYNTHETIC_TOKEN",
            body: #"{"data":[{"id":"L1","courseId":"88","name":"Synthetic","duration":3600,"percent":0}]}"#)],
            pageURL: "https://a.example/course", now: now).first)
        var state = PlannerState()
        try state.importWebCourses([snapshot], deadline: now, now: now)
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 30, lessonID: snapshot.lessons[0].id)
        state.tasks = [task]; try state.confirm(taskID: task.id, actualMinutes: 30, now: now)
        state.courses[0].lessonOrderCustomized = true
        state.courses[0].deletedLessonIDs = ["generic:88:deleted"]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var courses = try XCTUnwrap(object["courses"] as? [[String: Any]])
        var web = try XCTUnwrap(courses[0]["webCourse"] as? [String: Any])
        web["sourceURL"] = "https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@a.example/course?access_token=SYNTHETIC_TOKEN&session=SYNTHETIC_SESSION#SYNTHETIC_FRAGMENT"
        courses[0]["webCourse"] = web; object["courses"] = courses
        let raw = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("SYNTHETIC_TOKEN"))
        let loaded = try JSONDecoder().decode(PlannerState.self, from: raw)
        XCTAssertEqual(loaded, state, "Decoding legacy data changes only the private URL components")
        let backup = try PlannerBackupRepository.encode(PlannerBackup(state: loaded, reason: "Synthetic privacy test"))
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("SYNTHETIC_"))
        var ledger = SyncLedger(); try ledger.capture(loaded)
        for row in ledger.records.values { XCTAssertFalse(String(decoding: row.payload, as: UTF8.self).contains("SYNTHETIC_")) }
        let key = "courses/" + state.courses[0].id.uuidString
        ledger.records[key]?.payload = try JSONSerialization.data(withJSONObject: courses[0])
        try ledger.capture(loaded)
        XCTAssertFalse(String(decoding: try XCTUnwrap(ledger.records[key]?.payload), as: UTF8.self).contains("SYNTHETIC_"))
        var peer = SyncLedger(); try peer.merge(ledger.changes(after: 0))
        XCTAssertEqual(try peer.materialize(), loaded)
        let repository = try LocalRepository(inMemory: true)
        try repository.save(loaded)
        XCTAssertEqual(try repository.load(), loaded)
        var refreshed = loaded
        try refreshed.importWebCourses([snapshot], deadline: now, now: now)
        XCTAssertEqual(refreshed.courses.count, 1)
        XCTAssertEqual(refreshed.courses[0].id, loaded.courses[0].id)
        XCTAssertEqual(refreshed.completions, loaded.completions)
        XCTAssertEqual(refreshed.courses[0].deletedLessonIDs, loaded.courses[0].deletedLessonIDs)
    }

    func testLegacyOutboxAndTombstoneWireEncodingRetainEverythingExceptPrivateURLParts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var ledger = SyncLedger(); try ledger.capture(PlannerState())
        var row = try XCTUnwrap(ledger.records.values.first)
        row.kind = "courses"; row.id = UUID().uuidString; row.deleted = true; row.modifiedAt = 1_234
        let source = "https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@a.example/course?token=SYNTHETIC_TOKEN#SYNTHETIC_FRAGMENT"
        let payload: [String: Any] = ["id": row.id, "futureField": ["keep": 42], "webCourse": ["sourceURL": source],
                                     "mergedSources": [["webCourse": ["sourceURL": source]]]]
        row.payload = try JSONSerialization.data(withJSONObject: payload)
        let encoded = try JSONDecoder().decode(SyncRecord.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(encoded.id, row.id); XCTAssertEqual(encoded.version, row.version)
        XCTAssertEqual(encoded.deleted, row.deleted); XCTAssertEqual(encoded.modifiedAt, row.modifiedAt)
        XCTAssertFalse(String(decoding: encoded.payload, as: UTF8.self).contains("SYNTHETIC_"))
        let clean = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded.payload) as? [String: Any])
        XCTAssertEqual(clean["futureField"] as? [String: Int], ["keep": 42])
        ledger.records[row.key] = encoded
        let archive = CloudArchive(ledger: ledger)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var rows = try XCTUnwrap(object["records"] as? [[String: Any]])
        let index = try XCTUnwrap(rows.firstIndex { $0["kind"] as? String == "courses" })
        rows[index]["payload"] = row.payload.base64EncodedString(); object["records"] = rows
        let file = root.appendingPathComponent("legacy.json.gz")
        try CloudCompression.gzip(JSONSerialization.data(withJSONObject: object)).write(to: file)
        try CloudOutbox.sanitizeSourceURLsBeforeUpload(file)
        let sanitized = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(Data(contentsOf: file)))
        XCTAssertEqual(sanitized.archiveID, archive.archiveID)
        XCTAssertEqual(sanitized.records, archive.records)
        let first = try Data(contentsOf: file)
        try CloudOutbox.sanitizeSourceURLsBeforeUpload(file)
        XCTAssertEqual(try Data(contentsOf: file), first, "Clean retries must be idempotent")
    }
}

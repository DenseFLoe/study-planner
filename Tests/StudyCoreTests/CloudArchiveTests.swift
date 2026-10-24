import XCTest
import Foundation
@testable import StudyCore

final class CloudArchiveTests: XCTestCase {
    func testFullArchiveRetainsOperationsAndDeletes() throws {
        var state = PlannerState(); state.settings.availability = []
        let course = Course(name: "Cloud fixture", totalMinutes: 60, startDate: Date(), deadline: Date())
        state.courses = [course]; var ledger = SyncLedger(); let edited = Date(timeIntervalSince1970: 1_700_000_000)
        try ledger.capture(state, now: edited); state.removeCourse(id: course.id); try ledger.capture(state, now: edited.addingTimeInterval(10))
        let encoder = JSONEncoder(); let data = try CloudCompression.gzip(encoder.encode(CloudArchive(ledger: ledger)))
        let archive = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(data)).validated()
        let deleted = try XCTUnwrap(archive.records.first { $0.kind == "courses" })
        XCTAssertTrue(deleted.deleted); XCTAssertEqual(deleted.modifiedAt, 1_700_000_010_000)
        var restored = SyncLedger(); try restored.merge(archive.records); XCTAssertTrue(try restored.materialize().courses.isEmpty)
        XCTAssertThrowsError(try CloudCompression.gunzip(Data(data.dropLast(4))))
        XCTAssertThrowsError(try CloudCompression.gunzip(data + Data([0])))
    }
    func testOutboxIsDurableAndDeduplicatesSameRevision() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var ledger = SyncLedger(); try ledger.capture(PlannerState())
        let first = try CloudOutbox.enqueue(ledger, directory: folder)
        XCTAssertEqual(first, try CloudOutbox.enqueue(ledger, directory: folder))
        XCTAssertEqual(try CloudOutbox.files(in: folder).count, 1)
        let saved = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(Data(contentsOf: first)))
        XCTAssertEqual(saved.records.count, ledger.records.count)
    }
    func testJavaFullSnapshotCompatibility() throws {
        guard let directory = ProcessInfo.processInfo.environment["STUDY_CLOUD_FIXTURE_DIR"] else { throw XCTSkip("Set fixture directory for cross-language integration") }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("java-latest.json.gz")
        let archive = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(Data(contentsOf: url))).validated()
        var ledger = SyncLedger(); try ledger.merge(archive.records)
        let state = try ledger.materialize(); XCTAssertEqual(state.courses.count, 1); XCTAssertEqual(state.completions.count, 1)
        let encoder = JSONEncoder(); try CloudCompression.gzip(encoder.encode(CloudArchive(ledger: ledger))).write(to: URL(fileURLWithPath: directory).appendingPathComponent("swift-latest.json.gz"))
    }
}

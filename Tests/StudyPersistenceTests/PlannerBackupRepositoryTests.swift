import XCTest
import StudyCore
@testable import StudyPersistence

final class PlannerBackupRepositoryTests: XCTestCase {
    func testRotationReopeningAndCorruptFileIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = PlannerBackupRepository(directory: directory, limit: 3)
        var expected: PlannerBackup?
        for index in 0..<5 {
            let value = PlannerBackup(state: PlannerState(), reason: "备份", now: Date(timeIntervalSince1970: Double(index)))
            try await repo.save(value); expected = value
        }
        let reopened = PlannerBackupRepository(directory: directory, limit: 3)
        let entries = try await reopened.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.id, expected?.id)
        let value = try await reopened.load(entries[0].id)
        XCTAssertEqual(value.state, expected?.state)
        let file = directory.appendingPathComponent(entries[0].id.uuidString + ".json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let corrupt = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("broken".utf8).write(to: corrupt)
        try await reopened.save(.init(state: PlannerState(), reason: "仍可备份"))
        let remaining = try await reopened.entries()
        let unreadable = await reopened.unreadableCount
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(unreadable, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }

    func testPortableExportRejectsUnsupportedVersionAndDuplicateIDs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var state = PlannerState()
        let course = Course(name: "备份测试", totalMinutes: 60, startDate: Date(), deadline: Date())
        state.courses = [course]
        let backup = PlannerBackup(state: state, reason: "导出")
        try PlannerBackupRepository.encode(backup).write(to: url)
        XCTAssertEqual(try PlannerBackupRepository.read(url).state, state)
        var invalid = backup; invalid.format = 100
        try JSONEncoder().encode(invalid).write(to: url)
        XCTAssertThrowsError(try PlannerBackupRepository.read(url))
        invalid = backup; invalid.state.courses.append(course)
        XCTAssertThrowsError(try PlannerBackupRepository.encode(invalid))
        invalid = backup; invalid.state.settings.minimumScheduleUnit = 0
        XCTAssertThrowsError(try PlannerBackupRepository.encode(invalid))
    }
}

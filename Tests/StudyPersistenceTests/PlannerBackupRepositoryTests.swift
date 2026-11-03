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
        XCTAssertEqual(entries.map(\.createdAt), [4, 3, 2].map { Date(timeIntervalSince1970: Double($0)) })
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

    func testClockRollbackKeepsCurrentBackupAtLimitOne() async throws {
        for inMemory in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repo = PlannerBackupRepository(inMemory: inMemory, directory: directory, limit: 1)
            let future = PlannerBackup(state: PlannerState(), reason: "Before clock correction", now: Date(timeIntervalSince1970: 2_000_000_000))
            let current = PlannerBackup(state: PlannerState(), reason: "Current recovery point", now: Date(timeIntervalSince1970: 1_900_000_000))
            try await repo.save(future)
            try await repo.save(current)
            let entries = try await repo.entries()
            XCTAssertEqual(entries.map(\.id), [current.id])
            let loaded = try await repo.load(current.id)
            XCTAssertEqual(loaded.id, current.id)
            XCTAssertEqual(loaded.reason, current.reason)
            if !inMemory {
                let reopened = PlannerBackupRepository(directory: directory, limit: 1)
                let restored = try await reopened.load(current.id)
                XCTAssertEqual(restored.id, current.id)
                XCTAssertEqual(restored.state, current.state)
            }
        }
    }

    func testClockRollbackKeepsNewestOtherBackupsWithinLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = PlannerBackupRepository(directory: directory, limit: 3)
        var previous: [PlannerBackup] = []
        for timestamp in [100, 200, 300] {
            let backup = PlannerBackup(state: PlannerState(), reason: "Previous \(timestamp)", now: Date(timeIntervalSince1970: Double(timestamp)))
            try await repo.save(backup)
            previous.append(backup)
        }
        let current = PlannerBackup(state: PlannerState(), reason: "After clock correction", now: Date(timeIntervalSince1970: 50))
        try await repo.save(current)
        let reopened = PlannerBackupRepository(directory: directory, limit: 3)
        let entries = try await reopened.entries()
        XCTAssertEqual(entries.map(\.id), [previous[2].id, previous[1].id, current.id])
        for id in entries.map(\.id) {
            let loaded = try await reopened.load(id)
            XCTAssertEqual(loaded.id, id)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(previous[0].id.uuidString + ".json").path))
    }

    func testEqualTimestampKeepsCurrentBackupDespiteUUIDSortOrder() async throws {
        for inMemory in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repo = PlannerBackupRepository(inMemory: inMemory, directory: directory, limit: 1)
            let date = Date(timeIntervalSince1970: 1_900_000_000)
            var previous = PlannerBackup(state: PlannerState(), reason: "Sorts first", now: date)
            previous.id = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF"))
            var current = PlannerBackup(state: PlannerState(), reason: "Saved last", now: date)
            current.id = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
            try await repo.save(previous)
            try await repo.save(current)
            let entries = try await repo.entries()
            XCTAssertEqual(entries.map(\.id), [current.id])
            let loaded = try await repo.load(current.id)
            XCTAssertEqual(loaded.reason, current.reason)
            if !inMemory {
                let reopened = PlannerBackupRepository(directory: directory, limit: 1)
                let restored = try await reopened.load(current.id)
                XCTAssertEqual(restored.id, current.id)
            }
        }
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

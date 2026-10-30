import XCTest
import StudyCore
@testable import StudyPersistence

final class CompressedScheduleRepositoryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))! }
    private func time(_ minute: Int, day offset: Int = 0) -> Date {
        ScheduleEngine(calendar: calendar).instant(day: calendar.date(byAdding: .day, value: offset, to: day)!, minute: minute)
    }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 540) }
        state.courses = [[6, 4], [5]].enumerated().map { index, durations in
            var course = Course(name: "缓存课程\(index)", totalMinutes: durations.reduce(0, +), startDate: day, deadline: day)
            course.type = .lessonBasedRecorded
            course.manualLessons = durations.enumerated().map {
                .init(id: "\(index)-\($0.offset)", name: "第\($0.offset)节", durationMinutes: $0.element)
            }
            return course
        }
        state.fixedEvents = [.init(title: "固定课", startMinute: 500, endMinute: 510, startDate: day, endDate: day)]
        return state
    }
    private func makeSnapshot() throws -> CompressedScheduleSnapshot {
        let state = fixture()
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: time(480))
        return .init(basis: CompressedScheduleBasis(state: state), calendar: calendar, plan: plan,
                     preview: try CompressedSchedulePreview(plan: plan, state: state))
    }
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("CompressedSchedule.json")
    }

    func testSavedSnapshotSurvivesReloadInNewInstance() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try makeSnapshot()
        XCTAssertFalse(original.plan.tasks.isEmpty)
        try CompressedScheduleRepository(url: url).save(original)
        let reader = CompressedScheduleRepository(url: url)
        let restored = try XCTUnwrap(reader.load())
        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.calendar, calendar)
        XCTAssertEqual(restored.basis, original.basis)
        XCTAssertEqual(restored.preview, original.preview)
        // The recomputed dates and every task survive a fresh instance.
        XCTAssertEqual(restored.plan.capturedAt, original.plan.capturedAt)
        XCTAssertEqual(restored.plan.finish, original.plan.finish)
        XCTAssertEqual(restored.plan.tasks, original.plan.tasks)
        XCTAssertEqual(restored.plan.courses.map(\.course), original.plan.courses.map(\.course))
        XCTAssertEqual(restored.plan.courses.map(\.remainingMinutes), original.plan.courses.map(\.remainingMinutes))
        XCTAssertEqual(restored.plan.courses.map(\.finish), original.plan.courses.map(\.finish))
        XCTAssertEqual(restored.plan.fixed.map(\.event), original.plan.fixed.map(\.event))
        XCTAssertEqual(restored.plan.fixed.map(\.start), original.plan.fixed.map(\.start))
        XCTAssertEqual(restored.plan.fixed.map(\.end), original.plan.fixed.map(\.end))
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testInMemoryModeNeverTouchesDisk() throws {
        let url = temporaryURL()
        let original = try makeSnapshot()
        let repository = CompressedScheduleRepository(inMemory: true, url: url)
        try repository.save(original)
        let restored = try XCTUnwrap(repository.load())
        XCTAssertEqual(restored.plan.finish, original.plan.finish)
        XCTAssertEqual(restored.plan.tasks, original.plan.tasks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertNil(try CompressedScheduleRepository(inMemory: true, url: url).load())
    }

    func testMissingCacheFileReturnsNil() throws {
        let url = temporaryURL()
        XCTAssertNil(try CompressedScheduleRepository(url: url).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnsupportedVersionThrows() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CompressedScheduleRepository(url: url).save(try makeSnapshot())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try CompressedScheduleRepository(url: url).load())
    }

    func testCorruptJSONThrows() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a compressed snapshot".utf8).write(to: url)
        XCTAssertThrowsError(try CompressedScheduleRepository(url: url).load())
    }
}

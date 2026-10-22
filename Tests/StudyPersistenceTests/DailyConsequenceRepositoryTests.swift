import XCTest
import StudyCore
@testable import StudyPersistence

final class DailyConsequenceRepositoryTests: XCTestCase {
    func testJournalAndActualStudyDatesSurviveReloadWithPrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let calendar = Calendar.current, now = calendar.startOfDay(for: Date()).addingTimeInterval(8 * 3600)
        var state = PlannerState()
        state.courses = [.init(name: "模拟课程", totalMinutes: 120, startDate: now, deadline: now.addingTimeInterval(86400))]
        let plan = state.replan(now: now)
        try state.confirm(taskID: plan.tasks[0].id, actualMinutes: 30, now: now)
        let entry = DailyConsequenceAnalyzer().capture(state: state, result: state.replan(now: now), now: now, warningMinutes: 480)
        var journal = DailyConsequenceJournal(); journal.days = [entry]
        let writer = DailyConsequenceRepository(url: url)
        try await writer.save(journal, sequence: 1)
        let reader = DailyConsequenceRepository(url: url)
        let restored = try await reader.load()
        XCTAssertEqual(restored, journal)
        XCTAssertNotNil(restored.days[0].capturedRecords[0].studyDate)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testOlderSaveCannotOverwriteNewerJournal() async throws {
        let repository = DailyConsequenceRepository(inMemory: true)
        var newer = DailyConsequenceJournal()
        newer.days = [DailyConsequenceAnalyzer().capture(state: PlannerState(), result: ScheduleEngine().generate(state: PlannerState(), now: Date()), now: Date(), warningMinutes: 480)]
        try await repository.save(newer, sequence: 2)
        try await repository.save(DailyConsequenceJournal(), sequence: 1)
        let saved = try await repository.load()
        XCTAssertEqual(saved.days.count, 1)
    }
    func testCorruptHistoryIsNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let bad = Data("invalid journal".utf8); try bad.write(to: url)
        let repository = DailyConsequenceRepository(url: url)
        do { _ = try await repository.load(); XCTFail("Must reject corrupt history") } catch { }
        do { try await repository.save(DailyConsequenceJournal(), sequence: 1); XCTFail("Must preserve corrupt file") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }
}

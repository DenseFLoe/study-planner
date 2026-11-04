import XCTest
import StudyCore
@testable import StudyPersistence

final class MergedScheduleTransactionTests: XCTestCase {
    private func fixture() -> PlannerState {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        var state = PlannerState()
        state.courses = [Course(name: "Concurrent course", totalMinutes: 120, startDate: day, deadline: day, minimumBlockMinutes: 0)]
        state.settings.minimumScheduleUnit = 60
        state.settings.availability = [.init(weekday: calendar.component(.weekday, from: day), startMinute: 480, endMinute: 660)]
        _ = state.replan(now: Date())
        return state
    }
    func testConcurrentWindowAndBlockEditsDoNotSaveTwoPlans() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var local = baseline, remote = baseline
        local.settings.minimumScheduleUnit = 30
        _ = local.replan(now: Date())
        remote.settings.availability[0].startMinute = 780
        remote.settings.availability[0].endMinute = 960
        _ = remote.replan(now: Date())
        try repository.save(remote)
        let saved = try repository.saveChanges(local, from: baseline)
        XCTAssertEqual(saved.settings.minimumScheduleUnit, 30)
        XCTAssertEqual(saved.tasks.filter(\.isUnconfirmed).reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertTrue(saved.tasks.allSatisfy { Calendar.current.component(.hour, from: $0.start) >= 13 })
        XCTAssertEqual(try repository.loadLedger().materialize().tasks, saved.tasks)
        XCTAssertEqual(try repository.load().tasks, saved.tasks)
    }
    func testCourseConflictAfterDraftCheckRejectsAllChanges() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var local = baseline, remote = baseline
        local.courses[0].name = "Local name"
        local.courses[0] = try local.courses[0].mergingDraft(from: baseline.courses[0], into: baseline.courses[0])
        local.settings.notificationMinute = 1234
        remote.courses[0].name = "Remote name"
        try repository.save(remote)
        let before = try repository.loadLedger()
        XCTAssertThrowsError(try repository.saveChanges(local, from: baseline)) { XCTAssertTrue($0 is CourseEditError) }
        XCTAssertEqual(try repository.loadLedger().records, before.records)
        XCTAssertEqual(try repository.load().courses, remote.courses)
    }
    func testCourseSchedulingInputsConflictButDisjointDisplayFieldsMerge() throws {
        for conflict in [true, false] {
            let repository = try LocalRepository(inMemory: true)
            let baseline = fixture()
            try repository.save(baseline)
            var local = baseline, remote = baseline
            local.courses[0].totalMinutes = 180
            local.courses[0].notes = "Local notes"
            remote.courses[0].color = "green"
            if conflict { remote.courses[0].initialCompletedMinutes = 30 }
            try repository.save(remote)
            if conflict {
                XCTAssertThrowsError(try repository.saveChanges(local, from: baseline)) { XCTAssertTrue($0 is CourseEditError) }
            } else {
                let saved = try repository.saveChanges(local, from: baseline)
                XCTAssertEqual(saved.courses[0].totalMinutes, 180)
                XCTAssertEqual(saved.courses[0].notes, "Local notes")
                XCTAssertEqual(saved.courses[0].color, "green")
            }
        }
    }
    func testSameCourseEditIsIdempotentAndRemoteDeletionCannotResurrect() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var local = baseline
        local.courses[0].name = "Same name"
        try repository.save(local)
        XCTAssertEqual(try repository.saveChanges(local, from: baseline).courses, local.courses)
        var removed = local
        removed.removeCourse(id: local.courses[0].id)
        try repository.save(removed)
        XCTAssertThrowsError(try repository.saveChanges(local, from: baseline)) { XCTAssertTrue($0 is CourseEditError) }
        XCTAssertTrue(try repository.load().courses.isEmpty)
        XCTAssertEqual(try repository.saveChanges(local, from: removed).courses, local.courses, "Explicit restore remains available")
    }
}

extension MergedScheduleTransactionTests {
    func testSyncDuringCalculationRetriesWithoutHoldingTransactionLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("retry.store")
        let repository = try LocalRepository(url: url)
        let baseline = fixture()
        try repository.save(baseline)
        var attempts = 0
        let saved = try repository.update { state, ledger in
            attempts += 1
            if attempts == 1 {
                var remote = state
                remote.courses[0].notes = "Arrived during calculation"
                let incoming = remote
                let written = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    defer { written.signal() }
                    do { try LocalRepository.withExclusiveAccess { try LocalRepository(url: url).save(incoming) } }
                    catch { XCTFail("Remote write failed: \(error)") }
                }
                guard written.wait(timeout: .now() + 5) == .success else {
                    XCTFail("Schedule computation held the transaction lock")
                    throw CocoaError(.fileLocking)
                }
            }
            state.courses[0].color = "green"
            return state
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(saved.courses[0].notes, "Arrived during calculation")
        XCTAssertEqual(saved.courses[0].color, "green")
        XCTAssertEqual(try LocalRepository(url: url).load().courses, saved.courses)
    }
}

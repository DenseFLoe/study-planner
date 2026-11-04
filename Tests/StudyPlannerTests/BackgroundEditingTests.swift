import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class BackgroundEditingTests: XCTestCase {
    @MainActor func testStorageConflictRefreshesLatestStateWithoutPublishingRejectedDraft() async {
        let original = fixture()
        var latest = original
        latest.courses[0].notes = "另一端刚保存的备注"
        let errors: [Error] = [ConfirmationEditError.changed, CourseEditError.conflictingChanges,
                               FixedEventEditError.removalChanged]
        for error in errors {
            let repository = Repository()
            repository.saved = latest; repository.rejection = error
            let store = store(original, repository)
            let saved = await store.change(replan: false) { $0.courses[0].name = "未保存的输入" }
            XCTAssertFalse(saved)
            XCTAssertEqual(repository.saved, latest)
            XCTAssertEqual(store.state, latest)
            XCTAssertFalse(store.orderSaveBusy)
            XCTAssertTrue(store.errorMessage?.contains(error.localizedDescription) == true)
        }
    }
    @MainActor func testOccurrenceRestoreConflictIsVisibleWithoutLosingTheSkip() async {
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        var event = FixedEvent(title: "待恢复", startMinute: 540, endMinute: 600, startDate: day, endDate: day)
        event.excludedDates = [day]
        var original = PlannerState()
        original.fixedEvents = [event, .init(title: "新增占用", startMinute: 550, endMinute: 580, startDate: day, endDate: day)]
        let repository = Repository(), store = store(original, repository)
        await store.setEventSkipped(event, on: day, skipped: false)
        XCTAssertEqual(store.state, original); XCTAssertNil(repository.saved)
        XCTAssertTrue(store.errorMessage?.contains("本日安排未恢复") == true)
        XCTAssertNil(store.pendingEventConflicts)
        XCTAssertFalse(store.orderSaveBusy)
    }
    @MainActor func testStaleConfirmationAndUndoKeepCurrentProgress() async throws {
        let now = Date(), original = fixture(), task = try XCTUnwrap(original.tasks.first)
        var moved = original; let index = try XCTUnwrap(moved.tasks.firstIndex { $0.id == task.id })
        moved.tasks[index].start.addTimeInterval(60)
        let repository = Repository(), store = store(moved, repository)
        let confirmed = await store.confirm(task, minutes: 10, now: now)
        XCTAssertFalse(confirmed); XCTAssertEqual(store.state, moved); XCTAssertNil(repository.saved)

        var state = original; try state.confirm(taskID: task.id, actualMinutes: 10, now: now)
        let reviewed = try XCTUnwrap(state.tasks.first { $0.id == task.id })
        try state.undoConfirmation(taskID: task.id, now: now)
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now.addingTimeInterval(60))
        let undoStore = self.store(state, repository)
        let undone = await undoStore.undoConfirmation(reviewed)
        XCTAssertFalse(undone); XCTAssertEqual(undoStore.state, state); XCTAssertNil(repository.saved)
    }
    @MainActor func testStaleFixedEventDeletionDoesNotSaveOrRotateRecovery() async throws {
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        let reviewed = FixedEvent(title: "待删除规则", startMinute: 540, endMinute: 600, startDate: day, endDate: day)
        var current = PlannerState(), changed = reviewed; changed.notes = "另一端的新备注"; current.fixedEvents = [changed]
        let repository = Repository(), backups = PlannerBackupRepository(inMemory: true, limit: 1)
        let recovery = PlannerBackup(state: current, reason: "保留的恢复点")
        try await backups.save(recovery)
        let store = store(current, repository, backups: backups)
        let deleted = await store.deleteEvent(reviewed)
        XCTAssertFalse(deleted); XCTAssertEqual(store.state, current); XCTAssertNil(repository.saved)
        XCTAssertTrue(store.errorMessage?.contains("未执行删除") == true)
        let entries = try await backups.entries()
        XCTAssertEqual(entries.map(\.id), [recovery.id])
    }
    private final class Repository: PlannerRepository {
        var saved: PlannerState?
        var fails = false
        var rejection: Error?
        var holds = false
        @MainActor var resume: CheckedContinuation<Void, Never>?
        @MainActor var observer: CheckedContinuation<Void, Never>?
        func load() throws -> PlannerState { saved ?? PlannerState() }
        func save(_ state: PlannerState) throws {
            if let rejection { throw rejection }
            if fails { throw CocoaError(.fileWriteUnknown) }
            saved = state
        }
        @MainActor func saveForInteraction(_ state: PlannerState) async throws {
            if holds { await withCheckedContinuation { resume = $0; observer?.resume(); observer = nil } }
            try save(state)
        }
        @MainActor func waitForSave() async {
            if resume == nil { await withCheckedContinuation { observer = $0 } }
        }
    }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        state.courses = [Course(name: "课程 A", totalMinutes: 120, startDate: day, deadline: day.addingTimeInterval(86400 * 3)),
                         Course(name: "课程 B", totalMinutes: 60, startDate: day, deadline: day.addingTimeInterval(86400 * 3))]
        _ = state.replan(now: day)
        return state
    }
    @MainActor private func store(_ state: PlannerState, _ repo: Repository, backups: PlannerBackupRepository = .init(inMemory: true)) -> PlannerStore {
        PlannerStore(state: state, repository: repo, result: ScheduleEngine().assessSavedPlan(state: state, now: Date()), backups: backups)
    }

    @MainActor func testDisplayOnlyEditPreservesEveryTaskAndSettings() async {
        let original = fixture(), repo = Repository()
        let store = store(original, repo)
        var edited = original.courses[0]
        edited.name = "改名"; edited.notes = "新备注"; edited.color = "green"
        let saved = await store.saveCourse(edited)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.state.tasks, original.tasks)
        XCTAssertEqual(store.state.settings, original.settings)
        XCTAssertEqual(store.state.completions, original.completions)
        XCTAssertEqual(store.state.courses[0], edited)
        XCTAssertEqual(repo.saved, store.state)
        edited.totalMinutes += 60
        let rescheduled = await store.saveCourse(edited)
        XCTAssertTrue(rescheduled)
        XCTAssertEqual(store.result.tasks.filter { $0.courseID == edited.id }.reduce(0) { $0 + $1.durationMinutes }, 180)
    }

    @MainActor func testSlowFailedSaveKeepsUIResponsiveAndOldStateIntact() async {
        let original = fixture(), repo = Repository()
        repo.holds = true; repo.fails = true
        let store = store(original, repo)
        var edited = original.courses[0]; edited.name = "未保存的名称"
        let operation = Task { await store.saveCourse(edited) }
        await repo.waitForSave()
        // This main-actor assertion runs while disk work is suspended.
        XCTAssertTrue(store.orderSaveBusy)
        XCTAssertEqual(store.state, original)
        let competing = await store.change { $0.courses.removeAll() }
        XCTAssertFalse(competing)
        repo.resume?.resume()
        let success = await operation.value
        XCTAssertFalse(success)
        XCTAssertFalse(store.orderSaveBusy)
        XCTAssertEqual(store.state, original)
        XCTAssertNil(repo.saved)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.backupEntries.count, 1)
    }

    @MainActor func testUndoDeletionRestoresHistoryAndKeepsLaterEdits() async throws {
        var original = fixture()
        let task = try XCTUnwrap(original.tasks.first { $0.courseID == original.courses[0].id })
        try original.confirm(taskID: task.id, actualMinutes: task.durationMinutes, now: task.end)
        let store = store(original, Repository())
        let deleted = await store.deleteCourse(original.courses[0])
        XCTAssertTrue(deleted)
        let backup = try XCTUnwrap(store.latestDeletedCourse)
        var other = original.courses[1]; other.name = "后来修改 B"
        let edited = await store.saveCourse(other)
        XCTAssertTrue(edited)
        let restored = await store.undoCourseDeletion(backup.id)
        XCTAssertTrue(restored)
        XCTAssertEqual(store.course(other.id)?.name, other.name)
        XCTAssertEqual(store.course(original.courses[0].id), original.courses[0])
        XCTAssertEqual(store.state.completions, original.completions)
        XCTAssertEqual(store.state.tasks.first { $0.id == task.id }, original.tasks.first { $0.id == task.id })
        XCTAssertNil(store.latestDeletedCourse)
        let repeated = await store.undoCourseDeletion(backup.id)
        XCTAssertFalse(repeated)
    }

    @MainActor func testRestorePreservesPreRestoreBackupAndFailedWriteDoesNotReplaceState() async throws {
        let original = fixture(), repo = Repository()
        let store = store(original, repo)
        var replacement = original; replacement.courses[0].name = "备份中的名称"
        let backup = PlannerBackup(state: replacement, reason: "测试")
        repo.fails = true
        let failed = await store.restoreBackup(backup, from: original)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.state, original)
        repo.fails = false
        let success = await store.restoreBackup(backup, from: original)
        XCTAssertTrue(success)
        XCTAssertEqual(store.state, replacement)
        let entry = try XCTUnwrap(store.backupEntries.first)
        let before = try await store.backups.load(entry.id)
        XCTAssertEqual(before.state, original)
        var invalid = backup; invalid.format = 99
        let rejected = await store.restoreBackup(invalid, from: replacement)
        XCTAssertFalse(rejected)
        XCTAssertEqual(store.state, replacement)
    }

    @MainActor func testBackupFailurePreventsDestructiveSave() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = fixture(), repo = Repository()
        let store = store(original, repo, backups: .init(directory: url))
        let success = await store.deleteCourse(original.courses[0])
        XCTAssertFalse(success)
        XCTAssertEqual(store.state, original)
        XCTAssertNil(repo.saved)
    }

    @MainActor func testStaleBackupReviewPreservesNewEditsAndRecoveryPoint() async throws {
        let original = fixture(), repo = Repository()
        let backups = PlannerBackupRepository(inMemory: true, limit: 1)
        let store = store(original, repo, backups: backups)
        let reviewed = store.state
        var replacement = original; replacement.courses[0].name = "旧备份课程"
        let backup = PlannerBackup(state: replacement, reason: "待恢复")
        var edited = original.courses[0]; edited.notes = "核对备份期间收到的新备注"
        let editSaved = await store.saveCourse(edited)
        XCTAssertTrue(editSaved)
        let current = store.state, saved = repo.saved
        let entries = try await backups.entries()

        let restored = await store.restoreBackup(backup, from: reviewed)

        XCTAssertFalse(restored)
        XCTAssertEqual(store.state, current)
        XCTAssertEqual(repo.saved, saved)
        XCTAssertFalse(store.orderSaveBusy)
        XCTAssertTrue(store.errorMessage?.contains("核对备份期间") == true)
        let after = try await backups.entries()
        XCTAssertEqual(after.map(\.id), entries.map(\.id), "Rejected restore must not replace the earlier recovery point")
        let freshReview = store.state
        let retried = await store.restoreBackup(backup, from: freshReview)
        XCTAssertTrue(retried)
        XCTAssertEqual(store.state, replacement)
        let recovery = try XCTUnwrap(store.backupEntries.first)
        let beforeRestore = try await backups.load(recovery.id)
        XCTAssertEqual(beforeRestore.state, current)
    }

    @MainActor func testStaleBackupReviewDoesNotEraseNewConfirmation() async throws {
        let original = fixture(), repo = Repository()
        let store = store(original, repo)
        let reviewed = store.state
        let task = try XCTUnwrap(original.tasks.first)
        let confirmed = await store.change(replan: false) { state in
            try state.confirm(taskID: task.id, actualMinutes: 20, now: task.end)
        }
        XCTAssertTrue(confirmed)
        let records = store.state.completions

        let restored = await store.restoreBackup(PlannerBackup(state: original, reason: "旧备份"), from: reviewed)

        XCTAssertFalse(restored)
        XCTAssertEqual(store.state.completions, records)
        XCTAssertEqual(repo.saved?.completions, records)
    }

    @MainActor func testInvalidRestorePreservesTheOnlyOlderRecoveryPoint() async throws {
        let original = fixture(), repo = Repository()
        let backups = PlannerBackupRepository(inMemory: true, limit: 1)
        let recovery = PlannerBackup(state: original, reason: "保留的恢复点", now: Date().addingTimeInterval(-60))
        try await backups.save(recovery)
        let store = store(original, repo, backups: backups)
        await store.refreshBackups()
        let previousTasks = store.result.tasks
        var invalid = PlannerBackup(state: original, reason: "不支持的备份")
        invalid.format = 99

        let saved = await store.restoreBackup(invalid, from: original)

        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, original)
        XCTAssertEqual(store.result.tasks, previousTasks)
        XCTAssertNil(repo.saved)
        XCTAssertFalse(store.orderSaveBusy)
        XCTAssertNotNil(store.errorMessage)
        let entries = try await backups.entries()
        XCTAssertEqual(entries.map(\.id), [recovery.id])
        XCTAssertEqual(store.backupEntries.map(\.id), [recovery.id])
        let retained = try await backups.load(recovery.id)
        XCTAssertEqual(retained.state, original)
    }

    @MainActor func testConflictingEventPreservesTheOnlyOlderRecoveryPoint() async throws {
        let now = Date()
        let day = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        var original = fixture()
        original.fixedEvents = [.init(title: "原事项", startMinute: 600, endMinute: 660, startDate: day, endDate: day)]
        _ = original.replan(now: now)
        let repo = Repository(), backups = PlannerBackupRepository(inMemory: true, limit: 1)
        let recovery = PlannerBackup(state: original, reason: "保留的恢复点", now: now.addingTimeInterval(-60))
        try await backups.save(recovery)
        let store = store(original, repo, backups: backups)
        await store.refreshBackups()
        let previousTasks = store.result.tasks
        let conflicting = FixedEvent(title: "冲突事项", startMinute: 630, endMinute: 690, startDate: day, endDate: day)

        let saved = await store.saveEvent(conflicting)

        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, original)
        XCTAssertEqual(store.result.tasks, previousTasks)
        XCTAssertNil(repo.saved)
        XCTAssertFalse(store.orderSaveBusy)
        XCTAssertFalse(store.pendingEventConflicts?.isEmpty ?? true)
        let entries = try await backups.entries()
        XCTAssertEqual(entries.map(\.id), [recovery.id])
        XCTAssertEqual(store.backupEntries.map(\.id), [recovery.id])
        let retained = try await backups.load(recovery.id)
        XCTAssertEqual(retained.state, original)
    }

    @MainActor func testUndoDeletionSurvivesDiskReopeningAndSyncTombstones() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("planner.store")
        var original = fixture()
        let course = original.courses[0]
        let task = try XCTUnwrap(original.tasks.first { $0.courseID == course.id })
        try original.confirm(taskID: task.id, actualMinutes: task.durationMinutes, now: task.end)
        let repository = try LocalRepository(url: url)
        try repository.save(original)
        let backups = PlannerBackupRepository(directory: directory.appendingPathComponent("backups"))
        let first = PlannerStore(state: original, repository: repository,
                                 result: ScheduleEngine().assessSavedPlan(state: original, now: Date()), backups: backups)
        let deleted = await first.deleteCourse(course)
        XCTAssertTrue(deleted)
        let reopened = try LocalRepository(url: url)
        let state = try reopened.load()
        XCTAssertFalse(state.courses.contains { $0.id == course.id })
        let store = PlannerStore(state: state, repository: reopened,
                                 result: ScheduleEngine().assessSavedPlan(state: state, now: Date()), backups: backups)
        await store.refreshBackups()
        let entry = try XCTUnwrap(store.latestDeletedCourse)
        let restored = await store.undoCourseDeletion(entry.id)
        XCTAssertTrue(restored)
        let final = try LocalRepository(url: url)
        XCTAssertEqual(try final.load().completions, original.completions)
        XCTAssertEqual(try final.loadLedger().materialize().completions, original.completions)
        XCTAssertTrue(try final.loadLedger().materialize().courses.contains { $0.id == course.id })
    }
}

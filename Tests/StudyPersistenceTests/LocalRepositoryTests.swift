import XCTest
import StudyCore
import SwiftData
@testable import StudyPersistence

final class LocalRepositoryTests: XCTestCase {
    @MainActor func testFixedEventDeletionRejectsAChangeThatReachedDiskAfterReview() throws {
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        var original = PlannerState()
        let event = FixedEvent(title: "核对时的规则", startMinute: 540, endMinute: 600, startDate: day, endDate: day)
        original.fixedEvents = [event]
        let repository = try LocalRepository(inMemory: true)
        try repository.save(original)
        var edited = original; try edited.removeFixedEvent(reviewed: event); edited.settings.minimumScheduleUnit = 15
        var remote = original; remote.fixedEvents[0].notes = "稍后同步的新备注"
        try repository.save(remote)
        XCTAssertThrowsError(try repository.saveChanges(edited, from: original)) { error in
            guard case FixedEventEditError.removalChanged = error else { return XCTFail("Wrong conflict: \(error)") }
        }
        XCTAssertEqual(try repository.load(), remote)
        var fresh = remote; try fresh.removeFixedEvent(reviewed: remote.fixedEvents[0])
        let saved = try repository.saveChanges(fresh, from: remote)
        XCTAssertTrue(saved.fixedEvents.isEmpty)
        XCTAssertEqual(saved.settings, remote.settings)
    }
    @MainActor func testDeletedFixedEventStaysAbsentAfterDiskReopenAndStaleSync() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixed-deletion.store")
        let repository = try LocalRepository(url: url)
        let day = Calendar.current.startOfDay(for: Date())
        let event = FixedEvent(title: "删除整条课表", startMinute: 480, endMinute: 600,
                               startDate: day.addingTimeInterval(-7 * 86400),
                               endDate: day.addingTimeInterval(7 * 86400), weekdays: Set(1...7))
        var baseline = PlannerState()
        baseline.fixedEvents = [event]
        try repository.save(baseline)
        let staleRows = try repository.loadLedger().changes(after: 0)
        var edited = baseline
        edited.removeFixedEvent(id: event.id)
        XCTAssertTrue(try repository.saveChanges(edited, from: baseline).fixedEvents.isEmpty)
        let reopened = try LocalRepository(url: url)
        XCTAssertTrue(try reopened.load().fixedEvents.isEmpty)
        var ledger = try reopened.loadLedger()
        XCTAssertEqual(ledger.records["fixedEvents/" + event.id.uuidString]?.deleted, true)
        try ledger.merge(staleRows)
        XCTAssertTrue(try ledger.materialize().fixedEvents.isEmpty)
        var peer = SyncLedger()
        try peer.merge(staleRows)
        try peer.merge(ledger.changes(after: 0))
        XCTAssertTrue(try peer.materialize().fixedEvents.isEmpty)
    }

    @MainActor func testSavingWithoutRemoteChangesKeepsDisplayedOrder() throws {
        let repository = try LocalRepository(inMemory: true)
        let day = Date()
        var baseline = PlannerState()
        baseline.courses = (0..<8).map { Course(name: "课程\($0)", totalMinutes: 60, startDate: day, deadline: day) }
        baseline.tasks = baseline.courses.enumerated().map {
            ScheduledTask(courseID: $0.element.id, start: day.addingTimeInterval(Double($0.offset) * 3600), durationMinutes: 60)
        }
        try repository.save(baseline)
        var edited = baseline
        edited.courses[0].name = "已编辑"
        let saved = try repository.saveChanges(edited, from: baseline)
        XCTAssertEqual(saved, edited)
    }

    @MainActor func testSavingDisplayedEditsPreservesUnseenRemoteChangesAndLedgerProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("concurrent.store")
        let local = try LocalRepository(url: url)
        let day = Date()
        var baseline = PlannerState()
        baseline.courses = [Course(name: "本地待删除", totalMinutes: 60, startDate: day, deadline: day),
                            Course(name: "远端待编辑", totalMinutes: 60, startDate: day, deadline: day)]
        try local.save(baseline)
        _ = try local.load() // Cache rows before the other context commits.
        let remote = try LocalRepository(url: url)
        var incoming = baseline
        incoming.courses[1].name = "远端已编辑"
        incoming.courses.append(Course(name: "远端新增", totalMinutes: 60, startDate: day, deadline: day))
        incoming.settings.minimumScheduleUnit = 30
        var progress = try remote.loadLedger()
        progress.peerCursor = 123
        try remote.save(incoming, ledger: progress)
        var edited = baseline
        edited.courses[1].dailyStudyWeight = 2
        edited.settings.notificationMinute = 1200
        edited.removeCourse(id: baseline.courses[0].id)
        let saved = try local.saveChanges(edited, from: baseline)
        XCTAssertEqual(Set(saved.courses.map(\.name)), ["远端已编辑", "远端新增"])
        XCTAssertEqual(saved.settings.minimumScheduleUnit, 30)
        XCTAssertEqual(saved.settings.notificationMinute, 1200)
        XCTAssertEqual(saved.courses.first { $0.id == baseline.courses[1].id }?.dailyStudyWeight, 2)
        let reopened = try LocalRepository(url: url)
        XCTAssertEqual(Set(try reopened.load().courses.map(\.name)), ["远端已编辑", "远端新增"])
        let ledger = try reopened.loadLedger()
        XCTAssertEqual(ledger.peerCursor, 123)
        XCTAssertEqual(ledger.records["courses/" + baseline.courses[0].id.uuidString]?.deleted, true)
        XCTAssertEqual(Set(try ledger.materialize().courses.map(\.name)), ["远端已编辑", "远端新增"])
    }

    @MainActor func testFailedBackgroundSavesDiscardCachedRowsBeforeReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conflict-refresh.store")
        let local = try LocalRepository(url: url), day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        var baseline = PlannerState()
        baseline.courses = [Course(name: "原课程", totalMinutes: 60, startDate: day, deadline: day)]
        baseline.fixedEvents = [.init(title: "原事项", startMinute: 540, endMinute: 600, startDate: day, endDate: day)]
        try local.save(baseline)
        _ = try local.load()
        let remote = try LocalRepository(url: url)
        var incoming = baseline; incoming.courses[0].name = "远端课程"
        try remote.save(incoming)
        var edited = baseline; edited.courses[0].name = "本地冲突名称"
        do {
            _ = try await local.saveChangesForInteraction(edited, from: baseline)
            XCTFail("A stale conflicting course edit must be rejected")
        } catch { XCTAssertTrue(error is CourseEditError) }
        XCTAssertEqual(try local.load().courses, incoming.courses)

        incoming.fixedEvents[0].title = "远端事项"
        try remote.save(incoming)
        var event = baseline.fixedEvents[0]; event.title = "本地冲突事项"
        do {
            _ = try await local.saveFixedEventForInteraction(.init(event: event, baseline: baseline.fixedEvents[0]),
                                                             from: baseline, now: Date())
            XCTFail("A stale conflicting event edit must be rejected")
        } catch { XCTAssertTrue(error is FixedEventEditError) }
        XCTAssertEqual(try local.load().fixedEvents, incoming.fixedEvents)
        XCTAssertEqual(try LocalRepository(url: url).load().courses, incoming.courses)
    }

    @MainActor func testBackgroundInteractionSaveMergesConfirmationWithRemoteAddition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("confirm.store")
        let local = try LocalRepository(url: url)
        var baseline = PlannerState()
        let day = Date()
        let course = Course(name: "确认进度", totalMinutes: 60, startDate: day, deadline: day)
        baseline.courses = [course]
        let task = ScheduledTask(courseID: course.id, start: day, durationMinutes: 60)
        baseline.tasks = [task]
        try local.save(baseline)
        var incoming = baseline
        incoming.courses.append(Course(name: "云端新增", totalMinutes: 60, startDate: day, deadline: day))
        try LocalRepository(url: url).save(incoming)
        var edited = baseline
        try edited.confirm(taskID: task.id, actualMinutes: 30, now: task.end)
        let saved = try await local.saveChangesForInteraction(edited, from: baseline)
        XCTAssertEqual(saved.completedMinutes(for: course), 30)
        XCTAssertEqual(Set(saved.courses.map(\.name)), ["确认进度", "云端新增"])
        let reopened = try LocalRepository(url: url)
        XCTAssertEqual(try reopened.load().completedMinutes(for: course), 30)
        XCTAssertEqual(try reopened.loadLedger().materialize().completedMinutes(for: course), 30)
    }

    @MainActor func testSplitImmediateRequestSurvivesDiskAndSyncLedgerRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("immediate.store")
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let now = ScheduleEngine().instant(day: day, minute: 480)
        var state = PlannerState()
        var course = Course(name: "分段学习", totalMinutes: 120, startDate: day,
                            deadline: calendar.date(byAdding: .day, value: 2, to: day)!)
        course.type = .lessonBasedRecorded
        course.manualLessons = [.init(id: "earlier", name: "第一节", durationMinutes: 30),
                                .init(id: "selected", name: "第二节", durationMinutes: 90)]
        state.courses = [course]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 540) }
        _ = try state.studyImmediately(courseID: course.id, lessonID: "selected", now: now)
        do { try LocalRepository(url: url).save(state) }
        let reopened = try LocalRepository(url: url)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.settings, state.settings)
        XCTAssertEqual(loaded.settings.immediateStudy?.continuesLesson, true)
        XCTAssertEqual(loaded.tasks, state.tasks)
        XCTAssertEqual(loaded.immediateStudyContinuation(now: now)?.id, "selected")
        let peer = try reopened.loadLedger().materialize()
        XCTAssertEqual(peer.settings, loaded.settings)
        XCTAssertEqual(Set(peer.tasks.map(\.id)), Set(loaded.tasks.map(\.id)))
        XCTAssertEqual(peer.remainingMinutes(for: course), 120)
        XCTAssertTrue(peer.completions.isEmpty)
    }

    @MainActor func testBackgroundSaveRefreshesContextBeforeNextTransaction() async throws {
        let repo = try LocalRepository(inMemory: true)
        var state = PlannerState()
        let day = Calendar.current.startOfDay(for: Date())
        let course = Course(name: "课程", totalMinutes: 120, startDate: day, deadline: day)
        state.courses = [course]
        state.tasks = [.init(courseID: course.id, start: day.addingTimeInterval(8 * 3600), durationMinutes: 60)]
        try repo.save(state)
        _ = try repo.load() // Register old rows in the UI context.
        state.tasks[0].start = day.addingTimeInterval(10 * 3600)
        state.settings.minimumScheduleUnit = 30
        try await repo.saveForInteraction(state)
        XCTAssertEqual(try repo.load(), state)
        let sequence = try repo.loadLedger().sequence
        try repo.save(state)
        XCTAssertEqual(try repo.loadLedger().sequence, sequence)
        state.tasks[0].durationMinutes = 30
        try repo.save(state)
        XCTAssertEqual(try repo.load(), state)
    }

    @MainActor func testLegacyCourseDeletionIsCleanedOnLoadAndPersistsAfterReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.store")
        var state = PlannerState()
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var removed = Course(name: "旧删除课程", totalMinutes: 120, startDate: day, deadline: day)
        let kept = Course(name: "保留课程", totalMinutes: 60, startDate: day, deadline: day)
        state.courses = [removed, kept]
        for course in state.courses {
            let task = ScheduledTask(courseID: course.id, start: day, durationMinutes: 60)
            state.tasks.append(task)
            try state.confirm(taskID: task.id, actualMinutes: 30, now: task.end)
        }
        do { let repo = try LocalRepository(url: url); try repo.save(state) }
        // Seed the archive flag exactly as the earlier application persisted it.
        removed.isArchived = true
        do {
            let container = try ModelContainer(for: LocalRecord.self, configurations: ModelConfiguration("StudyPlanner", url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<LocalRecord>()).first { $0.key == "course/\(removed.id)" })
            row.payload = try JSONEncoder().encode(removed)
            try context.save()
        }
        var expected = state
        expected.removeCourse(id: removed.id)
        do {
            let repo = try LocalRepository(url: url)
            let loaded = try repo.load()
            XCTAssertEqual(loaded, expected)
            try repo.save(loaded)
        }
        let reopened = try LocalRepository(url: url)
        XCTAssertEqual(try reopened.load(), expected)
        let ledger = try reopened.loadLedger()
        XCTAssertEqual(ledger.records["courses/" + removed.id.uuidString]?.deleted, true)
        XCTAssertEqual(try ledger.materialize(), expected)
    }

    @MainActor func testFloatingEventsAndTaskWindowsSurviveReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("floating.store")
        let day = Calendar.current.startOfDay(for: Date())
        var state = PlannerState()
        let course = Course(name: "浮动学习", totalMinutes: 60, startDate: day, deadline: day)
        state.courses = [course]
        var event = FixedEvent(title: "杂务", startMinute: 840, endMinute: 1080, startDate: day, endDate: day)
        event.floatingDurationMinutes = 60
        state.fixedEvents = [event]
        try state.setFixedEventSkipped(id: event.id, on: day, skipped: true, now: day)
        event = state.fixedEvents[0]
        var task = ScheduledTask(courseID: course.id, start: day.addingTimeInterval(840 * 60), durationMinutes: 60)
        task.floatingWindowStart = task.start
        task.floatingWindowEnd = day.addingTimeInterval(1080 * 60)
        state.tasks = [task]
        do { let repo = try LocalRepository(url: url); try repo.save(state) }
        let loaded = try LocalRepository(url: url).load()
        XCTAssertEqual(loaded.fixedEvents, [event])
        XCTAssertFalse(loaded.fixedEvents[0].occurs(on: day, calendar: .current))
        XCTAssertEqual(loaded.tasks, [task])
    }

    @MainActor func testDiskRoundTripAndReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("planner.store")
        var state = PlannerState()
        state.courses = [.init(name: "数学", totalMinutes: 600, startDate: Date(), deadline: Date().addingTimeInterval(86400 * 10))]
        try state.recordActualStudyStart(minute: 630, now: Date())
        _ = state.replan(now: Date())
        let task = try XCTUnwrap(state.tasks.first)
        try state.confirm(taskID: task.id, actualMinutes: 30, now: Date())
        do { let repo = try LocalRepository(url: url); try repo.save(state) }
        let reopened = try LocalRepository(url: url)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.courses, state.courses)
        XCTAssertEqual(Set(loaded.tasks.map(\.id)), Set(state.tasks.map(\.id)))
        XCTAssertEqual(loaded.completions, state.completions)
        XCTAssertEqual(loaded.settings, state.settings)
        state.tasks.removeAll { $0.isUnconfirmed }
        try reopened.save(state)
        XCTAssertEqual(try reopened.load().tasks.count, 1)
        try reopened.save(state)
        XCTAssertEqual(try reopened.load().completions.count, 1)
    }
}

extension LocalRepositoryTests {
    func testLedgerTombstonesAndAutomaticDatePersistTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.store")
        let db = try LocalRepository(url: url)
        var s = PlannerState(); s.settings.availability = []
        s.courses = [.init(name: "离线课程", totalMinutes: 60, startDate: Date(), deadline: Date())]
        try db.save(s); let id = s.courses[0].id.uuidString
        s.courses.removeAll(); try db.save(s)
        var ledger = try db.loadLedger(); ledger.lastAutoDate = "2026-09-19"; ledger.peerCursor = 123
        try db.save(s, ledger: ledger)
        let reopened = try LocalRepository(url: url)
        XCTAssertTrue(try reopened.load().courses.isEmpty)
        XCTAssertEqual(try reopened.loadLedger().records["courses/" + id]?.deleted, true)
        XCTAssertEqual(try reopened.loadLedger().lastAutoDate, "2026-09-19")
        XCTAssertEqual(try reopened.loadLedger().peerCursor, 123)
        let sequence = ledger.sequence
        var invalid = try XCTUnwrap(ledger.records["courses/" + id]); invalid.version += 100; invalid.deleted = false; invalid.payload = Data("broken".utf8)
        try ledger.merge([invalid])
        XCTAssertThrowsError(try ledger.materialize())
        XCTAssertEqual(try reopened.loadLedger().sequence, sequence)
        XCTAssertTrue(try reopened.load().courses.isEmpty)
    }
}

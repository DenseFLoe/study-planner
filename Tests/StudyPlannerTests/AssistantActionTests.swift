import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class AssistantActionTests: XCTestCase {
    private func proposal(_ name: String, _ input: [String: String], _ snapshot: AssistantSnapshot = AssistantSimulation.snapshot()) throws -> AssistantChange {
        let (evidence, change) = try AssistantActions.execute(name: name, input: input, snapshot: snapshot, id: "E1")
        XCTAssertTrue(evidence.json.contains("awaiting_local_confirmation"), name)
        return try XCTUnwrap(change)
    }
    func testCourseAddEditDeleteAndReplanAreOnlyPreviews() throws {
        let s = AssistantSimulation.snapshot(), original = s.state
        let add = try proposal("preview_add_course", ["name": "数学", "total_minutes": "180", "start_date": "2026-09-14", "deadline": "2026-09-18", "minimum_block": "30"], s)
        XCTAssertEqual(add.after.courses.count, original.courses.count + 1)
        XCTAssertEqual(add.after.courses.last?.name, "数学")
        let edit = try proposal("preview_edit_course", ["course": AssistantSimulation.courseID.uuidString, "field": "deadline", "value": "2026-09-20"], s)
        XCTAssertEqual(edit.after.courses.first?.deadline, try s.date("2026-09-20"))
        let deletion = try proposal("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString], s)
        XCTAssertTrue(deletion.after.courses.isEmpty)
        XCTAssertTrue(deletion.after.tasks.isEmpty)
        XCTAssertTrue(deletion.summary.contains("删除 1"))
        XCTAssertTrue(deletion.title.contains("学习记录"))
        var unplanned = s.state; unplanned.tasks = []
        let replan = try proposal("preview_replan", [:], .init(state: unplanned, now: s.now, calendar: s.calendar))
        XCTAssertEqual(replan.after.courses, original.courses)
        XCTAssertEqual(replan.after.completions, original.completions)
        XCTAssertEqual(s.state, original)
    }
    func testTaskSwapUsesExistingRulesAndKeepsHistory() throws {
        let s = AssistantSimulation.snapshot(), day = s.calendar.startOfDay(for: s.now)
        var state = PlannerState()
        state.courses = (0..<2).map { Course(name: "排序课程\($0)", totalMinutes: 60, startDate: day, deadline: day) }
        state.settings.availability = [.init(weekday: s.calendar.component(.weekday, from: day), startMinute: 480, endMinute: 720)]
        _ = state.replan(now: day, calendar: s.calendar)
        XCTAssertEqual(state.tasks.count, 2)
        let first = state.tasks[0], second = state.tasks[1]
        let change = try proposal("preview_swap_tasks", ["source": first.id.uuidString, "target": second.id.uuidString], .init(state: state, now: day, calendar: s.calendar))
        XCTAssertEqual(change.after.tasks.sorted { $0.start < $1.start }.first?.id, second.id)
        XCTAssertEqual(change.after.courses, state.courses)
        XCTAssertEqual(change.after.completions, state.completions)
        XCTAssertNotEqual(change.after.settings.dailyTaskOrders, state.settings.dailyTaskOrders)
        XCTAssertNil(try AssistantActions.execute(name: "preview_swap_tasks", input: ["source": first.id.uuidString, "target": first.id.uuidString], snapshot: s, id: "E1").1)
    }
    func testEventLifecycleAndConflictRejection() throws {
        let s = AssistantSimulation.snapshot()
        let args = ["title": "运动", "start_date": "2026-09-15", "end_date": "2026-09-15", "start_time": "18:00", "end_time": "19:00", "weekdays": ""]
        let add = try proposal("preview_add_event", args, s)
        let event = try XCTUnwrap(add.after.fixedEvents.first)
        let current = AssistantSnapshot(state: add.after, now: s.now, calendar: s.calendar)
        let edit = try proposal("preview_edit_event", ["event": event.id.uuidString, "field": "end_time", "value": "19:30"], current)
        XCTAssertEqual(edit.after.fixedEvents.first?.endMinute, 1170)
        let moved = try proposal("preview_edit_event", ["event": event.id.uuidString, "field": "start_date", "value": "2026-09-16"], current)
        XCTAssertEqual(moved.after.fixedEvents.first?.startDate, try s.date("2026-09-16"))
        XCTAssertEqual(moved.after.fixedEvents.first?.endDate, try s.date("2026-09-16"))
        let deletion = try proposal("preview_delete_event", ["event": event.id.uuidString], current)
        XCTAssertTrue(deletion.after.fixedEvents.isEmpty)
        let (error, rejected) = try AssistantActions.execute(name: "preview_add_event", input: args, snapshot: current, id: "E1")
        XCTAssertNil(rejected); XCTAssertTrue(error.json.contains("冲突"))
        XCTAssertEqual(current.state, add.after)
    }
    func testEventListingOmitsNotesAndRejectsSecretNames() throws {
        var state = AssistantSimulation.snapshot().state
        let s = AssistantSimulation.snapshot()
        var event = FixedEvent(title: "午休", startMinute: 720, endMinute: 750, startDate: s.now, endDate: s.now)
        event.notes = "private-note-never-send"
        state.fixedEvents = [event]
        let result = try AssistantActions.execute(name: "list_events", input: ["offset": "0"], snapshot: .init(state: state, now: s.now), id: "E1")
        XCTAssertNil(result.1); XCTAssertTrue(result.0.json.contains("午休")); XCTAssertFalse(result.0.json.contains(event.notes))
        state.fixedEvents[0].title = "password=" + "synthetic-only-fixture"
        XCTAssertThrowsError(try AssistantActions.execute(name: "list_events", input: ["offset": "0"], snapshot: .init(state: state, now: s.now), id: "E2"))
    }
    func testStrictFieldsInvalidValuesAndSingleProposal() throws {
        let s = AssistantSimulation.snapshot()
        for field in ["password", "key", "notes", "webCourse", "cloudEndpoint", "__proto__", "initialCompletedMinutes"] {
            let result = try AssistantActions.execute(name: "preview_edit_course", input: ["course": AssistantSimulation.courseID.uuidString, "field": field, "value": "anything"], snapshot: s, id: "E1")
            XCTAssertNil(result.1)
        }
        for (field, value) in [("deadline", "2026-02-30"), ("priority", "9999999999999999999999"), ("daily_weight", "nan"), ("auto_schedule", "yes"), ("total_minutes", "40"), ("name", "\n")] {
            XCTAssertNil(try AssistantActions.execute(name: "preview_edit_course", input: ["course": AssistantSimulation.courseID.uuidString, "field": field, "value": value], snapshot: s, id: "E1").1)
        }
        XCTAssertNil(try AssistantActions.execute(name: "preview_delete_course", input: ["course": AssistantSimulation.courseID.uuidString, "path": "/etc/passwd"], snapshot: s, id: "E1").1)
        XCTAssertNil(try AssistantActions.execute(name: "preview_replan", input: [:], snapshot: s, id: "E1", alreadyProposed: true).1)
        for name in ["read_file", "run_command", "read_keychain", "load_password", "apply_change", "undo_change"] {
            XCTAssertThrowsError(try AssistantActions.execute(name: name, input: [:], snapshot: s, id: "E1"))
        }
        XCTAssertThrowsError(try AssistantActions.execute(name: "preview_edit_course", input: ["course": AssistantSimulation.courseID.uuidString, "field": "name", "value": "api_key=" + "synthetic-fixture-value"], snapshot: s, id: "E1"))
    }
    func testPreviewExpiresAndRejectsRevisionTimeZoneAndTaskBoundaryChanges() throws {
        let s = AssistantSimulation.snapshot()
        let p = try proposal("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString], s)
        XCTAssertNoThrow(try p.validate(snapshot: s, now: s.now))
        XCTAssertThrowsError(try p.validate(snapshot: s, now: p.expiresAt))
        XCTAssertThrowsError(try p.validate(snapshot: .init(state: s.state, now: s.now, calendar: s.calendar, id: "changed"), now: s.now))
        var state = s.state
        state.tasks = [ScheduledTask(courseID: AssistantSimulation.courseID, start: s.now.addingTimeInterval(60), durationMinutes: 60)]
        let boundary = AssistantSnapshot(state: state, now: s.now, calendar: s.calendar)
        let b = try proposal("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString], boundary)
        XCTAssertThrowsError(try b.validate(snapshot: boundary, now: s.now.addingTimeInterval(61)))
        var calendar = s.calendar; calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertThrowsError(try p.validate(snapshot: .init(state: s.state, now: s.now, calendar: calendar, id: s.id), now: s.now))
    }
    func testDeleteIncludesCompletionsAndKeepsUnrelatedCourse() throws {
        let s = AssistantSimulation.snapshot()
        var state = s.state
        let task = try XCTUnwrap(state.tasks.first)
        try state.confirm(taskID: task.id, actualMinutes: 30, now: task.end)
        state.courses.append(Course(name: "保留课程", totalMinutes: 60, startDate: s.now, deadline: s.now))
        let p = try proposal("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString], .init(state: state, now: s.now, calendar: s.calendar))
        XCTAssertEqual(p.before.completions.count, 1); XCTAssertTrue(p.after.completions.isEmpty)
        XCTAssertEqual(p.after.courses.map(\.name), ["保留课程"])
        XCTAssertTrue(p.details.contains { $0.contains("删除学习记录") })
    }

    @MainActor func testStoreTransactionBacksUpAppliesAndUndoesExactPreview() async throws {
        let repository = try LocalRepository(inMemory: true), s = AssistantSimulation.snapshot()
        try repository.save(s.state)
        let initial = try repository.load()
        let store = PlannerStore(state: initial, repository: repository, result: ScheduleEngine().assessSavedPlan(state: initial, now: s.now))
        let p = try proposal("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString], .init(state: initial, now: s.now, calendar: s.calendar))
        let saved = await store.applyAssistantChange(p.after, from: p.before)
        XCTAssertNotNil(saved); XCTAssertTrue(store.state.courses.isEmpty)
        XCTAssertFalse(store.backupEntries.isEmpty)
        let undone = await store.applyAssistantChange(p.before, from: store.state)
        XCTAssertNotNil(undone)
        XCTAssertEqual(store.state.courses, initial.courses)
        XCTAssertEqual(Set(store.state.tasks.map(\.id)), Set(initial.tasks.map(\.id)))
        XCTAssertEqual(try repository.load(), store.state)
    }
    @MainActor func testConcurrentDiskEditCannotBeOverwrittenByApplyOrUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("planner.store")
        let repo = try LocalRepository(url: url), s = AssistantSimulation.snapshot()
        try repo.save(s.state)
        let original = try repo.load()
        let store = PlannerStore(state: original, repository: repo, result: ScheduleEngine().assessSavedPlan(state: original, now: s.now))
        let p = try proposal("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString], .init(state: original, now: s.now, calendar: s.calendar))
        let peer = try LocalRepository(url: url)
        var newer = original; newer.courses[0].name = "另一个窗口的新名称"
        _ = try peer.saveChanges(newer, from: original)
        let applied = await store.applyAssistantChange(p.after, from: p.before)
        XCTAssertNil(applied)
        XCTAssertEqual(try peer.load().courses[0].name, newer.courses[0].name)
        let staleUndo = await store.applyAssistantChange(original, from: p.after)
        XCTAssertNil(staleUndo)
        XCTAssertEqual(try peer.load().courses[0].name, newer.courses[0].name)
    }
    private final class FailingRepository: PlannerRepository {
        let state: PlannerState
        init(_ state: PlannerState) { self.state = state }
        func load() throws -> PlannerState { state }
        func save(_ state: PlannerState) throws { throw CocoaError(.fileWriteUnknown) }
    }
    @MainActor func testWriteFailurePreservesState() async throws {
        let s = AssistantSimulation.snapshot(), repo = FailingRepository(AssistantSimulation.snapshot().state)
        let store = PlannerStore(state: s.state, repository: repo, result: ScheduleEngine().assessSavedPlan(state: s.state, now: s.now))
        let p = try proposal("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString], s)
        let applied = await store.applyAssistantChange(p.after, from: s.state)
        XCTAssertNil(applied); XCTAssertEqual(store.state, s.state)
    }
    @MainActor func testExpiredTransactionAndBackupFailureNeverWrite() async throws {
        let s = AssistantSimulation.snapshot(), repo = try LocalRepository(inMemory: true)
        try repo.save(s.state)
        let before = try repo.load()
        let normal = PlannerStore(state: before, repository: repo, result: ScheduleEngine().assessSavedPlan(state: before, now: s.now))
        let expired = await normal.applyAssistantChange(PlannerState(), from: before, validUntil: Date.distantPast)
        XCTAssertNil(expired); XCTAssertEqual(try repo.load(), before)
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let brokenBackups = PlannerBackupRepository(directory: blocker)
        let store = PlannerStore(state: before, repository: repo, result: ScheduleEngine().assessSavedPlan(state: before, now: s.now), backups: brokenBackups)
        let failed = await store.applyAssistantChange(PlannerState(), from: before)
        XCTAssertNil(failed); XCTAssertEqual(store.state, before); XCTAssertEqual(try repo.load(), before)
    }

    @MainActor private func finish(_ session: AssistantSession, allow: Bool = true) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while session.busy {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out"); throw AssistantError.protocolError }
            if let approval = session.approval { session.decide(approval.id, allow: allow) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor func testSessionRequiresSeparateConfirmationAndCanUndo() async throws {
        try await AssistantSimulation.actionProbe()
    }
    @MainActor func testRefusingSendingCancellingProposalAndClosingNeverWrite() async throws {
        for mode in ["refuse", "cancel", "close", "new"] {
            let (session, store) = try AssistantSimulation.actionSession()
            let before = store.state
            session.send(); try await finish(session, allow: mode != "refuse")
            if mode == "refuse" { XCTAssertNil(session.pendingChange) }
            else {
                let id = try XCTUnwrap(session.pendingChange?.id)
                switch mode {
                case "cancel": session.dismissChange(id)
                case "close": session.close()
                default: session.newConversation()
                }
                await session.confirmChange(id)
            }
            XCTAssertNil(session.pendingChange); XCTAssertNil(session.undoChange)
            XCTAssertEqual(store.state, before); XCTAssertTrue(store.backupEntries.isEmpty)
        }
    }
    @MainActor func testStaleConfirmationAndStaleUndoPreserveNewEdits() async throws {
        let (session, store) = try AssistantSimulation.actionSession()
        session.send(); try await finish(session)
        let oldID = try XCTUnwrap(session.pendingChange?.id)
        var course = store.state.courses[0]; course.name = "手动修改"
        let edited = await store.saveCourse(course)
        XCTAssertTrue(edited)
        await session.confirmChange(oldID)
        XCTAssertNil(session.undoChange); XCTAssertEqual(store.state.courses[0].name, "手动修改")
        session.question = "删除合成课程"; session.send(); try await finish(session)
        await session.confirmChange(try XCTUnwrap(session.pendingChange?.id))
        XCTAssertNotNil(session.undoChange); XCTAssertTrue(store.state.courses.isEmpty)
        let added = await store.saveCourse(Course(name: "新的课程", totalMinutes: 60, startDate: Date(), deadline: Date()))
        XCTAssertTrue(added)
        let newer = store.state
        await session.undoLastChange()
        XCTAssertEqual(store.state, newer)
        XCTAssertTrue(session.message?.contains("不能直接撤销") == true)
    }
    @MainActor func testQuittingWaitsForConfirmedMutationAndItsReceipt() async throws {
        let now = Date()
        var state = PlannerState()
        var course = Course(name: "合成退出测试", totalMinutes: 60, startDate: now, deadline: now)
        course.id = AssistantSimulation.courseID; state.courses = [course]; state.settings.availability = []
        var held: CheckedContinuation<Void, Never>?
        var quitFinished = false
        let session = AssistantSession(historyStore: nil, simulated: true,
            snapshot: { .init(state: state, now: Date(), id: "current") },
            transportFactory: { AssistantMockTransport(script: [("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString])]) },
            applyChange: { replacement, _, _ in
                await withCheckedContinuation { held = $0 }
                state = replacement
                return state
            })
        session.configuration = AssistantSimulation.configuration()
        session.question = "删除合成课程"; session.send(); try await finish(session)
        let id = try XCTUnwrap(session.pendingChange?.id)
        let applying = Task { await session.confirmChange(id) }
        while held == nil { try await Task.sleep(for: .milliseconds(10)) }
        let quitting = Task { let saved = await session.prepareToQuit(); quitFinished = true; return saved }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(quitFinished)
        held?.resume(); await applying.value
        let saved = await quitting.value
        XCTAssertTrue(saved); XCTAssertTrue(state.courses.isEmpty)
        XCTAssertTrue(session.entries.contains { $0.role == "本机操作" && $0.text.hasPrefix("已应用") })
    }
    @MainActor func testAllProviderSerializersReturnProposalAndNeverExposePrivateMetadata() async throws {
        var state = AssistantSimulation.snapshot().state
        state.courses[0].notes = "private-source-must-not-leak"
        let s = AssistantSnapshot(state: state, now: AssistantSimulation.snapshot().now)
        for provider in [AssistantProvider.openai, .anthropic, .deepseek] {
            let transport = AssistantMockTransport(script: [("preview_delete_course", ["course": AssistantSimulation.courseID.uuidString])])
            var changes: [AssistantChange] = []
            _ = try await AssistantRunner().run(configuration: AssistantSimulation.configuration(provider: provider),
                messages: [.init(role: "user", content: "删除合成课程")], snapshot: s, key: "",
                transport: transport, currentSnapshotID: { s.id }, approve: { _ in true }, activity: { _ in }, evidence: { _ in }, proposal: { changes.append($0) })
            XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes.first?.before, state)
            let requests = await transport.requests
            XCTAssertTrue(requests.allSatisfy { !$0.body.contains("private-source-must-not-leak") })
            XCTAssertTrue(requests.last?.body.contains("awaiting_local_confirmation") == true)
        }
    }

}

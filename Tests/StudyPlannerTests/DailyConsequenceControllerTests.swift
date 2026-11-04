import XCTest
@testable import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class DailyConsequenceControllerTests: XCTestCase {
    private nonisolated static func fulfilled(_ expectations: [XCTestExpectation]) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 5)
        return result == .completed
    }

    private func fixture() -> (PlannerState, ScheduleResult, Date) {
        let calendar = Calendar.current, day = calendar.startOfDay(for: Date())
        let now = calendar.date(byAdding: .hour, value: 8, to: day)!
        var state = PlannerState()
        var c = Course(name: "模拟课程", totalMinutes: 240, startDate: day, deadline: calendar.date(byAdding: .day, value: 2, to: day)!)
        c.type = .lessonBasedRecorded
        c.manualLessons = (0..<4).map { .init(id: "lesson\($0)", name: "第\($0)节", durationMinutes: 60) }
        state.courses = [c]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 615) }
        let result = state.replan(now: now)
        return (state, result, now)
    }
    @MainActor func testChangingBurdenReminderDoesNotShrinkDailyGoalAfterPartialCompletion() async throws {
        var (state, result, now) = fixture()
        let controller = DailyConsequenceController(inMemory: true)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        let original = controller.today?.goalMinutes
        now = now.addingTimeInterval(1800)
        try state.confirm(taskID: result.tasks[0].id, actualMinutes: 30, now: now)
        result = state.replan(now: now)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 90)
        controller.cancel()
        XCTAssertEqual(controller.today?.goalMinutes, original)
        XCTAssertEqual(controller.today?.warningMinutes, 90)
    }
    @MainActor func testGoalIsFrozenAndEachCrossedBandCelebratesOnlyOnceIncludingAfterRestart() async throws {
        var (state, result, now) = fixture()
        let repository = DailyConsequenceRepository(inMemory: true)
        let controller = DailyConsequenceController(repository: repository)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        let goal = controller.today?.goalMinutes
        now = now.addingTimeInterval(30 * 60)
        try state.confirm(taskID: result.tasks[0].id, actualMinutes: 30, now: now)
        result = state.replan(now: now)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        XCTAssertEqual(controller.today?.goalMinutes, goal)
        XCTAssertEqual(controller.confirmedToday, 30)
        XCTAssertEqual(controller.celebrationEvents[0], 1)
        XCTAssertNil(controller.celebrationEvents[250])
        let next = try XCTUnwrap(result.tasks.first { Calendar.current.isDate($0.start, inSameDayAs: now) })
        now = next.start.addingTimeInterval(60)
        try state.confirm(taskID: next.id, actualMinutes: 1, now: now)
        result = state.replan(now: now)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        XCTAssertEqual(controller.celebrationEvents[250], 1)
        XCTAssertEqual(controller.today?.goalMinutes, goal)
        await controller.waitForPersistence()
        let restored = DailyConsequenceController(repository: repository)
        await restored.refresh(state: state, result: result, now: now, warningMinutes: 120)
        restored.cancel()
        XCTAssertEqual(restored.today?.goalMinutes, goal)
        XCTAssertTrue(restored.celebrationEvents.isEmpty)
        XCTAssertTrue(restored.today?.achieved(250, confirmed: restored.confirmedToday) == true)
        try state.undoConfirmation(taskID: next.id, now: now)
        result = state.replan(now: now)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        XCTAssertFalse(controller.today?.achieved(250, confirmed: controller.confirmedToday) == true)
        XCTAssertEqual(controller.celebrationEvents[250], 1)
    }
    @MainActor func testRolloverShowsReviewedYesterdayAndFreshTodayWithoutCelebrationReplay() async throws {
        var (state, result, now) = fixture()
        let controller = DailyConsequenceController(inMemory: true)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        controller.cancel()
        let original = try XCTUnwrap(controller.today)
        for task in original.plannedToday { try state.confirm(taskID: task.id, actualMinutes: 0, now: now, studyDate: now) }
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        result = state.replan(now: nextDay)
        await controller.refresh(state: state, result: result, now: nextDay, warningMinutes: 120)
        await controller.waitForYesterday()
        controller.cancel()
        XCTAssertEqual(controller.yesterday?.date, original.date)
        XCTAssertEqual(controller.yesterday?.confirmedMinutes, 0)
        XCTAssertEqual(controller.yesterday?.isReviewed, true)
        XCTAssertEqual(controller.confirmedToday, 0)
        XCTAssertNotEqual(controller.today?.date, original.date)
        XCTAssertTrue(controller.celebrationEvents.isEmpty)
    }
    @MainActor func testDuplicateBaselineJournalUsesTemporaryCurrentForecastAndPreservesOriginalFile() async throws {
        try await assertDamagedBaselinePreservesFile(damage: .courses)
    }
    @MainActor func testDuplicateTaskBaselineUsesTemporaryCurrentForecastAndPreservesOriginalFile() async throws {
        try await assertDamagedBaselinePreservesFile(damage: .tasks)
    }
    @MainActor func testOverflowingBaselineProgressUsesTemporaryCurrentForecastAndPreservesOriginalFile() async throws {
        try await assertDamagedBaselinePreservesFile(damage: .records)
        try await assertDamagedBaselinePreservesFile(damage: .initialProgress)
    }
    private enum BaselineDamage { case courses, tasks, records, initialProgress }
    @MainActor private func assertDamagedBaselinePreservesFile(damage: BaselineDamage) async throws {
        let (state, result, now) = fixture(), original = state
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        var damaged = try DailyConsequenceAnalyzer().capture(state: state, result: result, now: now, warningMinutes: 120)
        switch damage {
        case .tasks:
            damaged.baseline.tasks.append(try XCTUnwrap(damaged.baseline.tasks.first))
        case .courses:
            damaged.baseline.courses.append(damaged.baseline.courses[0])
        case .records, .initialProgress:
            // A recorded baseline exercises the same evidence-check reducer as
            // the standalone crash proof; current valid planner state is intact.
            damaged.baseline.courses[0].type = .recorded
            damaged.baseline.courses[0].manualLessons = nil
            let owner = damaged.baseline.courses[0].id
            let amounts = damage == .records ? [Int.max, 1] : [1]
            damaged.baseline.courses[0].initialCompletedMinutes = damage == .initialProgress ? Int.max : 0
            damaged.baseline.completions = amounts.map { .init(courseID: owner, taskID: UUID(), minutes: $0, recordedAt: now, studyDate: now) }
        }
        var journal = DailyConsequenceJournal(); journal.days = [damaged]
        let bytes = try JSONEncoder().encode(journal); try bytes.write(to: url)
        for _ in 0..<2 {
            let controller = DailyConsequenceController(repository: DailyConsequenceRepository(url: url))
            await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
            await controller.waitForForecasts(); await controller.waitForYesterday(); await controller.waitForPersistence()
            let temporary = try XCTUnwrap(controller.today)
            XCTAssertNotEqual(temporary.id, damaged.id)
            XCTAssertEqual(temporary.baseline.courses.count, 1)
            XCTAssertEqual(temporary.baseline.courses[0].id, state.courses[0].id)
            XCTAssertEqual(temporary.baseline.tasks.count, state.tasks.count)
            XCTAssertEqual(Set(temporary.baseline.tasks.map(\.id)).count, temporary.baseline.tasks.count)
            XCTAssertEqual(temporary.goalMinutes, damaged.goalMinutes)
            XCTAssertEqual(temporary.forecasts.count, temporary.fractions.count)
            XCTAssertNil(controller.todayError)
            XCTAssertNotNil(controller.storageMessage)
            XCTAssertTrue(controller.celebrationEvents.isEmpty)
            XCTAssertFalse(controller.calculating)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(state, original)
            controller.cancel()
        }
        // Only the test replaces the file. A new instance may use that valid
        // history; failed-read instances never re-enable their own writes.
        let replacement = try JSONEncoder().encode(DailyConsequenceJournal())
        try replacement.write(to: url)
        let reopened = DailyConsequenceController(repository: DailyConsequenceRepository(url: url))
        await reopened.refresh(state: state, result: result, now: now, warningMinutes: 120)
        await reopened.waitForForecasts(); await reopened.waitForPersistence()
        XCTAssertNotNil(reopened.today)
        XCTAssertNil(reopened.storageMessage)
        XCTAssertNil(reopened.todayError)
        let saved = try JSONDecoder().decode(DailyConsequenceJournal.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.days.count, 1)
        XCTAssertEqual(saved.days[0].id, reopened.today?.id)
        XCTAssertEqual(saved.days[0].baseline.courses.count, 1)
        XCTAssertNotEqual(try Data(contentsOf: url), replacement)
        XCTAssertEqual(state, original)
        reopened.cancel()
    }

    private var emptyPlan: ScheduleResult { .init(tasks: [], risks: [], demands: [:], diagnostics: []) }
    private func progress(_ values: [Int], on date: Date) -> PlannerState {
        var state = PlannerState()
        state.settings.availability = []
        for value in values {
            let course = Course(name: "Synthetic daily credit", totalMinutes: 120, startDate: date, deadline: date)
            state.courses.append(course)
            state.completions.append(.init(courseID: course.id, taskID: UUID(), minutes: value, recordedAt: date, studyDate: date))
        }
        return state
    }

    @MainActor func testOverflowClearsPriorSuccessWithoutChangingDiskAndValidDataRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json"), now = Date()
        let repository = DailyConsequenceRepository(url: url)
        let controller = DailyConsequenceController(repository: repository)
        let valid = progress([1], on: now)
        await controller.refresh(state: valid, result: emptyPlan, now: now, warningMinutes: 480)
        controller.cancel(); await controller.waitForPersistence()
        let before = try Data(contentsOf: url), journal = try await repository.load()
        XCTAssertNotNil(controller.today)
        var ledger = SyncLedger(); try ledger.capture(progress([Int.max, 1], on: now))
        _ = try CloudArchive(ledger: ledger).validated()
        let overflow = try ledger.materialize(), original = overflow
        await controller.refresh(state: overflow, result: emptyPlan, now: now, warningMinutes: 480)
        await controller.waitForForecasts(); await controller.waitForYesterday(); await controller.waitForPersistence()
        XCTAssertNil(controller.today)
        XCTAssertNotNil(controller.todayError)
        XCTAssertFalse(controller.calculating)
        XCTAssertTrue(controller.celebrationEvents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let failedJournal = try await repository.load()
        XCTAssertEqual(failedJournal, journal)
        XCTAssertEqual(overflow, original)
        await controller.refresh(state: valid, result: emptyPlan, now: now, warningMinutes: 480)
        controller.cancel()
        XCTAssertNotNil(controller.today)
        XCTAssertNil(controller.todayError)
        XCTAssertEqual(controller.confirmedToday, 1)
    }

    @MainActor func testCaptureOverflowDoesNotCreateOrReplaceJournalEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json"), now = Date()
        let repository = DailyConsequenceRepository(url: url)
        let controller = DailyConsequenceController(repository: repository)
        await controller.refresh(state: PlannerState(), result: emptyPlan, now: now, warningMinutes: 480)
        controller.cancel(); await controller.waitForPersistence()
        let before = try Data(contentsOf: url)
        let state = progress([Int.max], on: now)
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 1)
        let plan = ScheduleResult(tasks: [task], risks: [], demands: [:], diagnostics: [])
        await controller.refresh(state: state, result: plan, now: now, warningMinutes: 480)
        await controller.waitForPersistence()
        XCTAssertNil(controller.today)
        XCTAssertNotNil(controller.todayError)
        XCTAssertEqual(try Data(contentsOf: url), before)
        controller.cancel()
    }

    @MainActor func testYesterdayFailureIsIndependentAndReviewValidatesCurrentDataBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json"), now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let repository = DailyConsequenceRepository(url: url)
        let controller = DailyConsequenceController(repository: repository)
        let valid = PlannerState()
        await controller.refresh(state: valid, result: emptyPlan, now: yesterday, warningMinutes: 480)
        controller.cancel(); await controller.waitForPersistence()
        await controller.refresh(state: valid, result: emptyPlan, now: now, warningMinutes: 480)
        await controller.waitForYesterday(); controller.cancel(); await controller.waitForPersistence()
        XCTAssertNotNil(controller.yesterday)
        let before = try Data(contentsOf: url)
        let overflow = progress([Int.max, 1], on: yesterday)
        controller.markYesterdayReviewed(state: overflow, now: now)
        await controller.waitForYesterday(); await controller.waitForPersistence()
        XCTAssertNil(controller.yesterday)
        XCTAssertNotNil(controller.yesterdayError)
        XCTAssertEqual(try Data(contentsOf: url), before)
        var saved = try await repository.load()
        XCTAssertNil(saved.days.first { Calendar.current.isDate($0.date, inSameDayAs: yesterday) }?.reviewedAt)
        await controller.refresh(state: overflow, result: emptyPlan, now: now, warningMinutes: 480)
        await controller.waitForYesterday(); controller.cancel(); await controller.waitForPersistence()
        XCTAssertNotNil(controller.today)
        XCTAssertNil(controller.todayError)
        XCTAssertEqual(controller.confirmedToday, 0)
        XCTAssertNil(controller.yesterday)
        XCTAssertNotNil(controller.yesterdayError)
        controller.markYesterdayReviewed(state: valid, now: now)
        await controller.waitForYesterday(); await controller.waitForPersistence()
        XCTAssertNotNil(controller.yesterday)
        XCTAssertNil(controller.yesterdayError)
        XCTAssertTrue(controller.yesterday?.isReviewed == true)
        saved = try await repository.load()
        XCTAssertEqual(saved.days.first { Calendar.current.isDate($0.date, inSameDayAs: yesterday) }?.reviewedAt, now)
    }

    @MainActor func testForecastFailureDoesNotSaveFailedResultAndCanRecover() async throws {
        let repository = DailyConsequenceRepository(inMemory: true), now = Date()
        let state = PlannerState(), analyzer = DailyConsequenceAnalyzer()
        var entry = try analyzer.capture(state: state, result: emptyPlan, now: now, warningMinutes: 480)
        entry.goalMinutes = Int.max; entry.confirmedAtCapture = Int.min
        var journal = DailyConsequenceJournal(); journal.days = [entry]
        try await repository.save(journal, sequence: 0)
        let controller = DailyConsequenceController(repository: repository)
        await controller.refresh(state: state, result: emptyPlan, now: now, warningMinutes: 480)
        await controller.waitForForecasts(); await controller.waitForPersistence()
        XCTAssertNil(controller.today)
        XCTAssertNotNil(controller.todayError)
        XCTAssertFalse(controller.calculating)
        let saved = try await repository.load()
        XCTAssertEqual(saved, journal)
        await controller.refresh(state: state, result: emptyPlan, now: now, warningMinutes: 481)
        await controller.waitForForecasts(); controller.cancel()
        XCTAssertNotNil(controller.today)
        XCTAssertNil(controller.todayError)
    }

    @MainActor func testCancelledOldForecastCannotClearNewSuccessfulRefresh() async throws {
        let repository = DailyConsequenceRepository(inMemory: true), now = Date()
        let state = PlannerState(), analyzer = DailyConsequenceAnalyzer()
        var entry = try analyzer.capture(state: state, result: emptyPlan, now: now, warningMinutes: 480)
        entry.goalMinutes = Int.max; entry.confirmedAtCapture = Int.min
        var journal = DailyConsequenceJournal(); journal.days = [entry]
        try await repository.save(journal, sequence: 0)
        let controller = DailyConsequenceController(repository: repository)
        await controller.refresh(state: state, result: emptyPlan, now: now, warningMinutes: 480)
        // This refresh has no suspension once loaded, so the old task cannot
        // publish its callback on the main actor before its token is invalidated.
        await controller.refresh(state: state, result: emptyPlan, now: now, warningMinutes: 481)
        await controller.waitForForecasts()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNotNil(controller.today)
        XCTAssertNil(controller.todayError)
        XCTAssertEqual(controller.today?.warningMinutes, 481)
        XCTAssertFalse(controller.calculating)
        controller.cancel()
    }

    @MainActor func testOldForecastCannotClearAnotherDayWithAlreadyCompleteForecasts() async throws {
        let repository = DailyConsequenceRepository(inMemory: true), now = Date()
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let state = PlannerState(), analyzer = DailyConsequenceAnalyzer()
        var older = try analyzer.capture(state: state, result: emptyPlan, now: now, warningMinutes: 480)
        older.goalMinutes = Int.max; older.confirmedAtCapture = Int.min
        var newer = try analyzer.capture(state: state, result: emptyPlan, now: nextDay, warningMinutes: 480)
        newer.goalMinutes = 1; newer.confirmedAtCapture = 1
        newer.forecasts = try newer.fractions.map { try XCTUnwrap(analyzer.forecast(newer, fraction: $0, horizon: 1)) }
        var journal = DailyConsequenceJournal(); journal.days = [older, newer]
        try await repository.save(journal, sequence: 0)
        let controller = DailyConsequenceController(repository: repository)
        await controller.refresh(state: state, result: emptyPlan, now: now, warningMinutes: 480)
        await controller.refresh(state: state, result: emptyPlan, now: nextDay, warningMinutes: 480)
        await controller.waitForForecasts(); await controller.waitForYesterday()
        XCTAssertEqual(controller.today?.id, newer.id)
        XCTAssertEqual(controller.today?.forecasts, newer.forecasts)
        XCTAssertNil(controller.todayError)
        XCTAssertFalse(controller.calculating)
        controller.cancel()
    }

    @MainActor func testYesterdayReviewDoesNotCancelValidRunningTodayForecasts() async throws {
        let (state, result, now) = fixture()
        let date = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let repository = DailyConsequenceRepository(inMemory: true)
        var journal = DailyConsequenceJournal()
        journal.days = [try DailyConsequenceAnalyzer().capture(state: PlannerState(), result: emptyPlan, now: date, warningMinutes: 120)]
        try await repository.save(journal, sequence: 0)
        let controller = DailyConsequenceController(repository: repository)
        await controller.refresh(state: state, result: result, now: now, warningMinutes: 120)
        XCTAssertTrue(controller.calculating)
        controller.markYesterdayReviewed(state: state, now: now)
        XCTAssertTrue(controller.calculating)
        controller.markYesterdayReviewed(state: progress([Int.max, 1], on: date), now: now)
        XCTAssertNil(controller.todayError)
        XCTAssertTrue(controller.calculating)
        await controller.waitForForecasts(); await controller.waitForYesterday()
        XCTAssertNotNil(controller.yesterdayError)
        XCTAssertEqual(controller.today?.forecasts.count, controller.today?.fractions.count)
        XCTAssertFalse(controller.calculating)
        controller.cancel()
    }

    @MainActor func testPendingOrAmbiguousYesterdayCannotBeMarkedReviewed() async throws {
        let repository = DailyConsequenceRepository(inMemory: true), now = Date()
        let date = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        var journal = DailyConsequenceJournal()
        journal.days = [try DailyConsequenceAnalyzer().capture(state: PlannerState(), result: emptyPlan, now: date, warningMinutes: 480)]
        try await repository.save(journal, sequence: 0)
        let controller = DailyConsequenceController(repository: repository)
        await controller.refresh(state: PlannerState(), result: emptyPlan, now: now, warningMinutes: 480)
        await controller.waitForYesterday(); await controller.waitForPersistence()
        let before = try await repository.load()
        var pending = PlannerState()
        let course = Course(name: "Synthetic pending", totalMinutes: 60, startDate: date, deadline: now)
        pending.courses = [course]
        pending.tasks = [ScheduledTask(courseID: course.id, start: date, durationMinutes: 60)]
        controller.markYesterdayReviewed(state: pending, now: now)
        await controller.waitForYesterday(); await controller.waitForPersistence()
        var saved = try await repository.load()
        XCTAssertEqual(saved, before)
        XCTAssertFalse(controller.yesterday?.isReviewed == true)
        var ambiguous = pending; ambiguous.tasks = []
        ambiguous.completions = [.init(courseID: course.id, taskID: UUID(), minutes: 0, recordedAt: date)]
        controller.markYesterdayReviewed(state: ambiguous, now: now)
        await controller.waitForYesterday(); await controller.waitForPersistence()
        saved = try await repository.load()
        XCTAssertEqual(saved, before)
        XCTAssertEqual(controller.yesterday?.ambiguousRecords, 1)
        XCTAssertNil(controller.yesterdayError)
        controller.cancel()
    }

    @MainActor func testConcurrentInitialLoadsPublishOnlyTheLatestInput() async throws {
        let repository = DailyConsequenceRepository(inMemory: true), now = Date()
        let entered = expectation(description: "Repository actor held before load")
        let gate = DispatchSemaphore(value: 0)
        let hold = Task.detached { await repository.holdForDailyControllerTest(gate: gate, entered: entered) }
        let enteredResult = await Self.fulfilled([entered])
        XCTAssertTrue(enteredResult)
        defer { gate.signal() }
        let controller = DailyConsequenceController(repository: repository)
        let olderState = progress([Int.max, 1], on: now), latestState = PlannerState()
        let plan = emptyPlan
        let olderStarted = expectation(description: "Older refresh started")
        let latestStarted = expectation(description: "Latest refresh started")
        let older = Task {
            olderStarted.fulfill()
            await controller.refresh(state: olderState, result: plan, now: now, warningMinutes: 480)
        }
        let olderResult = await Self.fulfilled([olderStarted])
        XCTAssertTrue(olderResult)
        let latest = Task {
            latestStarted.fulfill()
            await controller.refresh(state: latestState, result: plan, now: now, warningMinutes: 481)
        }
        let latestResult = await Self.fulfilled([latestStarted])
        XCTAssertTrue(latestResult)
        gate.signal(); await hold.value
        await older.value; await latest.value; await controller.waitForForecasts()
        XCTAssertNotNil(controller.today)
        XCTAssertNil(controller.todayError)
        XCTAssertEqual(controller.today?.warningMinutes, 481)
        XCTAssertEqual(controller.confirmedToday, 0)
        controller.cancel()
    }

}


private extension DailyConsequenceRepository {
    func holdForDailyControllerTest(gate: DispatchSemaphore, entered: XCTestExpectation) {
        entered.fulfill()
        _ = gate.wait(timeout: .now() + 5)
    }
}

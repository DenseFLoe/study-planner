import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class AssistantResponsivenessTests: XCTestCase {
    @MainActor func testOpeningAndClosingLargeHistoryDoNotBlockMainActor() async throws {
        let store = try history(), snapshot = AssistantSimulation.snapshot()
        let archive = (0..<8).map { _ in
            AssistantConversation(entries: (0..<20).map { _ in
                .init(role: "助手", text: String(repeating: "仅用于窗口响应测试的合成记录。", count: 60), status: "完成")
            })
        }
        try await Task.detached {
            try store.save(.init(configuration: AssistantSimulation.configuration(), conversations: archive, selectedID: archive[0].id))
        }.value
        let opening = ContinuousClock.now
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { snapshot })
        let openDuration = opening.duration(to: .now)
        XCTAssertLessThan(openDuration, .milliseconds(100), "Opening must not synchronously read/validate history")
        await session.waitUntilReady()
        let closing = ContinuousClock.now
        session.close()
        let closeDuration = closing.duration(to: .now)
        XCTAssertLessThan(closeDuration, .milliseconds(100), "Closing must not wait for history writes")
        print("ASSISTANT_WINDOW_RESPONSIVENESS open=\(openDuration) close=\(closeDuration)")
        let saved = await session.prepareToQuit()
        XCTAssertTrue(saved)
    }
    private func history() throws -> AssistantHistoryStore {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("assistant-responsive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(url: root.appendingPathComponent("workspace.json"))
    }
    @MainActor func testLargeHistorySendAndFollowupKeepMainActorResponsiveAndConfirmOncePerTurn() async throws {
        let store = try history(), selected = AssistantConversation()
        let archive = (0..<8).map { _ in
            AssistantConversation(entries: (0..<20).map { _ in
                .init(role: "助手", text: String(repeating: "仅用于响应测试的合成学习记录。", count: 60), status: "完成")
            })
        }
        try store.save(.init(configuration: AssistantSimulation.configuration(), conversations: [selected] + archive, selectedID: selected.id))
        let snapshot = AssistantSimulation.snapshot()
        let session = AssistantSession(historyStore: store, simulated: true,
                                       snapshot: { snapshot }, transportFactory: {
            AssistantMockTransport(script: Array(AssistantSimulation.script.prefix(2)))
        })
        await session.waitUntilReady()
        for text in ["第一问", "继续查询"] {
            session.question = text
            let start = ContinuousClock.now
            session.send()
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(300), "Sending must return before history validation or IO")
            XCTAssertTrue(session.busy)
            var approvals = 0, ticks = 0, longest = Duration.zero
            let deadline = ContinuousClock.now.advanced(by: .seconds(40))
            while session.busy && ContinuousClock.now < deadline {
                if let approval = session.approval { approvals += 1; session.decide(approval.id, allow: true) }
                let tick = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(10))
                longest = max(longest, tick.duration(to: .now)); ticks += 1
            }
            XCTAssertFalse(session.busy)
            XCTAssertEqual(approvals, 1)
            XCTAssertGreaterThan(ticks, 2)
            XCTAssertLessThan(longest, .milliseconds(500), "Background work must allow the UI executor to service events")
            print("ASSISTANT_RESPONSIVENESS sendAndFollowup maxMainActorGap=\(longest) ticks=\(ticks)")
        }
        XCTAssertEqual(session.entries.filter { $0.role == "助手" }.count, 2)
        XCTAssertEqual(try store.load().selectedID, selected.id)
        let start = ContinuousClock.now
        session.newConversation(); let latest = session.selectedID
        session.select(selected.id); session.select(latest)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
        session.close()
        let flushed = await session.prepareToQuit()
        XCTAssertTrue(flushed)
        let saved = try store.load()
        XCTAssertEqual(saved.selectedID, latest)
        XCTAssertEqual(saved.conversations.count, 10)
    }
    @MainActor func testStopDuringPreparationCannotSendOrOverwriteNewConversation() async throws {
        let store = try history(), mock = AssistantMockTransport()
        let snapshot = AssistantSimulation.snapshot()
        let session = AssistantSession(historyStore: store, simulated: true,
                                       snapshot: { snapshot }, transportFactory: { mock })
        await session.waitUntilReady()
        session.configuration = AssistantSimulation.configuration()
        session.question = "待取消的合成问题"; session.send()
        session.newConversation(); let latest = session.selectedID
        try await Task.sleep(for: .milliseconds(200))
        let flushed = await session.prepareToQuit()
        XCTAssertTrue(flushed)
        XCTAssertFalse(session.busy); XCTAssertNil(session.approval)
        XCTAssertTrue(session.entries.isEmpty)
        let requests = await mock.requests; XCTAssertTrue(requests.isEmpty)
        let saved = try store.load()
        XCTAssertEqual(saved.selectedID, latest)
        XCTAssertEqual(saved.conversations.count, 2)
        XCTAssertFalse(saved.conversations.flatMap(\.entries).contains { $0.status == "处理中" })
    }
    @MainActor func testStoreRevisionTracksSuccessfulChangesAndPreservesFailedSaveVersion() async throws {
        let state = AssistantSimulation.snapshot().state, repository = Repository()
        let store = PlannerStore(state: state, repository: repository,
                                 result: ScheduleEngine().assessSavedPlan(state: state, now: Date()))
        let initial = store.assistantSnapshotID
        let changed = await store.change(replan: false) { $0.courses[0].name = "修改后的合成课程" }
        XCTAssertTrue(changed); XCTAssertNotEqual(initial, store.assistantSnapshotID)
        let saved = store.assistantSnapshotID
        repository.fails = true
        let rejected = await store.change(replan: false) { $0.courses[0].name = "未保存的合成课程" }
        XCTAssertFalse(rejected); XCTAssertEqual(saved, store.assistantSnapshotID)
    }
    private final class Repository: PlannerRepository {
        var fails = false
        func load() throws -> PlannerState { .init() }
        func save(_ state: PlannerState) throws {
            if fails { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

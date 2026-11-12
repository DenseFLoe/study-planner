import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class AssistantPlanningReliabilityTests: XCTestCase {
    @MainActor private func finish(_ session: AssistantSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while session.busy {
            guard ContinuousClock.now < deadline else { throw AssistantError.limit }
            if let approval = session.approval { session.decide(approval.id, allow: true) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testFailedRequestAndReasonSurviveReopeningAndContinueIntoCompoundPreview() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = AssistantHistoryStore(url: root.appendingPathComponent("history.json"))
        let snapshot = AssistantSimulation.snapshot()
        let first = AssistantSession(historyStore: history, simulated: true, snapshot: { snapshot },
            transportFactory: { AssistantMockTransport(failAt: 1) })
        await first.waitUntilReady()
        first.configuration = AssistantSimulation.configuration()
        first.question = "今天尽可能安排合成课程 A，其他课程自动另找时间"; first.send()
        try await finish(first)
        XCTAssertEqual(first.entries.last?.failureReason, .network)
        let persisted = try history.load()
        XCTAssertEqual(persisted.conversations[0].entries.last?.failureReason, .network)
        let transport = AssistantMockTransport(script: [("list_courses", ["offset": "0"]),
            ("preview_focus_today", ["course": AssistantSimulation.courseID.uuidString])])
        let reopened = AssistantSession(historyStore: history, simulated: true, snapshot: { snapshot }, transportFactory: { transport })
        await reopened.waitUntilReady()
        reopened.question = "你自己安排即可"; reopened.send(); try await finish(reopened)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "A complete local preview needs no additional model response")
        let rootObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(requests[0].body.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(rootObject["messages"] as? [[String: String]])
        XCTAssertTrue(messages.contains { $0["role"] == "user" && $0["content"] == first.entries[0].text })
        XCTAssertTrue(messages.contains { $0["content"]?.contains("上一请求未完成") == true })
        XCTAssertEqual(messages.last?["content"], "你自己安排即可")
        XCTAssertNotNil(reopened.pendingChange)
        XCTAssertEqual(reopened.pendingChange?.before, snapshot.state)
        XCTAssertTrue(reopened.entries.last?.text.contains("尚未保存") == true)
    }

    func testInterruptedContextRetainsIntentButLegacyEvidenceStaysLocalAndLatestInstructionWins() throws {
        let entries: [AssistantChatEntry] = [
            .init(role: "你", text: "旧版私有问题", status: "旧版记录 · 仅本机查看"),
            .init(role: "本机证据", text: "无效的旧证据", status: "完成"),
            .init(role: "你", text: "合成原目标", status: "上次已中断 · 未续传"),
            .init(role: "本机操作", text: "已取消修改方案，日程未改变。", status: "完成")
        ]
        let messages = try AssistantConversationContext.messages(history: entries, memories: [], current: "取消前面的安排，只查进度")
        XCTAssertFalse(messages.contains { $0.content.contains("旧版私有") || $0.content.contains("旧证据") })
        XCTAssertTrue(messages.contains { $0.role == "user" && $0.content == "合成原目标" })
        XCTAssertTrue(messages.contains { $0.content.contains("已取消修改") })
        XCTAssertEqual(messages.last?.content, "取消前面的安排，只查进度")
    }

    @MainActor func testNoOpSaveKeepsRevisionAndRealEditInvalidatesIt() async throws {
        let repository = try LocalRepository(inMemory: true), fixture = AssistantSimulation.snapshot()
        try repository.save(fixture.state)
        let initial = try repository.load()
        let store = PlannerStore(state: initial, repository: repository,
            result: ScheduleEngine(calendar: fixture.calendar).assessSavedPlan(state: initial, now: fixture.now))
        let revision = store.assistantSnapshotID
        let saved = await store.change(replan: false, now: fixture.now) { _ in }
        XCTAssertTrue(saved); XCTAssertEqual(store.state, initial)
        XCTAssertEqual(store.assistantSnapshotID, revision)
        let changed = await store.change(replan: false, now: fixture.now) { $0.courses[0].name = "合成真正修改" }
        XCTAssertTrue(changed); XCTAssertNotEqual(store.assistantSnapshotID, revision)
    }

    private actor SavingTransport: AssistantTransport {
        nonisolated let simulated = true
        let mock = AssistantMockTransport(script: [("inspect_rules", [:])])
        let save: @MainActor () -> Void
        init(save: @escaping @MainActor () -> Void) { self.save = save }
        func send(_ request: AssistantRequest, key: String) async throws -> String {
            let response = try await mock.send(request, key: key)
            await save()
            return response
        }
    }
    @MainActor func testTransientSavingWaitsWithoutDiscardingEvidenceOrRestartingRequests() async throws {
        let snapshot = AssistantSimulation.snapshot()
        var saving = false, transports = 0
        let transport = SavingTransport {
            saving = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                saving = false
            }
        }
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { saving ? nil : snapshot }, transportFactory: {
            transports += 1; return transport
        })
        session.configuration = AssistantSimulation.configuration(); session.question = "合成查询"; session.send()
        try await finish(session)
        XCTAssertNil(session.message); XCTAssertEqual(transports, 1)
        XCTAssertEqual(session.evidence.count, 1)
        let requests = await transport.mock.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(session.entries[0].steps?.contains("课表已更新，正在重新查询…") == true)
    }
}

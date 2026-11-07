import XCTest
@testable import StudyPlanner

final class AssistantConversationTests: XCTestCase {
    private func history() throws -> AssistantHistoryStore {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("assistant-delete-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(url: root.appendingPathComponent("workspace.json"))
    }
    @MainActor func testDeleteSelectedPersistsAndSelectsMostRecentWithoutChangingMemories() async throws {
        let store = try history()
        let old = AssistantConversation(updatedAt: .distantPast)
        let recent = AssistantConversation(entries: [.init(role: "你", text: "合成最近问题", status: "完成")])
        let selected = AssistantConversation(entries: [.init(role: "你", text: "要删除的合成问题", status: "完成")])
        let memory = AssistantMemory(text: "合成学习偏好", enabled: false)
        let config = AssistantSimulation.configuration()
        try store.save(.init(configuration: config, conversations: [old, selected, recent], selectedID: selected.id, memories: [memory]))
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        let deleted = await session.deleteConversation(selected.id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.selectedID, recent.id)
        XCTAssertFalse(session.conversations.contains { $0.id == selected.id })
        let reopened = AssistantSession(historyStore: store, simulated: true, snapshot: { nil })
        await reopened.waitUntilReady()
        XCTAssertEqual(reopened.conversations.map(\.id), [old.id, recent.id])
        XCTAssertEqual(reopened.selectedID, recent.id)
        XCTAssertEqual(reopened.memories.map(\.id), [memory.id])
        XCTAssertEqual(reopened.configuration, config)
    }
    @MainActor func testDeletingLastConversationPersistsOneEmptyReplacement() async throws {
        let store = try history()
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        let original = session.selectedID
        let deleted = await session.deleteConversation(original)
        XCTAssertTrue(deleted); XCTAssertNotEqual(session.selectedID, original)
        XCTAssertEqual(session.conversations.count, 1); XCTAssertTrue(session.entries.isEmpty)
        let saved = try store.load()
        XCTAssertEqual(saved.selectedID, session.selectedID)
        XCTAssertEqual(saved.conversations.count, 1)
        let invalid = await session.deleteConversation(UUID())
        XCTAssertFalse(invalid)
    }
    private struct FailingHistory: AssistantHistoryPersistence {
        let initial: AssistantWorkspace
        func load() throws -> AssistantWorkspace { initial }
        func save(_ value: AssistantWorkspace) throws { throw AssistantError.history }
    }
    @MainActor func testBatchDeleteAndClearAllPersistWithoutChangingSettingsOrMemories() async throws {
        let store = try history()
        let records = (0..<5).map { AssistantConversation(entries: [.init(role: "你", text: "合成对话 \($0)", status: "完成")]) }
        let config = AssistantSimulation.configuration(), memory = AssistantMemory(text: "合成记忆", enabled: true)
        try store.save(.init(configuration: config, conversations: records, selectedID: records[0].id, memories: [memory]))
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        let batch = await session.deleteConversations([records[1].id, records[3].id, UUID()])
        XCTAssertTrue(batch)
        XCTAssertEqual(session.selectedID, records[0].id)
        XCTAssertEqual(try store.load().conversations.map(\.id), [records[0].id, records[2].id, records[4].id])
        let cleared = await session.deleteConversations(Set(session.conversations.map(\.id)))
        XCTAssertTrue(cleared)
        let reopened = AssistantSession(historyStore: store, simulated: true, snapshot: { nil })
        await reopened.waitUntilReady()
        XCTAssertEqual(reopened.conversations.count, 1)
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertFalse(records.map(\.id).contains(reopened.selectedID))
        XCTAssertEqual(reopened.configuration, config)
        XCTAssertEqual(reopened.memories.map(\.id), [memory.id])
    }
    @MainActor func testFailedBatchDeletionRestoresAllRecordsAndOriginalOrder() async throws {
        let records = (0..<5).map { AssistantConversation(entries: [.init(role: "你", text: "保留合成对话 \($0)", status: "完成")]) }
        let session = AssistantSession(historyStore: FailingHistory(initial: .init(conversations: records, selectedID: records[2].id)),
                                       simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        let deleted = await session.deleteConversations([records[0].id, records[2].id, records[4].id])
        XCTAssertFalse(deleted)
        XCTAssertEqual(session.conversations.map(\.id), records.map(\.id))
        XCTAssertEqual(session.selectedID, records[2].id)
        let cleared = await session.deleteConversations(Set(records.map(\.id)))
        XCTAssertFalse(cleared)
        XCTAssertEqual(session.conversations.map(\.id), records.map(\.id))
        XCTAssertEqual(session.selectedID, records[2].id)
    }
    @MainActor func testFailedDeletionRestoresOriginalSelectionAndDoesNotKeepPlaceholder() async throws {
        let original = AssistantConversation(entries: [.init(role: "你", text: "必须保留的合成问题", status: "完成")])
        let session = AssistantSession(historyStore: FailingHistory(initial: .init(conversations: [original], selectedID: original.id)),
                                       simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        let deleted = await session.deleteConversation(original.id)
        XCTAssertFalse(deleted); XCTAssertFalse(session.isDeletingConversation)
        XCTAssertEqual(session.conversations.map(\.id), [original.id])
        XCTAssertEqual(session.selectedID, original.id)
        XCTAssertEqual(session.entries.first?.text, original.entries.first?.text)
        XCTAssertNotNil(session.historyMessage)
    }
    private final class SlowHistory: AssistantHistoryPersistence, @unchecked Sendable {
        let store: AssistantHistoryStore
        let started: XCTestExpectation
        let gate = NSCondition()
        private var released = false
        init(store: AssistantHistoryStore, started: XCTestExpectation) { self.store = store; self.started = started }
        func load() throws -> AssistantWorkspace { try store.load() }
        func save(_ value: AssistantWorkspace) throws {
            gate.lock()
            if !released {
                started.fulfill()
                let deadline = Date().addingTimeInterval(5)
                while !released {
                    if !gate.wait(until: deadline) { gate.unlock(); throw AssistantError.history }
                }
            }
            gate.unlock()
            try store.save(value)
        }
        func release() { gate.lock(); released = true; gate.broadcast(); gate.unlock() }
    }
    @MainActor func testQuitWaitsForDeletionAndUIStaysResponsiveDuringSave() async throws {
        let store = try history(), started = expectation(description: "Deletion save started")
        let slow = SlowHistory(store: store, started: started)
        defer { slow.release() }
        let session = AssistantSession(historyStore: slow, simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        let original = session.selectedID
        let deletion = Task { await session.deleteConversation(original) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(session.isDeletingConversation)
        let replacement = session.selectedID
        session.newConversation(); session.select(original)
        XCTAssertEqual(session.selectedID, replacement)
        var quitFinished = false
        let quit = Task { let result = await session.prepareToQuit(); quitFinished = true; return result }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(quitFinished)
        slow.release()
        let deleted = await deletion.value, saved = await quit.value
        XCTAssertTrue(deleted); XCTAssertTrue(saved)
        XCTAssertFalse(try store.load().conversations.contains { $0.id == original })
    }
    private actor LateTransport: AssistantTransport {
        nonisolated let simulated = true
        private(set) var started = false
        private(set) var finished = false
        private var release: CheckedContinuation<Void, Never>?
        func send(_ request: AssistantRequest, key: String) async throws -> String {
            await withCheckedContinuation { release = $0; started = true }
            finished = true
            return try await AssistantMockTransport(script: []).send(request, key: key)
        }
        func finish() { release?.resume(); release = nil }
    }
    @MainActor private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AssistantError.protocolError }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor func testDeletingOtherConversationKeepsApprovalThenDeletingActiveCancelsIt() async throws {
        let store = try history(), mock = AssistantMockTransport(script: [])
        let snapshot = AssistantSimulation.snapshot()
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { snapshot }, transportFactory: { mock })
        await session.waitUntilReady()
        session.configuration = AssistantSimulation.configuration()
        let other = session.selectedID
        session.newConversation(); let current = session.selectedID
        session.question = "删除测试的合成查询"; session.send()
        try await waitUntil { session.approval != nil || !session.busy }
        let approval = try XCTUnwrap(session.approval)
        let removedOther = await session.deleteConversation(other)
        XCTAssertTrue(removedOther); XCTAssertEqual(session.selectedID, current)
        XCTAssertTrue(session.busy); XCTAssertEqual(session.approval?.id, approval.id)
        let removedCurrent = await session.deleteConversation(current)
        XCTAssertTrue(removedCurrent); XCTAssertFalse(session.busy); XCTAssertNil(session.approval)
        session.decide(approval.id, allow: true)
        try await Task.sleep(for: .milliseconds(50))
        let requests = await mock.requests
        XCTAssertTrue(requests.isEmpty)
        let flushed = await session.prepareToQuit()
        XCTAssertTrue(flushed)
        XCTAssertFalse(try store.load().conversations.contains { $0.id == current || $0.id == other })
    }
    @MainActor func testLateResponseCannotResurrectDeletedConversation() async throws {
        let store = try history(), late = LateTransport(), snapshot = AssistantSimulation.snapshot()
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { snapshot }, transportFactory: { late })
        await session.waitUntilReady()
        session.configuration = AssistantSimulation.configuration()
        let original = session.selectedID
        session.question = "合成延迟查询"; session.send()
        try await waitUntil { session.approval != nil || !session.busy }
        session.decide(try XCTUnwrap(session.approval).id, allow: true)
        try await waitUntil { await late.started }
        let deleted = await session.deleteConversation(original)
        XCTAssertTrue(deleted)
        let replacement = session.selectedID
        await late.finish()
        try await waitUntil { await late.finished }
        try await Task.sleep(for: .milliseconds(50))
        let saved = await session.prepareToQuit()
        XCTAssertTrue(saved); XCTAssertEqual(session.selectedID, replacement); XCTAssertTrue(session.entries.isEmpty)
        XCTAssertFalse(try store.load().conversations.contains { $0.id == original })
    }
}

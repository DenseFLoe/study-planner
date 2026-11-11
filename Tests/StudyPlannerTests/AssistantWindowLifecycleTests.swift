import XCTest
@testable import StudyPlanner

final class AssistantWindowLifecycleTests: XCTestCase {
    @MainActor private final class TransportSelection {
        var useFast = false
    }
    private actor LateTransport: AssistantTransport {
        nonisolated let simulated = true
        private(set) var started = false
        private(set) var returnedAfterCancellation = false
        private var release: CheckedContinuation<Void, Never>?
        func send(_ request: AssistantRequest, key: String) async throws -> String {
            await withCheckedContinuation { release = $0; started = true }
            returnedAfterCancellation = Task.isCancelled
            return try await AssistantMockTransport(script: []).send(request, key: key)
        }
        func finish() { release?.resume(); release = nil }
    }
    @MainActor private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Synthetic request timed out"); throw AssistantError.protocolError }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor func testClosingInFlightIgnoresLateResponseAfterReopeningAndSendingAgain() async throws {
        let snapshot = AssistantSimulation.snapshot(), late = LateTransport(), fast = AssistantMockTransport(script: [])
        let selection = TransportSelection()
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { snapshot },
                                       transportFactory: { if selection.useFast { return fast }; return late })
        session.configuration = AssistantSimulation.configuration()
        session.question = "旧请求"; session.send()
        try await waitUntil { session.approval != nil }
        session.decide(session.approval!.id, allow: true)
        try await waitUntil { await late.started }
        session.close()
        XCTAssertFalse(session.busy); XCTAssertNil(session.approval)
        XCTAssertEqual(session.entries.first?.status, "未完成")
        selection.useFast = true; session.newConversation()
        let latest = session.selectedID
        session.question = "重开后新请求"; session.send()
        try await waitUntil {
            if let approval = session.approval { session.decide(approval.id, allow: true) }
            return !session.busy
        }
        let entries = session.entries.map(\.id)
        await late.finish()
        try await waitUntil { await late.returnedAfterCancellation }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.selectedID, latest); XCTAssertEqual(session.entries.map(\.id), entries)
        XCTAssertEqual(session.entries.filter { $0.role == "助手" }.count, 1)
        XCTAssertFalse(session.entries.contains { $0.text == "旧请求" })
    }
    /// A bounded stall models slow disk IO without relying on machine speed.
    private final class Gate: @unchecked Sendable {
        private let condition = NSCondition()
        private var opened = false
        func wait() throws {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while !opened {
                guard condition.wait(until: deadline) else { throw AssistantError.history }
            }
        }
        func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
    }
    private struct SlowHistory: AssistantHistoryPersistence {
        let store: AssistantHistoryStore
        var readGate: Gate? = nil
        var writeGate: Gate? = nil
        var writeStarted: XCTestExpectation? = nil
        func load() throws -> AssistantWorkspace { try readGate?.wait(); return try store.load() }
        func save(_ value: AssistantWorkspace) throws {
            writeStarted?.fulfill()
            try writeGate?.wait(); try store.save(value)
        }
    }
    private func history() throws -> AssistantHistoryStore {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("assistant-window-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(url: root.appendingPathComponent("workspace.json"))
    }
    @MainActor func testCloseDuringLoadKeepsOriginalHistoryAndQuitAwaitsLoad() async throws {
        let store = try history(), gate = Gate(), conversation = AssistantConversation(entries: [
            .init(role: "你", text: "合成的上次问题", status: "处理中")
        ])
        defer { gate.open() }
        try store.save(.init(configuration: AssistantSimulation.configuration(), conversations: [conversation], selectedID: conversation.id))
        let original = try Data(contentsOf: store.url)
        let start = ContinuousClock.now
        let session = AssistantSession(historyStore: SlowHistory(store: store, readGate: gate), simulated: true, snapshot: { nil })
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        XCTAssertTrue(session.isLoadingHistory)
        session.question = "加载时的合成问题"; session.send(); session.newConversation()
        XCTAssertFalse(session.canSend); XCTAssertFalse(session.busy)
        for _ in 0..<20 { session.close() }
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        var quitFinished = false
        let quit = Task { let saved = await session.prepareToQuit(); quitFinished = true; return saved }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(quitFinished)
        gate.open()
        let saved = await quit.value
        XCTAssertTrue(saved); XCTAssertFalse(session.isLoadingHistory)
        XCTAssertEqual(session.selectedID, conversation.id)
        let loaded = try store.load()
        XCTAssertEqual(loaded.conversations.count, 1)
        XCTAssertEqual(loaded.conversations[0].entries[0].status, "上次已中断 · 未续传")
    }
    @MainActor func testRepeatedCloseNeverWaitsForSlowSaveAndLatestSelectionWins() async throws {
        let store = try history(), gate = Gate()
        defer { gate.open() }
        let started = expectation(description: "background save started")
        started.assertForOverFulfill = false
        let session = AssistantSession(historyStore: SlowHistory(store: store, writeGate: gate, writeStarted: started),
                                       simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        let original = session.selectedID
        session.newConversation()
        // Let the queued writer enter its simulated slow IO before closing.
        await fulfillment(of: [started], timeout: 2)
        let closing = ContinuousClock.now
        for _ in 0..<20 { session.close() }
        XCTAssertLessThan(closing.duration(to: .now), .milliseconds(100))
        session.select(original)
        var quitFinished = false
        let quit = Task { let saved = await session.prepareToQuit(); quitFinished = true; return saved }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(quitFinished)
        gate.open()
        let saved = await quit.value
        XCTAssertTrue(saved)
        XCTAssertEqual(try store.load().selectedID, original)
        XCTAssertEqual(try store.load().conversations.count, 2)
    }
    @MainActor func testCloseDuringFailedLoadNeverOverwritesUnreadableHistory() async throws {
        let store = try history(), gate = Gate(), original = Data("synthetic corrupt history".utf8)
        defer { gate.open() }
        try original.write(to: store.url)
        let session = AssistantSession(historyStore: SlowHistory(store: store, readGate: gate), simulated: true, snapshot: { nil })
        session.close(); gate.open()
        await session.waitUntilReady()
        XCTAssertNotNil(session.historyMessage); XCTAssertFalse(session.canSend)
        session.close()
        let safeToQuit = await session.prepareToQuit()
        XCTAssertTrue(safeToQuit)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }
    @MainActor func testCloseSaveFailureIsReportedAndDoesNotPermitQuit() async throws {
        let store = try history()
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        // An existing directory at the file path makes the atomic write fail.
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        session.newConversation()
        session.close()
        let saved = await session.prepareToQuit()
        XCTAssertFalse(saved); XCTAssertNotNil(session.historyMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }
}

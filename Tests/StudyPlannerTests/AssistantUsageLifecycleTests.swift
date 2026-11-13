import XCTest
@testable import StudyPlanner

@MainActor final class AssistantUsageLifecycleTests: XCTestCase {
    private actor Metered: AssistantTransport {
        nonisolated let simulated = true
        let mock: AssistantMockTransport
        let malformed: Bool
        init(failAt: Int? = nil, malformed: Bool = false) {
            mock = AssistantMockTransport(script: [("list_courses", ["offset": "0"])], failAt: failAt)
            self.malformed = malformed
        }
        func send(_ request: AssistantRequest, key: String) async throws -> String {
            let response = try await mock.send(request, key: key)
            var root = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]
            root["usage"] = ["prompt_tokens": 1000, "completion_tokens": 200, "prompt_cache_hit_tokens": 400]
            if malformed { root.removeValue(forKey: "choices") }
            return try AssistantWire.encode(root)
        }
    }
    private func finish(_ session: AssistantSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while session.busy {
            guard ContinuousClock.now < deadline else { throw AssistantError.limit }
            if let approval = session.approval { session.decide(approval.id, allow: true) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func testSessionCountsAllRequestsAndRetainsEachTurnsSnapshotAcrossReload() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = AssistantHistoryStore(url: folder.appendingPathComponent("workspace.json"))
        let snapshot = AssistantSimulation.snapshot()
        let session = AssistantSession(historyStore: history, simulated: true, snapshot: { snapshot },
            transportFactory: { Metered() }, pricingProvider: { _ in XCTFail("Simulation must not fetch prices"); return .unsupported })
        await session.waitUntilReady()
        session.configuration = AssistantSimulation.configuration()
        session.question = "合成查询一"; session.send(); try await finish(session)
        let first = try XCTUnwrap(session.latestUsage)
        XCTAssertEqual(first.requests, 2); XCTAssertEqual(first.responses, 2)
        XCTAssertEqual(first.tools, 1); XCTAssertEqual(first.input, 2000); XCTAssertEqual(first.output, 400)
        XCTAssertEqual(first.cachedInput, 800); XCTAssertEqual(first.pricedResponses, 2)
        session.question = "合成查询二"; session.send(); try await finish(session)
        XCTAssertEqual(session.latestUsage?.requests, 2) // New turn, not cumulative conversation usage.
        XCTAssertEqual(session.entries.filter { $0.role == "你" }.first?.usage, first)
        let previous = session.selectedID
        session.newConversation(); XCTAssertNil(session.latestUsage)
        session.select(previous); XCTAssertEqual(session.latestUsage?.input, 2000)
        let saved = await session.prepareToQuit(); XCTAssertTrue(saved)
        let reloaded = AssistantSession(historyStore: history, simulated: true, snapshot: { nil })
        await reloaded.waitUntilReady()
        XCTAssertEqual(reloaded.latestUsage, session.latestUsage)
    }
    func testFailureRetainsKnownUsageAndDoesNotCountUnreturnedRequestAsFree() async throws {
        let snapshot = AssistantSimulation.snapshot()
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { snapshot }, transportFactory: { Metered(failAt: 2) })
        session.configuration = AssistantSimulation.configuration()
        session.question = "合成中途失败"; session.send(); try await finish(session)
        let usage = try XCTUnwrap(session.latestUsage)
        XCTAssertEqual(usage.requests, 2); XCTAssertEqual(usage.responses, 1)
        XCTAssertEqual(usage.pricedResponses, 1); XCTAssertEqual(usage.input, 1000)
        XCTAssertEqual(session.entries.last?.status, "未完成")
    }
    func testUsageSurvivesSnapshotChangesAndInvalidReplies() async throws {
        let snapshot = AssistantSimulation.snapshot()
        for malformed in [false, true] {
            var changed = false, events: [AssistantUsageEvent] = []
            do {
                _ = try await AssistantRunner().run(configuration: AssistantSimulation.configuration(),
                    messages: [.init(role: "user", content: "合成查询")], snapshot: snapshot, key: "", transport: Metered(malformed: malformed),
                    currentSnapshotID: { changed ? "changed" : snapshot.id }, approve: { _ in true }, activity: { _ in }, evidence: { _ in },
                    usage: { event in
                        events.append(event)
                        if case .response = event, !malformed { changed = true }
                    })
                XCTFail("Expected unusable reply")
            } catch { XCTAssertEqual(error as? AssistantError, malformed ? .protocolError : .snapshotChanged) }
            XCTAssertEqual(events.count, 2)
            guard case .response(let usage, _, _, _) = events[1] else { return XCTFail("Missing usage") }
            XCTAssertEqual(usage?.total, 1200)
        }
    }
}

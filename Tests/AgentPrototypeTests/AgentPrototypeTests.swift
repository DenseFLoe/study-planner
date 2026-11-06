import XCTest
@testable import AgentPrototype

final class AgentPrototypeTests: XCTestCase {
    private func request(id: String = "request-1", url: String = "https://synthetic-provider.invalid/v1/chat/completions",
                         body: String? = nil, headers: [String: String] = [:]) -> PrototypeRequest {
        .init(id: id, provider: "openai", url: url, method: "POST", headers: headers,
              body: body ?? "{\"model\":\"synthetic-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"合成问题\"}]}")
    }

    func testApprovalBindsExactContentAndIsSingleUse() throws {
        var gate = PrototypeApprovalGate()
        let original = request()
        let approval = try gate.prepare(original, snapshotID: "S1")
        XCTAssertEqual(approval.request.body, original.body)
        XCTAssertTrue(approval.summary.contains("本机模拟接口"))
        XCTAssertTrue(try gate.decide(approval, request: original, snapshotID: "S1", allow: true))
        XCTAssertEqual(gate.accepted, 1)
        XCTAssertThrowsError(try gate.decide(approval, request: original, snapshotID: "S1", allow: true))
        XCTAssertThrowsError(try gate.prepare(original, snapshotID: "S1"))
    }

    func testRefusalDoesNotAuthorizeAndCannotBeReused() throws {
        var gate = PrototypeApprovalGate()
        let original = request(), approval = try gate.prepare(original, snapshotID: "S1")
        XCTAssertFalse(try gate.decide(approval, request: original, snapshotID: "S1", allow: false))
        XCTAssertEqual(gate.accepted, 0)
        XCTAssertThrowsError(try gate.decide(approval, request: original, snapshotID: "S1", allow: true))
    }

    func testChangedContentRecipientAndSnapshotFailClosed() throws {
        for (changed, snapshot) in [(request(body: "{\"model\":\"synthetic-chat\",\"messages\":[]}"), "S1"),
                        (request(url: "https://another.invalid/v1/chat/completions"), "S1"), (request(), "S2")] {
            var gate = PrototypeApprovalGate()
            let approval = try gate.prepare(request(), snapshotID: "S1")
            XCTAssertThrowsError(try gate.decide(approval, request: changed, snapshotID: snapshot, allow: true))
            XCTAssertEqual(gate.accepted, 0)
            XCTAssertNil(gate.pending)
        }
    }

    func testExpiredApprovalCannotSend() throws {
        var gate = PrototypeApprovalGate()
        let now = Date(timeIntervalSince1970: 100)
        let approval = try gate.prepare(request(), snapshotID: "S1", now: now)
        XCTAssertThrowsError(try gate.decide(approval, request: request(), snapshotID: "S1", allow: true,
                                           now: now.addingTimeInterval(120)))
        XCTAssertEqual(gate.accepted, 0)
    }

    func testLiveDestinationsCredentialsCookiesAndLargePayloadAreRejected() {
        let invalid = [request(url: "https://api.deepseek.com/chat/completions"),
                       request(url: "https://synthetic-provider.invalid.evil.test/v1/chat/completions"),
                       request(headers: ["Authorization": "Bearer nonempty-test-value"]),
                       request(headers: ["x-api-key": "nonempty-test-value"]),
                       request(headers: ["Cookie": "synthetic=value"]),
                       request(body: String(repeating: "x", count: 524_289))]
        for item in invalid {
            var gate = PrototypeApprovalGate()
            XCTAssertThrowsError(try gate.prepare(item, snapshotID: "S1"))
            XCTAssertEqual(gate.accepted, 0)
        }
    }

    func testNewToolResultRequiresNewApproval() throws {
        var gate = PrototypeApprovalGate()
        let first = request(), approval = try gate.prepare(first, snapshotID: "S1")
        XCTAssertTrue(try gate.decide(approval, request: first, snapshotID: "S1", allow: true))
        let second = request(id: "request-2", body: "{\"model\":\"synthetic-chat\",\"messages\":[{\"role\":\"tool\",\"content\":\"requiredStudyMinutes:120\"}]}")
        let next = try gate.prepare(second, snapshotID: "S1")
        XCTAssertNotEqual(next.requestDigest, approval.requestDigest)
        XCTAssertTrue(next.summary.contains("排程证据"))
        XCTAssertEqual(gate.accepted, 1)
        XCTAssertFalse(try gate.decide(next, request: second, snapshotID: "S1", allow: false))
    }

    func testExistingEngineSuppliesEvidenceAndWhatIfKeepsDistinctSnapshot() throws {
        let fixture = try PrototypeFixture(), adjusted = try PrototypeFixture(extraMinutes: 15)
        XCTAssertEqual(fixture.conflict.requiredStudyMinutes, 120)
        XCTAssertEqual(fixture.conflict.minimumRestMinutes, 15)
        XCTAssertEqual(fixture.conflict.availableMinutes, 120)
        XCTAssertEqual(fixture.conflict.unscheduledMinutes, 60)
        XCTAssertEqual(fixture.conflict.status, "provenRestConflict")
        XCTAssertEqual(adjusted.schedule.status, "scheduled")
        XCTAssertEqual(adjusted.schedule.unscheduledMinutes, 0)
        XCTAssertNotEqual(adjusted.snapshotID, fixture.snapshotID)
        XCTAssertEqual(try PrototypeFixture().snapshotID, fixture.snapshotID)
    }

    func testToolAllowlistAndEvidenceMismatchAreRejected() throws {
        let fixture = try PrototypeFixture()
        XCTAssertThrowsError(try fixture.query(name: "read_file", input: ["date": "2026-09-14"]))
        XCTAssertThrowsError(try fixture.query(name: "query_schedule", input: ["date": "2026-09-15"]))
        XCTAssertThrowsError(try fixture.validateAnswer("缺少 60 分钟", evidence: [fixture.schedule, fixture.conflict]))
        XCTAssertThrowsError(try fixture.validateAnswer(fixture.expectedAnswer, evidence: [fixture.schedule]))
        try fixture.validateAnswer(fixture.expectedAnswer, evidence: [fixture.schedule, fixture.conflict])
    }

    @MainActor func testSDKBridgeWithBothSerializersAndRuntimeRestrictions() async throws {
        let directory = try runtime()
        for provider in ["openai", "anthropic"] {
            var approvals: [PrototypeApproval] = []
            let result = try await PrototypeRunner().run(provider: provider, directory: directory, approve: {
                approvals.append($0); return true
            })
            XCTAssertEqual(result.modelSteps, 3)
            XCTAssertEqual(result.executedTools, 2)
            XCTAssertEqual(result.externalRequests, 0)
            XCTAssertEqual(result.restrictions.count, 4)
            XCTAssertTrue(result.restrictions.values.allSatisfy { $0 })
            XCTAssertEqual(approvals.count, 3)
            XCTAssertFalse(approvals[0].request.body.contains("requiredStudyMinutes"))
            XCTAssertTrue(approvals[1].request.body.contains("requiredStudyMinutes"))
            XCTAssertTrue(approvals[2].request.body.contains("E2"))
        }
    }

    @MainActor func testSDKRefusalAfterFirstQueryStopsBeforeEvidenceTransmission() async throws {
        let runner = PrototypeRunner(), directory = try runtime()
        var requests = 0
        do {
            _ = try await runner.run(provider: "openai", directory: directory, approve: { _ in
                requests += 1; return requests == 1
            })
            XCTFail("Refusal must stop")
        } catch {
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(runner.sentToSimulator, 1)
            XCTAssertEqual(runner.evidence.count, 1)
        }
    }

    @MainActor private func runtime() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/agent-prototype/payload")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Optional SDK runtime absent; run bash Scripts/prepare-agent-prototype.sh first")
        }
        return directory
    }
}

import XCTest
@testable import StudyPlanner

final class AssistantNativeProtocolTests: XCTestCase {
    private actor Replies: AssistantTransport {
        nonisolated let simulated = true
        let responses: [String]
        private(set) var requests: [AssistantRequest] = []
        init(_ responses: [String]) { self.responses = responses }
        func send(_ request: AssistantRequest, key: String) async throws -> String {
            let index = requests.count; requests.append(request)
            guard index < responses.count else { throw AssistantError.protocolError }
            return responses[index]
        }
    }
    private func call(_ id: String, name: String = "inspect_rules", input: [String: Any] = [:]) throws -> [String: Any] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": try AssistantWire.encode(input)]]
    }
    private func response(_ calls: [[String: Any]] = [], text: String = "已核对", reason: String? = nil,
                          reasoning: String? = nil) throws -> String {
        var message: [String: Any] = ["role": "assistant", "content": text, "tool_calls": calls]
        message["reasoning_content"] = reasoning
        return try AssistantWire.encode(["choices": [["finish_reason": reason ?? (calls.isEmpty ? "stop" : "tool_calls"), "message": message]]])
    }
    @MainActor private func run(_ transport: Replies, configuration: AssistantConfiguration = AssistantSimulation.configuration(),
                               evidence: @escaping @MainActor (AssistantToolEvidence) -> Void = { _ in }) async throws -> String {
        let snapshot = AssistantSimulation.snapshot()
        return try await AssistantRunner().run(configuration: configuration, messages: [.init(role: "user", content: "合成查询")],
            snapshot: snapshot, key: "", transport: transport, currentSnapshotID: { snapshot.id },
            approve: { _ in true }, activity: { _ in }, evidence: evidence)
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    @MainActor func testBatchToolResultsRetainCallIDsAndDeepSeekReasoning() async throws {
        let transport = Replies([try response([call("first"), call("second")], reasoning: "合成推理上下文"), try response()])
        var config = AssistantSimulation.configuration(provider: .deepseek); config.model = "deepseek-reasoner"
        var evidence: [AssistantToolEvidence] = []
        let answer = try await run(transport, configuration: config, evidence: { evidence.append($0) })
        XCTAssertEqual(answer, "已核对"); XCTAssertEqual(evidence.map(\.id), ["E1", "E2"])
        let requests = await transport.requests
        let messages = try XCTUnwrap(object(requests[1].body)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[2]["reasoning_content"] as? String, "合成推理上下文")
        XCTAssertEqual(messages.suffix(2).compactMap { $0["tool_call_id"] as? String }, ["first", "second"])
        XCTAssertEqual(requests[1].categories.count, 1)
    }
    @MainActor func testReasoningModelsUseDeveloperRoleAndCompletionLimit() async throws {
        for model in ["o3", "o4-mini", "gpt-5", "gpt-5.1"] {
            let transport = Replies([try response()])
            var config = AssistantSimulation.configuration(); config.model = model
            _ = try await run(transport, configuration: config)
            let requests = await transport.requests, root = try object(XCTUnwrap(requests.first).body)
            XCTAssertEqual(root["max_completion_tokens"] as? Int, 4096); XCTAssertNil(root["max_tokens"])
            XCTAssertEqual((root["messages"] as? [[String: Any]])?.first?["role"] as? String, "developer")
        }
    }
    @MainActor func testAnthropicSystemAndBatchResultsUseMessagesProtocol() async throws {
        let first = try AssistantWire.encode(["stop_reason": "tool_use", "content": [
            ["type": "text", "text": "先查询"],
            ["type": "tool_use", "id": "one", "name": "inspect_rules", "input": [:]],
            ["type": "tool_use", "id": "two", "name": "inspect_rules", "input": [:]]
        ]])
        let last = try AssistantWire.encode(["stop_reason": "end_turn", "content": [["type": "text", "text": "已核对"]]])
        let transport = Replies([first, last])
        _ = try await run(transport, configuration: AssistantSimulation.configuration(provider: .anthropic))
        let requests = await transport.requests, root = try object(requests[1].body)
        XCTAssertTrue((root["system"] as? String)?.contains("本机日期：2026-09-14") == true)
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertFalse(messages.contains { $0["role"] as? String == "system" })
        let results = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["one", "two"])
        XCTAssertEqual(requests[1].categories.count, 1)
    }
    @MainActor func testMalformedBatchNeverExecutesItsValidFirstTool() async throws {
        let invalidCalls = [
            try call("bad", name: "run_command"),
            try call("bad", name: "list_courses", input: [:]),
            try call("bad", input: ["extra": "value"]),
            try call("bad", name: "list_courses", input: ["offset": 0]),
            try call("bad", name: "list_courses", input: ["offset": String(repeating: "0", count: 129)]),
            try call("same")
        ]
        for bad in invalidCalls {
            let transport = Replies([try response([call("same"), bad])])
            var count = 0
            do { _ = try await run(transport, evidence: { _ in count += 1 }); XCTFail("Invalid batch accepted") }
            catch { XCTAssertEqual(error as? AssistantError, .protocolError) }
            XCTAssertEqual(count, 0)
        }
    }
    @MainActor func testTruncatedMalformedAndEmptyAnswersNeverSucceed() async throws {
        for reply in ["{}", "{", try response(reason: "length"), try response(text: " "),
                      try response([call("call")], reason: "stop"), try response() + " trailing"] {
            do { _ = try await run(Replies([reply])); XCTFail("Incomplete response accepted") } catch {}
        }
    }
    @MainActor func testRequestAndToolLimitsStopNativeLoop() async throws {
        let responses = try (0..<8).map { try response([call("call-\($0)")]) }
        let transport = Replies(responses)
        do { _ = try await run(transport); XCTFail("Request limit ignored") }
        catch { XCTAssertEqual(error as? AssistantError, .limit) }
        let sent = await transport.requests; XCTAssertEqual(sent.count, 8)
        let batches = try (0..<5).map { batch in try response((0..<6).map { try call("call-\(batch)-\($0)") }) }
        var count = 0
        do { _ = try await run(Replies(batches), evidence: { _ in count += 1 }); XCTFail("Tool limit ignored") }
        catch { XCTAssertEqual(error as? AssistantError, .limit) }
        XCTAssertEqual(count, 24)
    }
    @MainActor func testRepeatedCallIDAcrossResponsesIsRejected() async throws {
        let reply = try response([call("repeated")])
        var count = 0
        do { _ = try await run(Replies([reply, reply]), evidence: { _ in count += 1 }); XCTFail("Duplicate call accepted") }
        catch { XCTAssertEqual(error as? AssistantError, .protocolError) }
        XCTAssertEqual(count, 1)
    }
}

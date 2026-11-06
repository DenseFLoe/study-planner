import XCTest
import StudyCore
@testable import StudyPlanner

final class AssistantWireTests: XCTestCase {
    private func config(_ provider: AssistantProvider) -> AssistantConfiguration {
        .init(provider: provider, endpoint: provider.endpoint, model: "synthetic-model")
    }
    func testProviderContractsUseDocumentedDistinctBodiesAndDefaultTier() throws {
        for provider in AssistantProvider.allCases {
            let request = try AssistantWire.request(configuration: config(provider), key: "fixture-key",
                                                    question: "测试问题", evidence: "[E1] 测试证据")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(request.url?.absoluteString, provider.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertEqual(json["stream"] as? Bool, false)
            XCTAssertNil(json["tools"]); XCTAssertNil(json["previous_response_id"])
            XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains("fixture-key"))
            if provider == .openAI {
                XCTAssertEqual(json["store"] as? Bool, false)
                XCTAssertEqual(json["max_output_tokens"] as? Int, 4096)
                XCTAssertEqual(json["service_tier"] as? String, "default")
                XCTAssertNil(json["messages"])
            } else {
                XCTAssertEqual((json["messages"] as? [[String: Any]])?.count, 2)
                XCTAssertEqual(json["max_tokens"] as? Int, 4096)
                XCTAssertNil(json["service_tier"]); XCTAssertNil(json["max_output_tokens"])
            }
        }
    }
    func testUnsafeDestinationsAndInvalidKeysRejectedBeforeTransport() throws {
        for endpoint in ["http://example.com/chat", "https://user:secret@example.com/chat", "https://example.com/chat?key=secret", "https://example.com/chat#secret", "file:///tmp/request", "https://example.com"] {
            var config = config(.openAI); config.endpoint = endpoint
            XCTAssertThrowsError(try config.validatedURL())
        }
        XCTAssertThrowsError(try AssistantWire.request(configuration: config(.openAI), key: "secret\r\nInjected: yes", question: "q", evidence: "e"))
        var emptyModel = config(.openAI); emptyModel.model = " "
        XCTAssertThrowsError(try AssistantWire.request(configuration: emptyModel, key: "fixture", question: "q", evidence: "e"))
    }
    func testResponseFixturesAndDeepSeekReasoningIsExcluded() throws {
        let response = Data(#"{"status":"completed","output":[{"type":"reasoning","summary":"secret"},{"type":"message","content":[{"type":"output_text","text":"根据[E1]"}]}]}"#.utf8)
        XCTAssertEqual(try AssistantWire.answer(data: response, status: 200, provider: .openAI), "根据[E1]")
        let chat = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"事实[E2]","reasoning_content":"private reasoning"}}]}"#.utf8)
        for provider in [AssistantProvider.xAI, .deepSeek] {
            XCTAssertEqual(try AssistantWire.answer(data: chat, status: 200, provider: provider), "事实[E2]")
        }
    }
    func testEmptyTruncatedRefusedMalformedAndOversizedResponsesFailClosed() {
        let fixtures: [(String, AssistantProvider, AssistantError)] = [
            (#"{"status":"incomplete","output":[]}"#, .openAI, .incomplete),
            (#"{"status":"completed","output":[]}"#, .openAI, .empty),
            (#"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#, .deepSeek, .incomplete),
            (#"{"choices":[{"finish_reason":"stop","message":{"content":" "}}]}"#, .xAI, .empty),
            (#"{"choices":[{"finish_reason":"tool_calls","message":{}}]}"#, .xAI, .incomplete),
            ("data: partial", .deepSeek, .invalidResponse), ("{", .openAI, .invalidResponse)
        ]
        for (text, provider, expected) in fixtures {
            XCTAssertThrowsError(try AssistantWire.answer(data: Data(text.utf8), status: 200, provider: provider)) {
                XCTAssertEqual($0 as? AssistantError, expected)
            }
        }
        XCTAssertThrowsError(try AssistantWire.answer(data: Data(repeating: 32, count: 1_048_577), status: 200, provider: .openAI))
    }
    func testHTTPFailuresNeverEchoRemoteBodyOrCredentials() {
        for (status, expected) in [(401, AssistantError.unauthorized), (403, .unauthorized), (429, .rateLimited), (404, .unavailable), (500, .network), (504, .timeout), (302, .rejected)] {
            XCTAssertThrowsError(try AssistantWire.answer(data: Data("secret-key returned by proxy".utf8), status: status, provider: .openAI)) {
                XCTAssertEqual($0 as? AssistantError, expected)
                XCTAssertFalse($0.localizedDescription.contains("secret-key"))
            }
        }
        XCTAssertEqual(AssistantError.safe(URLError(.timedOut)), .timeout)
        XCTAssertEqual(AssistantError.safe(CancellationError()), .cancelled)
    }
}

private actor AssistantMockTransport: AssistantTransport {
    var requests: [URLRequest] = []
    var pending: CheckedContinuation<String, Error>?
    func send(_ request: URLRequest, provider: AssistantProvider) async throws -> String {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ result: Result<String, Error>) { pending?.resume(with: result); pending = nil }
    func waitForStart() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pending == nil {
            guard ContinuousClock.now < deadline else { throw AssistantError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    var count: Int { requests.count }
}

@MainActor final class AssistantSessionTests: XCTestCase {
    private func session(_ transport: AssistantMockTransport) -> AssistantSession {
        let session = AssistantSession(transport: transport, defaults: nil)
        session.configuration.model = "mock"; session.key = "synthetic-key"
        return session
    }
    func testPreviewIsLocalAndDoubleSubmitSendsOnlyOnce() async throws {
        let transport = AssistantMockTransport()
        let actual = self.session(transport), state = PlannerState()
        await actual.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
        var count = await transport.count; XCTAssertEqual(count, 0)
        XCTAssertNotNil(actual.preview)
        actual.send(currentState: state); actual.send(currentState: state)
        try await transport.waitForStart()
        count = await transport.count; XCTAssertEqual(count, 1)
        await transport.finish(.success("合成回答")); await actual.waitForRequest()
        XCTAssertEqual(actual.answer, "合成回答"); XCTAssertNotNil(actual.answeredPreview)
        XCTAssertFalse(actual.busy)
    }
    func testStateChangeInvalidatesConsentBeforeSending() async {
        let transport = AssistantMockTransport(), session = session(transport)
        var state = PlannerState()
        await session.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
        state.settings.minimumScheduleUnit = 30
        session.send(currentState: state)
        let count = await transport.count; XCTAssertEqual(count, 0)
        XCTAssertNil(session.preview); XCTAssertTrue(session.message!.contains("已变化"))
    }
    func testCancelCloseCourseAndProviderChangeSuppressLateAnswer() async throws {
        for action in 0..<4 {
            let transport = AssistantMockTransport(), session = session(transport), state = PlannerState()
            await session.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
            session.send(currentState: state); try await transport.waitForStart()
            switch action {
            case 0: session.close()
            case 1: session.switchProvider(.deepSeek)
            default: session.invalidate() // same path used by date/course changes and Cancel
            }
            await transport.finish(.success("迟到回答"))
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(session.answer.isEmpty); XCTAssertFalse(session.busy); XCTAssertNil(session.preview)
            if action < 2 { XCTAssertTrue(session.key.isEmpty) }
        }
    }
    func testFailureRequiresFreshPreviewAndCanRecover() async throws {
        let transport = AssistantMockTransport(), session = session(transport), state = PlannerState()
        await session.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
        session.send(currentState: state); try await transport.waitForStart()
        await transport.finish(.failure(AssistantError.rateLimited)); await session.waitForRequest()
        session.send(currentState: state)
        var count = await transport.count; XCTAssertEqual(count, 1)
        XCTAssertNotNil(session.message); XCTAssertNil(session.preview)
        await session.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
        session.send(currentState: state); try await transport.waitForStart()
        await transport.finish(.success("恢复成功")); await session.waitForRequest()
        count = await transport.count; XCTAssertEqual(count, 2); XCTAssertEqual(session.answer, "恢复成功")
    }
    func testConfigurationPersistenceContainsNoKeyQuestionAnswerOrData() async throws {
        let suite = "AssistantTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = AssistantMockTransport(), session = AssistantSession(transport: transport, defaults: defaults)
        session.configuration.model = "mock"; session.key = "synthetic-secret"; session.question = "private-question"
        let state = PlannerState()
        await session.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
        session.send(currentState: state); try await transport.waitForStart()
        await transport.finish(.success("private-answer")); await session.waitForRequest()
        let data = try XCTUnwrap(defaults.data(forKey: AssistantSession.defaultsKey))
        let json = String(decoding: data, as: UTF8.self)
        for secret in ["synthetic-secret", "private-question", "private-answer", "课程"] { XCTAssertFalse(json.contains(secret)) }
        let restored = AssistantSession(transport: transport, defaults: defaults)
        XCTAssertEqual(restored.configuration.model, "mock"); XCTAssertTrue(restored.key.isEmpty); XCTAssertTrue(restored.answer.isEmpty)
    }
}

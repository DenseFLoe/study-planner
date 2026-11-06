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

import XCTest
@testable import StudyPlanner

/// URLProtocol intercepts every fixture request; no socket or external service is used.
private final class AssistantFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.url!.lastPathComponent
        if scenario == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        if scenario == "wait" { return }
        let status = scenario == "unauthorized" ? 401 : 200
        let type = scenario == "stream" ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data: Data
        switch scenario {
        case "tool": data = Data(#"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_fixture","type":"function","function":{"name":"inspect_runtime","arguments":"{}"}}]}}]}"#.utf8)
        case "oversized": data = Data(repeating: 32, count: 1_048_577)
        case "broken": data = Data("{partial".utf8)
        case "unauthorized": data = Data("secret must not appear".utf8)
        default: data = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"mock [E1]"}}]}"#.utf8)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AssistantHTTPTests: XCTestCase, @unchecked Sendable {
    private func transport() -> AssistantHTTPTransport {
        .init(makeConfiguration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AssistantFixtureProtocol.self]
            return config
        })
    }
    private func request(_ scenario: String) -> URLRequest {
        URLRequest(url: URL(string: "https://fixture.invalid/\(scenario)")!)
    }
    func testTransportDecodesBoundedCompleteResponse() async throws {
        let value = try await transport().send(request("success"), provider: .deepSeek)
        XCTAssertEqual(value, "mock [E1]")
    }
    func testTransportDecodesToolCallsWithoutTreatingThemAsEmptyAnswers() async throws {
        let reply = try await transport().turn(request("tool"), provider: .deepSeek)
        XCTAssertTrue(reply.text.isEmpty); XCTAssertEqual(reply.calls.first?.name, "inspect_runtime")
    }
    func testTransportRejectsStreamBrokenOversizedAndHTTPFailure() async {
        for (scenario, expected) in [("stream", AssistantError.incomplete), ("broken", .invalidResponse),
                                     ("oversized", .tooLarge), ("unauthorized", .unauthorized), ("timeout", .timeout)] {
            do {
                _ = try await transport().send(request(scenario), provider: .xAI)
                XCTFail("Expected \(scenario) to fail")
            } catch { XCTAssertEqual(error as? AssistantError, expected) }
        }
    }
    func testCancellationStopsWaitingTransport() async throws {
        let transport = transport(), request = request("wait")
        let task = Task { try await transport.send(request, provider: .xAI) }
        try await Task.sleep(for: .milliseconds(25))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned an answer") }
        catch { XCTAssertEqual(error as? AssistantError, .cancelled) }
    }
}

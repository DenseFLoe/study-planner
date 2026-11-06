import XCTest
@testable import StudyPlanner

private final class AssistantIntercept: URLProtocol, @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
    }
    private static let storage = Storage()
    static func reset() { storage.lock.withLock { storage.requests = [] } }
    static var requests: [URLRequest] { storage.lock.withLock { storage.requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.storage.lock.withLock { Self.storage.requests.append(request) }
        guard request.url?.host == "assistant-simulator.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let isFailure = request.url?.path.contains("failure") == true
        let status = isFailure ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AssistantHTTPTests: XCTestCase, @unchecked Sendable {
    func testNativeTransportUsesApprovedBytesAndSeparateAuthenticationWithoutNetwork() async throws {
        for provider in [AssistantProvider.openai, .anthropic] {
            AssistantIntercept.reset()
            let config = AssistantSimulation.configuration(provider: provider)
            let body = "{\"model\":\"synthetic-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"合成\"}]}"
            let request = AssistantRequest(id: "one", configuration: config, url: try config.endpoint().absoluteString, body: body)
            let transport = AssistantHTTPTransport(configurationFactory: {
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AssistantIntercept.self]; return config
            })
            let result = try await transport.send(request, key: "synthetic-credential-only")
            XCTAssertEqual(result, "{\"ok\":true}")
            let captured = try XCTUnwrap(AssistantIntercept.requests.first)
            XCTAssertEqual(AssistantIntercept.requests.count, 1)
            XCTAssertEqual(captured.url?.absoluteString, request.url)
            XCTAssertEqual(captured.httpMethod, "POST")
            var sent = captured.httpBody
            if sent == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024), bytes = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                }
                sent = bytes
            }
            XCTAssertEqual(sent, Data(body.utf8))
            let auth = provider == .anthropic ? "x-api-key" : "Authorization"
            XCTAssertEqual(captured.value(forHTTPHeaderField: auth), provider == .anthropic ? "synthetic-credential-only" : "Bearer synthetic-credential-only")
            XCTAssertNil(captured.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.details.contains("synthetic-credential-only"))
            XCTAssertFalse(String(decoding: try assistantJSON(request), as: UTF8.self).contains("synthetic-credential-only"))
        }
    }
    func testTransportFailureIsSanitizedAndNeverAutomaticallyRetries() async throws {
        AssistantIntercept.reset()
        var config = AssistantSimulation.configuration(); config.baseURL += "/failure"
        let request = AssistantRequest(id: "one", configuration: config, url: try config.endpoint().absoluteString,
            body: "{\"model\":\"synthetic-chat\",\"messages\":[]}")
        let transport = AssistantHTTPTransport(configurationFactory: {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AssistantIntercept.self]; return config
        })
        do { _ = try await transport.send(request, key: "synthetic-credential-only"); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? AssistantError, .network) }
        XCTAssertEqual(AssistantIntercept.requests.count, 1)
    }
}

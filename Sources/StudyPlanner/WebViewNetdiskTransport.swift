import Foundation
import WebKit
import StudyCore

/// Talks to the netdisk from inside the built-in browser, so private shares and passcode-protected
/// shares use the session the user already has. Tokens never leave this window.
@MainActor
final class WebViewNetdiskTransport: NSObject, NetdiskTransport, WKScriptMessageHandler {
    private static let handlerName = "quarkCrawler"
    let webView: WKWebView
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var requestCounter = 0

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let source = Self.resource()
        if !source.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: Self.handlerName)
    }

    static var script: String { resource() }
    private static func resource() -> String {
        guard let url = Bundle.module.url(forResource: "QuarkCrawler", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }

    /// Points the browser at the share so the injected reader is running on the right origin.
    func loadShare(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
    func stop() {
        for continuation in pending.values {
            continuation.resume(throwing: NetdiskAPIError.http(-1, "已取消"))
        }
        pending.removeAll()
        webView.stopLoading()
    }

    func get(path: String, query: [String: String]) async throws -> Data {
        try await call(path: path, query: query, body: nil)
    }
    func post(path: String, query: [String: String], body: [String: NetdiskJSON]) async throws -> Data {
        try await call(path: path, query: query, body: body)
    }
    /// The page bridge answers with an envelope; unwrap it and hand the provider payload on.
    nonisolated static func payload(fromPage data: Data) throws -> Data {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw NetdiskAPIError.malformed("抓取脚本响应") }
        guard envelope.ok else {
            throw NetdiskAPIError.notLoggedIn(envelope.error ?? "页面请求失败。")
        }
        let status = envelope.status ?? 200
        guard (200..<300).contains(status) else { throw NetdiskAPIError.http(status, "") }
        return Data((envelope.text ?? "").utf8)
    }

    private func call(path: String, query: [String: String], body: [String: NetdiskJSON]?) async throws -> Data {
        guard webView.url != nil else {
            throw NetdiskAPIError.notLoggedIn("请先在右侧打开分享链接，等页面加载完成后再读取。")
        }
        let requestID = UUID().uuidString
        let script: String
        let function = body == nil ? "get" : "post"
        if body == nil {
            script = """
            const bridge = window.studyQuarkCrawler;
            if (!bridge) return JSON.stringify({ ok: false, error: '抓取脚本未注入' });
            return JSON.stringify(await bridge.get(\(Self.literal(path)), \(Self.literal(query))));
            """
        } else {
            script = """
            const bridge = window.studyQuarkCrawler;
            if (!bridge) return JSON.stringify({ ok: false, error: '抓取脚本未注入' });
            return JSON.stringify(await bridge.\(function)(\(Self.literal(path)), \(Self.literal(query)), \(Self.jsonLiteral(body ?? [:]))));
            """
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            Task { @MainActor in
                do {
                    let value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                                                                     contentWorld: .page)
                    guard let text = value as? String, let data = text.data(using: .utf8) else {
                        throw NetdiskAPIError.malformed("抓取脚本没有返回结果")
                    }
                    try self.finish(requestID, with: .success(data))
                } catch {
                    if error is NetdiskAPIError {
                        try? self.finish(requestID, with: .failure(error))
                    } else {
                        try? self.finish(requestID, with: .failure(
                            NetdiskAPIError.notLoggedIn("无法在页面里发起请求：\(error.localizedDescription)。请确认分享页面已经打开。")))
                    }
                }
            }
        }
    }

    private func finish(_ requestID: String, with result: Result<Data, Error>) throws {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(with: result)
    }

    struct Envelope: Decodable {
        var ok: Bool
        var status: Int?
        var text: String?
        var error: String?
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {}

    /// JSON literals are built by encoding, never by string interpolation.
    private static func literal(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
    private static func jsonLiteral(_ body: [String: NetdiskJSON]) -> String {
        "{" + body.sorted { $0.key < $1.key }
            .map { let key = literal($0.key); return key + ": " + $0.value.javaScriptLiteral }
            .joined(separator: ", ") + "}"
    }
}

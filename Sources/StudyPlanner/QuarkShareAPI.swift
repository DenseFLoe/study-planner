import Foundation
import StudyCore

/// A JSON value that is safe to send across actors.
enum NetdiskJSON: Sendable {
    case string(String), number(Double), bool(Bool)
    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        }
    }
    var javaScriptLiteral: String {
        switch self {
        case .string(let value):
            guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
}

/// How the crawler talks to the netdisk. Public shares use the plain transport; shares that
/// require a signed-in session can fall back to requests from the embedded WebView.
protocol NetdiskTransport: Sendable {
    func get(path: String, query: [String: String]) async throws -> Data
    func post(path: String, query: [String: String], body: [String: NetdiskJSON]) async throws -> Data
}

enum NetdiskAPIError: LocalizedError, Equatable {
    case badLink
    case needsPasscode
    case wrongPasscode
    case shareGone(String)
    case provider(code: Int, message: String)
    case notLoggedIn(String)
    case malformed(String)
    case http(Int, String)
    public var errorDescription: String? {
        switch self {
        case .badLink: return "这不是有效的夸克网盘分享链接。"
        case .needsPasscode: return "这个分享需要提取码，请填写后再读取。"
        case .wrongPasscode: return "提取码不正确。"
        case .shareGone(let message): return message.isEmpty ? "分享已失效或被取消。" : message
        case .provider(_, let message): return message.isEmpty ? "网盘返回了错误。" : message
        case .notLoggedIn(let message): return message
        case .malformed(let detail): return "网盘返回的数据无法识别：\(detail)"
        case .http(let code, let detail):
            return code == 429 ? "网盘提示请求过于频繁，请稍后再试。" : "网盘请求失败（HTTP \(code)）\(detail)"
        }
    }
}

/// Minimal read-only client for the share endpoints. It never saves, moves or deletes anything.
struct QuarkShareAPI: Sendable {
    static let base = "https://pan.quark.cn"
    /// The website appends these to every clouddrive call; harmless and keeps the request familiar.
    static let appQuery = ["pr": "ucpro", "fr": "pc", "uc_param_str": ""]
    /// Sorted by the app instead of the provider, because the provider compares names byte by byte
    /// and would place `第10讲` before `第2讲`. The web app's own default is an empty sort, so this is
    /// a supported request.
    static let sortOrder = ""
    let transport: NetdiskTransport
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    struct Token: Sendable {
        var stoken: String
        var title: String
        var needsPasscode: Bool
    }

    /// Unwraps the envelope the in-page bridge returns into the provider's own JSON.
    static func payload(fromPage data: Data) throws -> Data {
        try WebViewNetdiskTransport.payload(fromPage: data)
    }

    /// One entry as the provider reports it.
    struct Item: Decodable, Sendable {
        var fid: String
        var shareFidToken: String?
        var fileName: String
        var dir: Bool?
        var fileType: Int?
        var category: Int?
        var formatType: String?
        var size: Int64?
        var duration: Double?
        var videoWidth: Int?
        var videoHeight: Int?
        var updatedAt: Double?
        var includeItems: Int?
        var riskType: Int?
        var ban: Bool?
        var badContent: Bool?
        var status: Int?
    }

    private struct DetailPayload: Decodable {
        var list: [Item]?
    }
    private struct DetailMetadata: Decodable {
        var page: Int?
        var size: Int?
        var count: Int?
        var total: Int?
        // `convertFromSnakeCase` leaves a leading underscore in place, so `_count` would not become
        // `count`. These keys are spelled out: the page total is what keeps the crawl complete.
        private enum CodingKeys: String, CodingKey {
            case page = "_page", size = "_size", count = "_count", total = "_total"
        }
    }
    private struct DetailEnvelope: Decodable {
        var status: Int?
        var code: Int?
        var message: String?
        var data: DetailPayload?
        var metadata: DetailMetadata?
    }
    private struct TokenPayload: Decodable {
        var stoken: String?
        var title: String?
        var passcode: String?
    }
    private struct TokenEnvelope: Decodable {
        var status: Int?
        var code: Int?
        var message: String?
        var data: TokenPayload?
    }

    /// Reads the share token for a link, reporting whether a passcode is required.
    func token(pwdID: String, passcode: String?) async throws -> Token {
        let body: [String: NetdiskJSON] = ["pwd_id": .string(pwdID),
                                            "support_visit_limit_private_share": .bool(true),
                                            "passcode": .string(passcode ?? "")]
        let data = try await transport.post(path: "/1/clouddrive/share/sharepage/token",
                                            query: Self.appQuery, body: body)
        let envelope: TokenEnvelope
        do { envelope = try decoder.decode(TokenEnvelope.self, from: data) }
        catch { throw NetdiskAPIError.malformed("令牌响应") }
        try Self.check(status: envelope.status, code: envelope.code, message: envelope.message)
        guard let payload = envelope.data, let stoken = payload.stoken, !stoken.isEmpty else {
            throw NetdiskAPIError.malformed("缺少 stoken")
        }
        let wantsPasscode = payload.passcode == "1" || payload.passcode?.lowercased() == "true"
        return Token(stoken: stoken, title: NetdiskTitles.displayName(payload.title ?? ""),
                     needsPasscode: wantsPasscode && (passcode ?? "").isEmpty)
    }

    struct Page: Sendable {
        var items: [Item]
        var total: Int
        var page: Int
        var size: Int
        var hasMore: Bool
    }

    /// Lists one folder of the share. Subdirectories need only `pdirFid` and the same stoken.
    func list(pwdID: String, stoken: String, directoryFID: String, page: Int, size: Int,
              passcode: String?) async throws -> Page {
        var query = Self.appQuery
        query["ver"] = "2"
        query["pwd_id"] = pwdID
        query["stoken"] = stoken
        query["pdir_fid"] = directoryFID
        query["force"] = "0"
        query["_page"] = String(page)
        query["_size"] = String(size)
        query["_fetch_banner"] = "0"
        query["_fetch_share"] = "0"
        query["fetch_relate_conversation"] = "0"
        query["_fetch_total"] = "1"
        query["_sort"] = Self.sortOrder
        if let passcode, !passcode.isEmpty { query["passcode"] = passcode }
        let data = try await transport.get(path: "/1/clouddrive/share/sharepage/detail", query: query)
        let envelope: DetailEnvelope
        do { envelope = try decoder.decode(DetailEnvelope.self, from: data) }
        catch { throw NetdiskAPIError.malformed("目录响应（\(String(describing: error))）") }
        try Self.check(status: envelope.status, code: envelope.code, message: envelope.message)
        let items = envelope.data?.list ?? []
        // The provider reports how many entries the folder holds. Its `_size` cannot be trusted for
        // pagination because it shrinks when the provider de-duplicates a page, which would stop the
        // crawl early and silently drop lessons. The requested page size is the honest signal, and
        // the accumulated count decides when the folder is complete.
        let metadata = envelope.metadata
        let total = metadata?.count ?? metadata?.total ?? items.count
        return Page(items: items, total: total, page: max(1, metadata?.page ?? page),
                    size: max(1, size), hasMore: !items.isEmpty)
    }

    /// Turns a provider error into something the window can show without inventing a cause.
    static func check(status: Int?, code: Int?, message: String?) throws {
        let resolvedCode = code ?? 0
        let resolvedStatus = status ?? 200
        if resolvedCode == 0, (200..<300).contains(resolvedStatus) { return }
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch resolvedCode {
        case 41006, 41009, 41010, 41012:
            throw NetdiskAPIError.shareGone(text)
        case 41008, 41011:
            throw NetdiskAPIError.needsPasscode
        case 41013, 41014, 41015:
            throw NetdiskAPIError.wrongPasscode
        case 31001, 31002, 31003:
            throw NetdiskAPIError.notLoggedIn(text.isEmpty ? "该分享需要登录夸克账号，请在页面里登录后重试。" : text)
        case 42900, 42901:
            throw NetdiskAPIError.http(429, text)
        default:
            throw NetdiskAPIError.provider(code: resolvedCode, message: text)
        }
    }
}

/// Talks to the netdisk with URLSession. Used for public shares, tests and `--netdisk-probe`.
final class PlainNetdiskTransport: NetdiskTransport, @unchecked Sendable {
    private let session: URLSession
    private let interval: Duration
    private let gate = NetdiskRateGate()

    init(session: URLSession? = nil, minimumInterval: Duration = .milliseconds(500)) {
        self.interval = minimumInterval
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                    + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "Referer": "https://pan.quark.cn/",
                "Accept": "application/json, text/plain, */*"
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    func get(path: String, query: [String: String]) async throws -> Data {
        try await send(path: path, query: query, body: nil)
    }
    func post(path: String, query: [String: String], body: [String: NetdiskJSON]) async throws -> Data {
        try await send(path: path, query: query, body: body)
    }

    private func send(path: String, query: [String: String], body: [String: NetdiskJSON]?) async throws -> Data {
        guard var components = URLComponents(string: QuarkShareAPI.base + path) else {
            throw NetdiskAPIError.badLink
        }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Share tokens may contain '+'. URLComponents leaves it literal in query strings, while
        // the provider interprets it as a space and rejects the token.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw NetdiskAPIError.badLink }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0.anyValue })
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<4 {
            try Task.checkCancellation()
            await gate.wait(interval)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                let prefix = String(decoding: data.prefix(200), as: UTF8.self)
                let html = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased().hasPrefix("<!doctype html")
                    || prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased().hasPrefix("<html")
                if status == 429 || (500..<600).contains(status) || html {
                    if attempt < 3 {
                        try await Task.sleep(for: .seconds(2 * (attempt + 1)))
                        continue
                    }
                    throw NetdiskAPIError.http(html && status == 200 ? 503 : status,
                                               html ? "（暂时返回网页，目录接口未响应）" : "")
                }
                guard (200..<300).contains(status) else {
                    throw NetdiskAPIError.http(status, prefix)
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NetdiskAPIError {
                throw error
            } catch {
                if attempt == 3 { throw error }
                try await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        throw NetdiskAPIError.http(503, "")
    }
}

/// Serialises requests so a large share is read at a polite pace instead of a burst.
actor NetdiskRateGate {
    private var lastUsed = Date.distantPast
    func wait(_ interval: Duration) async {
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        guard seconds > 0 else { return }
        let elapsed = Date().timeIntervalSince(lastUsed)
        if elapsed < seconds { try? await Task.sleep(for: .seconds(seconds - elapsed)) }
        lastUsed = Date()
    }
}

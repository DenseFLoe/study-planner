import Foundation
import Observation
import Security
import CryptoKit
import StudyCore

enum AssistantVault {
    private static func query(_ configuration: AssistantConfiguration) throws -> [String: Any] {
        let url = try configuration.validatedURL()
        let account = SHA256.hash(data: Data((configuration.provider.rawValue + "|" + url.absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.studyplanner.assistant",
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false]
    }
    static func load(_ configuration: AssistantConfiguration) throws -> String {
        var query = try query(configuration)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { throw AssistantError.key }
        guard status == errSecSuccess, let data = value as? Data,
              let key = String(data: data, encoding: .utf8) else { throw AssistantError.keychain }
        return key
    }
    static func save(_ key: String, configuration: AssistantConfiguration) throws {
        guard !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: { $0.isWhitespace }) else { throw AssistantError.key }
        let query = try query(configuration), data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard status == errSecItemNotFound, SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AssistantError.keychain }
    }
    static func delete(_ configuration: AssistantConfiguration) throws {
        let status = SecItemDelete(try query(configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError.keychain }
    }
}

struct AssistantChatEntry: Identifiable, Sendable {
    let id = UUID()
    var role: String
    var text: String
}

struct AssistantApproval: Identifiable, Sendable {
    let id = UUID()
    var configuration: AssistantConfiguration
    var context: AssistantContext
    var question: String?
    var results: [AssistantToolResult]
    var historyCount: Int
}

@MainActor @Observable
final class AssistantSession {
    var configuration: AssistantConfiguration
    var key = ""
    var question = ""
    private(set) var approval: AssistantApproval?
    private(set) var entries: [AssistantChatEntry] = []
    private(set) var evidence: [AssistantToolResult] = []
    private(set) var busy = false
    private(set) var activity = ""
    var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var history: [AssistantExchange] = []
    @ObservationIgnored private var readContext: (@MainActor () -> AssistantContext)?
    @ObservationIgnored private var requestsThisTurn = 0
    @ObservationIgnored private var usedCallIDs: Set<String> = []
    @ObservationIgnored private var nextResultID = 1
    @ObservationIgnored private var turnHistoryStart = 0
    @ObservationIgnored private var turnEvidenceStart = 0
    @ObservationIgnored private var privateReadsDenied = false
    @ObservationIgnored private let transport: any AssistantAgentTransport
    @ObservationIgnored private let defaults: UserDefaults?
    static let defaultsKey = "studyAssistant.configuration.v1"
    static let maxRequests = 8

    init(transport: any AssistantAgentTransport = AssistantHTTPTransport(), defaults: UserDefaults? = .standard) {
        self.transport = transport; self.defaults = defaults
        configuration = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(AssistantConfiguration.self, from: $0) } ?? .init()
    }

    func switchProvider(_ provider: AssistantProvider) {
        reset(); key = ""; configuration = .init(provider: provider, endpoint: provider.endpoint, model: "")
    }
    func reset() {
        generation = UUID(); task?.cancel(); task = nil
        history = []; entries = []; evidence = []; approval = nil; readContext = nil
        usedCallIDs = []; nextResultID = 1; busy = false; activity = ""; message = nil
    }
    func close() { reset(); key = ""; question = "" }
    func contextChanged() {
        // Do not leave stale course aliases or old tool output in the next request.
        let hadContent = !entries.isEmpty || approval != nil || busy
        reset()
        if hadContent { message = "应用数据已更新，旧查询和授权已清除。请重新提问，我会查看最新数据。" }
    }
    func questionChanged() {
        if approval?.question != nil { approval = nil }
    }
    func stop() {
        guard busy || approval != nil else { return }
        generation = UUID(); task?.cancel(); task = nil; approval = nil; busy = false; activity = ""
        // Incomplete function-call transcripts must never be replayed in a later turn.
        history = Array(history.prefix(turnHistoryStart))
        evidence = Array(evidence.prefix(turnEvidenceStart))
        message = AssistantError.cancelled.localizedDescription
    }

    func prepare(readContext: @escaping @MainActor () -> AssistantContext) {
        guard !busy, approval == nil else { return }
        message = nil
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 6000 else { message = "请输入问题，最多6000字节（约2000个汉字）。"; return }
        // No request or credential read occurs while preparing this local preview.
        self.readContext = readContext
        turnHistoryStart = history.count; turnEvidenceStart = evidence.count
        approval = .init(configuration: configuration, context: readContext(), question: value, results: [], historyCount: history.count)
    }

    func approve(_ id: UUID, includePrivateData: Bool = true) {
        guard !busy, let approved = approval, approved.id == id, let readContext else { return }
        guard approved.configuration == configuration, approved.context.matches(readContext()),
              approved.question == nil || approved.question == question.trimmingCharacters(in: .whitespacesAndNewlines) else {
            contextChanged(); message = "数据、问题或配置已变化，原确认已失效，请重新提问。"; return
        }
        if let question = approved.question {
            // Validate before consuming the question confirmation, so configuration errors can be fixed locally.
            do { _ = try AssistantAgentWire.request(configuration: configuration, key: key, history: []) }
            catch { message = AssistantError.safe(error).localizedDescription; return }
            history.append(.user(question + "\n\n" + approved.context.questionContext))
            entries.append(.init(role: "你", text: question)); requestsThisTurn = 0; privateReadsDenied = false
            self.question = ""
        } else {
            if !includePrivateData { privateReadsDenied = true }
            for var result in approved.results {
                if result.privateData && !includePrivateData {
                    result.content = "[\(result.id)] {\"error\":\"用户拒绝发送此查询结果。请使用已授权信息回答或说明缺少依据，不要再次索取。\"}"
                    result.denied = true; result.privateData = false
                }
                history.append(.tool(result)); evidence.append(result)
            }
        }
        approval = nil
        if let data = try? JSONEncoder().encode(configuration) { defaults?.set(data, forKey: Self.defaultsKey) }
        launch()
    }

    private func launch() {
        busy = true; message = nil; activity = "正在理解问题并查找依据…"
        let token = generation
        task = Task { [weak self] in await self?.run(token: token) }
    }

    private func run(token: UUID) async {
        do {
            while token == generation, !Task.isCancelled {
                guard requestsThisTurn < Self.maxRequests else {
                    throw AssistantAgentLimit.reached
                }
                let config = configuration
                let requestContext = readContext?()
                let request = try AssistantAgentWire.request(configuration: config, key: key, history: history)
                requestsThisTurn += 1
                let reply = try await transport.turn(request, provider: config.provider)
                guard token == generation, !Task.isCancelled else { return }
                guard config == configuration else { reset(); message = "配置已变化，请重新提问。"; return }
                if let requestContext, let latest = readContext?(), !requestContext.matches(latest) {
                    contextChanged(); return
                }
                history.append(.assistant(reply))
                if reply.calls.isEmpty {
                    entries.append(.init(role: "助手", text: reply.text))
                    message = citationWarning(reply.text)
                    busy = false; activity = ""; task = nil; return
                }
                guard let readContext else { throw AssistantError.cancelled }
                guard requestsThisTurn < Self.maxRequests else { throw AssistantAgentLimit.reached }
                let snapshot = readContext()
                var outputs: [AssistantToolResult] = []
                for call in reply.calls {
                    guard usedCallIDs.insert(call.id).inserted else { throw AssistantError.invalidResponse }
                    activity = AssistantTools.definitions.first { $0.name == call.name }?.title ?? "检查工具权限…"
                    let id = "R\(nextResultID)"; nextResultID += 1
                    var output = await Task.detached(priority: .userInitiated) {
                        AssistantTools.execute(call, context: snapshot, id: id)
                    }.value
                    guard token == generation, !Task.isCancelled else { return }
                    if output.privateData && privateReadsDenied {
                        output.content = "[\(id)] {\"error\":\"本轮用户已拒绝发送新增个人数据，不能通过其他工具绕过。请依据已有资料回答或说明不足。\"}"
                        output.privateData = false; output.denied = true
                    }
                    outputs.append(output)
                }
                guard snapshot.matches(readContext()) else { contextChanged(); return }
                if outputs.contains(where: \.privateData) {
                    approval = .init(configuration: config, context: snapshot, question: nil, results: outputs, historyCount: history.count)
                    activity = "已在本机查到资料，等待你确认发送"; busy = false; task = nil
                    return
                }
                for output in outputs { history.append(.tool(output)); evidence.append(output) }
                activity = "正在根据查询结果继续核对…"
            }
        } catch {
            guard token == generation else { return }
            // Roll back the incomplete wire turn, including references that cannot be reused.
            history = Array(history.prefix(turnHistoryStart))
            evidence = Array(evidence.prefix(turnEvidenceStart))
            message = error is AssistantAgentLimit ? "本轮已达到8次请求上限，已停止。可缩小问题后继续；不会自动重试。"
                : AssistantError.safe(error).localizedDescription
            busy = false; activity = ""; task = nil; approval = nil
        }
    }

    private func citationWarning(_ answer: String) -> String? {
        let regex = try! NSRegularExpression(pattern: #"\[R[0-9]+\]"#)
        let text = answer as NSString
        let matches = regex.matches(in: answer, range: NSRange(location: 0, length: text.length))
        let known = Set(evidence.filter { !$0.denied }.map { "[\($0.id)]" })
        if matches.contains(where: { !known.contains(text.substring(with: $0.range)) }) {
            return "回答引用了未授权或不存在的查询编号，请勿采信这些引用。"
        }
        if matches.isEmpty { return "回答未引用查询依据，内容尚未核实；可以继续要求助手查证。" }
        return nil
    }
    func waitForRequest() async { await task?.value }
}

private enum AssistantAgentLimit: Error { case reached }

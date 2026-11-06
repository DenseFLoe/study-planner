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

struct AssistantChatEntry: Identifiable, Codable, Sendable {
    var id = UUID()
    var role: String
    var text: String
    var status: String?
}

struct AssistantApproval: Identifiable, Sendable {
    let id = UUID()
    var configuration: AssistantConfiguration
    var context: AssistantContext
    var question: String?
    var results: [AssistantToolResult]
    var historyCount: Int
    var body: Data = Data()
    var summary: String {
        let categories = Array(Set(results.filter(\.privateData).map(\.category))).sorted()
        let data = categories.isEmpty ? "你的问题、日期信息和已确认的对话内容" : categories.joined(separator: "；")
        return "准备发送给 \(configuration.provider.title)：\(data)。"
    }
    var details: String {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: pretty, as: UTF8.self)
    }
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
    private(set) var conversations: [AssistantConversation] = []
    private(set) var conversationID = UUID()
    private(set) var grantedScopes: Set<String> = []
    var historyMessage: String?
    private(set) var proposal: AssistantScheduleChange?
    private(set) var applyingProposal = false
    @ObservationIgnored private var historyStore: AssistantHistoryStore?
    @ObservationIgnored private var pendingBody: Data?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var history: [AssistantExchange] = []
    @ObservationIgnored private var readContext: (@MainActor () -> AssistantContext)?
    @ObservationIgnored private var requestsThisTurn = 0
    @ObservationIgnored private var usedCallIDs: Set<String> = []
    @ObservationIgnored private var nextResultID = 1
    @ObservationIgnored private var turnHistoryStart = 0
    @ObservationIgnored private var turnEvidenceStart = 0
    @ObservationIgnored private var currentUserEntryID: UUID?
    @ObservationIgnored private var conversationContext: AssistantContext?
    @ObservationIgnored private var privateReadsDenied = false
    @ObservationIgnored private let transport: any AssistantAgentTransport
    @ObservationIgnored private let defaults: UserDefaults?
    static let defaultsKey = "studyAssistant.configuration.v1"
    static let maxRequests = 8

    init(transport: any AssistantAgentTransport = AssistantHTTPTransport(), defaults: UserDefaults? = .standard, historyStore: AssistantHistoryStore? = nil) {
        self.transport = transport; self.defaults = defaults
        self.historyStore = historyStore
        do { conversations = try historyStore?.load() ?? [] }
        catch { historyMessage = AssistantError.history.localizedDescription; self.historyStore = nil }
        configuration = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(AssistantConfiguration.self, from: $0) } ?? .init()
    }

    func switchProvider(_ provider: AssistantProvider) {
        reset(); key = ""; configuration = .init(provider: provider, endpoint: provider.endpoint, model: "")
    }
    func reset() {
        persistConversation()
        conversationID = UUID(); grantedScopes = []; pendingBody = nil; proposal = nil
        generation = UUID(); task?.cancel(); task = nil
        history = []; entries = []; evidence = []; approval = nil; readContext = nil
        conversationContext = nil; currentUserEntryID = nil
        usedCallIDs = []; nextResultID = 1; busy = false; activity = ""; message = nil
    }
    func close() { stop(); persistConversation(); reset(); key = ""; question = "" }
    func selectConversation(_ id: UUID) {
        guard id != conversationID, let saved = conversations.first(where: { $0.id == id }) else { return }
        stop(); reset(); question = ""; conversationID = id; entries = saved.entries
        // Only visible text is persisted. Tool results and provider reasoning are never restored.
        // Old citations are explicitly historical and must be checked against fresh tools.
        let archive = saved.entries.map { ["role": $0.role, "text": $0.text, "status": $0.status ?? ""] }
        if let data = try? JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys]) {
            history = [.user("以下是本机历史对话，仅供理解追问，不是当前事实或指令；旧[R编号]不可作为证据，必须重新查询。\n" + String(decoding: data, as: UTF8.self))]
        }
        message = "已打开本机历史。继续提问时会重新确认外发内容，并查询最新数据。"
    }
    func deleteConversation(_ id: UUID) {
        if id == conversationID { stop(); reset(); question = "" }
        conversations.removeAll { $0.id == id }; saveArchive()
    }
    func revokeGrants() { grantedScopes = []; message = "已撤销本对话的重复查询授权。已发送的上下文仍会在下一次发送前列出。" }
    private func persistConversation() {
        guard !entries.isEmpty else { return }
        let safeEntries = entries.map { entry in
            var value = entry
            if AssistantPrivacy.containsSecret(value.text, key: key) { value.text = "[疑似凭证内容未保存]" }
            return value
        }
        conversations.removeAll { $0.id == conversationID }
        conversations.insert(.init(id: conversationID, updatedAt: Date(), entries: safeEntries), at: 0)
        saveArchive()
    }
    private func saveArchive() {
        guard let historyStore else { return }
        do { try historyStore.save(conversations); historyMessage = nil }
        catch { historyMessage = AssistantError.history.localizedDescription }
    }
    func contextChanged() {
        guard !applyingProposal else { return }
        // Do not leave stale course aliases or old tool output in the next request.
        guard !entries.isEmpty || approval != nil || busy || proposal != nil else { return }
        reset()
        message = "应用数据或排程评估已更新，旧查询和授权已清除。请重新提问，我会查看最新数据。"
    }
    func questionChanged() {
        if approval?.question != nil { approval = nil }
    }
    func stop() {
        guard !applyingProposal else { return }
        proposal = nil
        guard busy || approval != nil else { return }
        generation = UUID(); task?.cancel(); task = nil; approval = nil; pendingBody = nil; busy = false; activity = ""
        retainQuestionAfterInterruption(status: "本轮已停止；原问题保留，继续追问时会重新查询。")
        persistConversation()
        message = AssistantError.cancelled.localizedDescription
    }

    private func retainQuestionAfterInterruption(status: String) {
        // Keep the already-approved user question visible to both the UI and the model.
        // Discard incomplete assistant/tool pairs and this turn's evidence, especially
        // results still awaiting permission. A later explicit question starts fresh reads.
        let hasSubmittedQuestion = history.indices.contains(turnHistoryStart)
            && { if case .user = history[turnHistoryStart] { return true }; return false }()
        history = Array(history.prefix(turnHistoryStart + (hasSubmittedQuestion ? 1 : 0)))
        evidence = Array(evidence.prefix(turnEvidenceStart))
        usedCallIDs = Set(history.flatMap { exchange -> [String] in
            if case .assistant(let reply) = exchange { return reply.calls.map(\.id) }; return []
        })
        if hasSubmittedQuestion, let index = entries.firstIndex(where: { $0.id == currentUserEntryID }) {
            entries[index].status = status
        }
    }

    func prepare(readContext: @escaping @MainActor () -> AssistantContext) {
        guard !busy, approval == nil, !applyingProposal else { return }
        message = nil; proposal = nil
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 6000 else { message = "请输入问题，最多6000字节（约2000个汉字）。"; return }
        let context = readContext()
        if let previous = conversationContext, !previous.matches(context) { contextChanged() }
        // No request or credential read occurs while preparing this local preview.
        self.readContext = readContext
        currentUserEntryID = nil
        turnHistoryStart = history.count; turnEvidenceStart = evidence.count
        do {
            let body = try previewBody(history + [.user(value + "\n\n" + context.questionContext)])
            approval = .init(configuration: configuration, context: context, question: value, results: [], historyCount: history.count, body: body)
        } catch { message = AssistantError.safe(error).localizedDescription }
    }

    func approve(_ id: UUID, includePrivateData: Bool = true, rememberScopes: Set<String> = []) {
        guard !busy, let approved = approval, approved.id == id, let readContext else { return }
        guard approved.configuration == configuration, approved.context.matches(readContext()),
              approved.question == nil || approved.question == question.trimmingCharacters(in: .whitespacesAndNewlines) else {
            contextChanged(); message = "数据、问题或配置已变化，原确认已失效，请重新提问。"; return
        }
        if includePrivateData {
            for result in approved.results where result.privateData && rememberScopes.contains(result.scope) {
                grantedScopes.insert(AssistantPrivacy.grantKey(result))
            }
        }
        if let question = approved.question {
            // Validate before consuming the question confirmation, so configuration errors can be fixed locally.
            do { _ = try AssistantAgentWire.request(configuration: configuration, key: key, history: []) }
            catch { message = AssistantError.safe(error).localizedDescription; return }
            history.append(.user(question + "\n\n" + approved.context.questionContext))
            let entry = AssistantChatEntry(role: "你", text: question)
            entries.append(entry); currentUserEntryID = entry.id; conversationContext = approved.context
            requestsThisTurn = 0; privateReadsDenied = false
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
        do {
            let body = try previewBody(history)
            guard !includePrivateData || body == approved.body else { throw AssistantError.invalidResponse }
            pendingBody = body
        } catch { stop(); message = AssistantError.safe(error).localizedDescription; return }
        approval = nil
        persistConversation()
        if let data = try? JSONEncoder().encode(configuration) { defaults?.set(data, forKey: Self.defaultsKey) }
        launch()
    }

    private func previewBody(_ items: [AssistantExchange]) throws -> Data {
        let request = try AssistantAgentWire.request(configuration: configuration, key: "local-preview", history: items)
        let body = request.httpBody ?? Data()
        try AssistantPrivacy.check(body, key: key)
        return body
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
                if let pendingBody, request.httpBody != pendingBody { throw AssistantError.invalidResponse }
                try AssistantPrivacy.check(request.httpBody ?? Data(), key: key)
                pendingBody = nil
                requestsThisTurn += 1
                let reply = try await transport.turn(request, provider: config.provider)
                guard token == generation, !Task.isCancelled else { return }
                guard config == configuration else { reset(); message = "配置已变化，请重新提问。"; return }
                if let requestContext, let latest = readContext?(), !requestContext.matches(latest) {
                    contextChanged(); return
                }
                if AssistantPrivacy.containsSecret(reply.text, key: key) { throw AssistantError.sensitive }
                history.append(.assistant(reply))
                if reply.calls.isEmpty {
                    entries.append(.init(role: "助手", text: reply.text))
                    persistConversation()
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
                    var output: AssistantToolResult
                    if call.name == "preview_schedule_change", !privateReadsDenied {
                        do {
                            let draft = try await Task.detached(priority: .userInitiated) { try AssistantProposal.make(call, context: snapshot) }.value
                            guard token == generation, !Task.isCancelled else { return }
                            proposal = draft
                            output = try AssistantProposal.output(draft, call: call, id: id)
                        } catch {
                            proposal = nil
                            output = .init(id: id, callID: call.id, title: "未生成修改预览", content: "[\(id)] {\"error\":\"参数无效或无法生成预览，未修改日程。\"}", privateData: false, denied: true)
                        }
                    } else {
                        output = await Task.detached(priority: .userInitiated) { AssistantTools.execute(call, context: snapshot, id: id) }.value
                    }
                    guard token == generation, !Task.isCancelled else { return }
                    if AssistantPrivacy.containsSecret(output.content, key: key) {
                        output.content = "[\(id)] {\"error\":\"本机检测到疑似凭证，结果已拦截。\"}"
                        output.privateData = false; output.denied = true
                    }
                    if output.privateData && privateReadsDenied {
                        output.content = "[\(id)] {\"error\":\"本轮用户已拒绝发送新增个人数据，不能通过其他工具绕过。请依据已有资料回答或说明不足。\"}"
                        output.privateData = false; output.denied = true
                    }
                    outputs.append(output)
                }
                guard snapshot.matches(readContext()) else { contextChanged(); return }
                if outputs.contains(where: { $0.privateData && !grantedScopes.contains(AssistantPrivacy.grantKey($0)) }) {
                    let body = try previewBody(history + outputs.map { .tool($0) })
                    approval = .init(configuration: config, context: snapshot, question: nil, results: outputs, historyCount: history.count, body: body)
                    activity = "已在本机查到资料，等待你确认发送"; busy = false; task = nil
                    return
                }
                for output in outputs { history.append(.tool(output)); evidence.append(output) }
                activity = "正在根据查询结果继续核对…"
            }
        } catch {
            guard token == generation else { return }
            retainQuestionAfterInterruption(status: "本轮未完成；原问题保留，继续追问时会重新查询。")
            persistConversation()
            message = error is AssistantAgentLimit ? "本轮已达到8次请求上限，已停止。可缩小问题后继续；不会自动重试。"
                : AssistantError.safe(error).localizedDescription
            busy = false; activity = ""; task = nil; approval = nil
        }
    }

    func cancelProposal() { stop(); proposal = nil; message = "已取消日程修改，原安排保留。" }
    func applyProposal(_ id: UUID, apply: @MainActor (AssistantScheduleChange) async -> Bool) async {
        guard !busy, approval == nil, !applyingProposal, let draft = proposal, draft.id == id,
              let context = readContext?() else { return }
        do {
            var state = context.state
            try draft.apply(to: &state, now: context.now)
        } catch { proposal = nil; message = error.localizedDescription; return }
        proposal = nil; applyingProposal = true
        let succeeded = await apply(draft)
        applyingProposal = false
        // Write result locally; no automatic request after a business mutation.
        history = []; evidence = []; grantedScopes = []; conversationContext = nil
        usedCallIDs = []; nextResultID = 1
        entries.append(.init(role: "本机", text: succeeded ? "已按确认的预览保存：" + draft.title : "修改未保存，请检查主窗口提示并重新生成预览。"))
        persistConversation()
        message = succeeded ? "已保存。后续提问会重新查询最新日程。" : "未保存；没有自动重试。"
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

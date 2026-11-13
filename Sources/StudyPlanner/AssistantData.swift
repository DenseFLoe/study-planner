import Foundation
import CryptoKit
import Security
import StudyCredentials

enum AssistantError: String, Error, LocalizedError, Codable {
    case configuration = "请填写 HTTPS 服务地址和模型名称；地址不能含账号、查询参数或片段。"
    case key = "请打开 API 设置填写密钥，或主动从本机钥匙串载入。"
    case keychain = "钥匙串操作未完成，原有凭证未删除。"
    case history = "本机聊天记录无法安全读写，原文件已保留；本次未覆盖保存。"
    case sensitive = "检测到疑似密钥或凭证，已阻止保存和发送。请移除后重试。"
    case protocolError = "助手通信未完成或返回了无效内容，未自动重试。"
    case expired = "确认已过期；请重试并重新核对发送内容。"
    case changed = "问题或设置已修改，本轮已停止。"
    case snapshotChanged = "课表仍在更新，稍后可重试查询。"
    case refused = "已拒绝发送，本轮已停止。"
    case stopped = "已停止；已经发出的请求无法撤回，服务商仍可能计费。"
    case network = "接口请求失败或超时；未自动重试。请核对服务地址、模型及账户后重试。"
    case limit = "本轮已到查询或内容上限，请缩小问题范围后重试。"
    var errorDescription: String? { rawValue }
    static func safe(_ error: Error) -> Self { error as? Self ?? (error is CancellationError ? .stopped : .network) }
}

enum AssistantProvider: String, Codable, CaseIterable, Identifiable {
    case openai = "OpenAI / 兼容接口", deepseek = "DeepSeek", anthropic = "Anthropic"
    var id: String { rawValue }
    var wire: String { self == .anthropic ? "anthropic" : "openai" }
    var baseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        }
    }
}

struct AssistantConfiguration: Codable, Equatable, Sendable {
    var provider: AssistantProvider = .openai
    var baseURL = AssistantProvider.openai.baseURL
    var model = ""
    func endpoint() throws -> URL {
        guard baseURL.utf8.count <= 2048, let parts = URLComponents(string: baseURL),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !baseURL.contains(where: { $0.isWhitespace }),
              !model.isEmpty, model.utf8.count <= 128, !model.contains(where: { $0.isWhitespace }) else {
            throw AssistantError.configuration
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                           + (provider == .anthropic ? "/messages" : "/chat/completions")) else { throw AssistantError.configuration }
        return url
    }
}
extension AssistantProvider: Sendable {}

func assistantJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func assistantHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

enum AssistantSecrets {
    static func check(_ text: String, key: String = "") throws {
        // Decode JSON strings too: an escaped credential is still a credential.
        func inspect(_ value: String, depth: Int) throws {
            let normalized = value.precomposedStringWithCompatibilityMapping
            let decoded = normalized.removingPercentEncoding ?? normalized
            let patterns = [
                #"(?i)\b(sk[-_]|sess-|gh[pousr]_|github_pat_|xox[baprs]-|Bearer\s+)[A-Za-z0-9_\-]{8,}"#,
                #"(?i)(api[_ -]?key|password|passwd|client[_ -]?secret|access[_ -]?token|refresh[_ -]?token|authorization|cookie|密钥|密码|口令|访问令牌)[\"']?\s*(?:[=:：]|是|为)\s*[\"']?[^\s\"',;}]{4,}"#,
                #"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"#,
                #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
                #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
                #"(?i)\b[a-z][a-z0-9+.-]*://[^\s/]+:[^\s/]+@"#,
                #"(?i)[?&](?:token|key|secret|password|signature|access_token)=[^\s&#\"]+"#
            ]
            for candidate in [normalized, decoded] {
                guard key.isEmpty || !candidate.contains(key), !patterns.contains(where: {
                    candidate.range(of: $0, options: .regularExpression) != nil
                }) else { throw AssistantError.sensitive }
            }
            guard depth < 8, let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            func walk(_ object: Any) throws {
                if let string = object as? String, string != value { try inspect(string, depth: depth + 1) }
                else if let array = object as? [Any] { for item in array { try walk(item) } }
                else if let dictionary = object as? [String: Any] {
                    for (name, item) in dictionary {
                        if let string = item as? String { try inspect(name + ":" + string, depth: depth + 1) }
                        try inspect(name, depth: depth + 1); try walk(item)
                    }
                }
            }
            try walk(object)
        }
        try inspect(text, depth: 0)
    }
    static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: { $0.isWhitespace }) else { throw AssistantError.key }
    }
}

/// Deliberately separate service: never reads or overwrites prior assistant/account credentials.
enum AssistantVault {
    private static func account(_ config: AssistantConfiguration) throws -> String {
        let destination = try config.endpoint().absoluteString
        return assistantHash(Data((config.provider.rawValue + destination).utf8))
    }
    static func load(_ config: AssistantConfiguration) throws -> String {
        let (data, status) = CredentialClient.perform(.init(.load, service: "local.studyplanner.assistant.sdk-v2", account: try account(config)))
        guard status == errSecSuccess, let data, let key = String(data: data, encoding: .utf8) else { throw AssistantError.keychain }
        try AssistantSecrets.validateKey(key); return key
    }
    static func save(_ key: String, config: AssistantConfiguration) throws {
        try AssistantSecrets.validateKey(key)
        let (_, status) = CredentialClient.perform(.init(.save, service: "local.studyplanner.assistant.sdk-v2", account: try account(config), value: Data(key.utf8)))
        guard status == errSecSuccess else { throw AssistantError.keychain }
    }
}

// Entry shape is compatible with the earlier assistant's local history.
struct AssistantChatEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var role: String
    var text: String
    var status: String?
    var steps: [String]?
    var failureReason: AssistantError?
    var usage: AssistantTurnUsage?
}
struct AssistantConversation: Codable, Identifiable, Sendable {
    var id = UUID()
    var updatedAt = Date()
    var entries: [AssistantChatEntry] = []
    var title: String { String((entries.first { $0.role == "你" }?.text ?? "新对话").prefix(32)) }
}
struct AssistantWorkspace: Codable, Sendable {
    var configuration = AssistantConfiguration()
    var conversations: [AssistantConversation] = []
    var selectedID: UUID?
    var memories: [AssistantMemory] = []

    init(configuration: AssistantConfiguration = .init(), conversations: [AssistantConversation] = [],
         selectedID: UUID? = nil, memories: [AssistantMemory] = []) {
        self.configuration = configuration; self.conversations = conversations
        self.selectedID = selectedID; self.memories = memories
    }
    private enum CodingKeys: String, CodingKey { case configuration, conversations, selectedID, memories }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try values.decode(AssistantConfiguration.self, forKey: .configuration)
        conversations = try values.decode([AssistantConversation].self, forKey: .conversations)
        selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        memories = try values.decodeIfPresent([AssistantMemory].self, forKey: .memories) ?? []
    }
}

protocol AssistantHistoryPersistence: Sendable {
    func load() throws -> AssistantWorkspace
    func save(_ value: AssistantWorkspace) throws
}

/// Atomic private file outside planner persistence/sync; a corrupt file is never replaced.
struct AssistantHistoryStore: AssistantHistoryPersistence {
    let url: URL
    var legacyURL: URL? = nil
    static var local: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyPlannerAssistant")
        return .init(url: root.appendingPathComponent("workspace-v2.json"), legacyURL: root.appendingPathComponent("conversations-v1.json"))
    }
    private func safePath(_ path: URL) throws {
        var current = path
        while current.path != "/" {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                // Foundation canonicalizes macOS temporary URLs back through these system aliases.
                // Permit only the exact OS alias, never a user-created history/file symlink.
                let systemAliases = ["/var": "private/var", "/tmp": "private/tmp"]
                guard let expected = systemAliases[current.path],
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path),
                      target == expected || target == "/" + expected else { throw AssistantError.history }
            }
            current.deleteLastPathComponent()
        }
    }
    private func read(_ path: URL) throws -> Data {
        try safePath(path)
        guard let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000 else { throw AssistantError.history }
        let data = try Data(contentsOf: path)
        guard data.count <= 8_000_000 else { throw AssistantError.history }; return data
    }
    func load() throws -> AssistantWorkspace {
        let fm = FileManager.default
        var value = AssistantWorkspace()
        if fm.fileExists(atPath: url.path) {
            value = try JSONDecoder().decode(AssistantWorkspace.self, from: read(url))
        } else if let legacyURL, fm.fileExists(atPath: legacyURL.path) {
            value.conversations = try JSONDecoder().decode([AssistantConversation].self, from: read(legacyURL))
            // Legacy records remain visible locally but require a fresh conversation to be sent.
            for i in value.conversations.indices {
                for j in value.conversations[i].entries.indices { value.conversations[i].entries[j].status = "旧版记录 · 仅本机查看" }
            }
        }
        try validate(value); return value
    }
    private func validate(_ value: AssistantWorkspace) throws {
        guard value.conversations.count <= 100,
              Set(value.conversations.map(\.id)).count == value.conversations.count,
              value.conversations.allSatisfy({ Set($0.entries.map(\.id)).count == $0.entries.count }),
              value.memories.count <= 50, Set(value.memories.map(\.id)).count == value.memories.count,
              value.memories.allSatisfy({ !$0.text.isEmpty && $0.text.utf8.count <= 2000 }) else { throw AssistantError.history }
        guard value.conversations.allSatisfy({ $0.entries.allSatisfy { $0.usage?.valid ?? true } }) else { throw AssistantError.history }
        try AssistantSecrets.check(String(decoding: assistantJSON(value), as: UTF8.self))
    }
    func save(_ value: AssistantWorkspace) throws {
        try validate(value); try safePath(url)
        let data = try assistantJSON(value)
        guard data.count <= 8_000_000 else { throw AssistantError.history }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One queue owns history IO, including initial validation and ordered saves.
final class AssistantHistoryWriter: Sendable {
    private let queue = DispatchQueue(label: "local.studyplanner.assistant.history", qos: .userInitiated)
    private let store: (any AssistantHistoryPersistence)?
    init(store: (any AssistantHistoryPersistence)?) { self.store = store }
    func load() async -> Result<AssistantWorkspace, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result {
                    var saved = try self.store?.load() ?? AssistantWorkspace()
                    if saved.conversations.isEmpty { saved.conversations = [AssistantConversation()] }
                    if !saved.conversations.contains(where: { $0.id == saved.selectedID }) {
                        saved.selectedID = saved.conversations[0].id
                    }
                    for i in saved.conversations.indices {
                        for j in saved.conversations[i].entries.indices where saved.conversations[i].entries[j].status == "处理中" {
                            saved.conversations[i].entries[j].status = "上次已中断 · 未续传"
                        }
                    }
                    return saved
                })
            }
        }
    }
    private func write(_ value: AssistantWorkspace, secrets: Set<String>) throws {
        let text = String(decoding: try assistantJSON(value), as: UTF8.self)
        try AssistantSecrets.check(text)
        for secret in secrets where !secret.isEmpty { try AssistantSecrets.check(text, key: secret) }
        try store?.save(value)
    }
    func save(_ value: AssistantWorkspace, secrets: Set<String>) throws {
        try queue.sync { try write(value, secrets: secrets) }
    }
    func enqueue(_ value: AssistantWorkspace, secrets: Set<String>,
                 completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            completion(Result { try self.write(value, secrets: secrets) })
        }
    }
}

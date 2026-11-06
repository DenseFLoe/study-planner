import Foundation

struct AssistantRequest: Codable, Equatable, Sendable {
    let id: String
    let configuration: AssistantConfiguration
    let url: String
    let body: String
    // These are precisely the application headers used by transport. Credential value stays outside this type.
    var headers: [String: String] {
        var value = ["Content-Type": "application/json", "Accept": "application/json"]
        if configuration.provider == .anthropic { value["anthropic-version"] = "2023-06-01" }
        return value
    }
    func validate(key: String = "") throws {
        guard url == (try configuration.endpoint().absoluteString), !id.isEmpty, id.count < 100,
              body.utf8.count <= 524_288,
              let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              object["model"] as? String == configuration.model,
              object["stream"] as? Bool != true,
              object["messages"] is [[String: Any]] else { throw AssistantError.protocolError }
        try AssistantSecrets.check(body, key: key)
        try AssistantSecrets.check(url, key: key)
        try AssistantSecrets.check(configuration.model, key: key)
    }
    var details: String {
        let auth = configuration.provider == .anthropic ? "x-api-key" : "Authorization"
        return "POST \(url)\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            + "\n\(auth): [密钥仅用于认证，不展示、不保存到聊天]\n\n" + body
    }
    /// Parse actual tool-result blocks; never infer approval categories from a model-written explanation.
    var categories: [String] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return [] }
        var names = Set<String>()
        func collect(_ content: Any) {
            if let text = content as? String, let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let category = object["category"] as? String { names.insert(category) }
            else if let blocks = content as? [[String: Any]] {
                for block in blocks {
                    if block["type"] as? String == "text", let text = block["text"] { collect(text) }
                    if block["type"] as? String == "tool_result", let value = block["content"] { collect(value) }
                }
            }
        }
        for message in messages {
            if message["role"] as? String == "tool", let content = message["content"] { collect(content) }
            if let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_result" {
                    if let value = block["content"] { collect(value) }
                }
            }
        }
        return names.sorted()
    }
    /// Privacy classes from the actual tool-result categories, never from model prose.
    var compactCategories: [String] {
        var result: [String] = []
        func add(_ name: String) { if !result.contains(name) { result.append(name) } }
        for category in categories {
            var matched = false
            for (terms, label) in [
                (["名称"], "课程/课节名称"), (["编号"], "相关编号"),
                (["日期", "时间", "时段", "截止"], "日期时间"),
                (["进度", "时长", "学习量"], "学习量与进度"),
                (["规则", "偏好", "排课设置", "休息"], "排程规则"),
                (["冲突", "重叠", "容量", "未排入", "时间核对"], "冲突及余量"),
                (["事项占用"], "事项占用"), (["计算"], "计算结果与依据"), (["参数提示"], "查询提示")
            ] where terms.contains(where: { category.contains($0) }) {
                matched = true; add(label)
            }
            if !matched { add(category) }
        }
        return result
    }
}

struct AssistantApproval: Identifiable, Sendable {
    let id = UUID()
    let request: AssistantRequest
    let fingerprint: String
    let snapshotID: String
    let expiresAt: Date
    let simulated: Bool
    var summary: String {
        let data = (["本次问题、本对话历史、助手规则与查询说明"] + request.compactCategories).joined(separator: "；")
        let destination = simulated ? "本机模拟（不会联网）" : "\(request.configuration.provider.rawValue) · \(URL(string: request.url)?.host ?? request.url)"
        return "发给：\(destination) · \(request.configuration.model)\n包含：\(data)。"
    }
}

struct AssistantApprovalGate {
    private(set) var pending: AssistantApproval?
    private var seen = Set<String>()
    mutating func prepare(_ request: AssistantRequest, snapshotID: String, simulated: Bool, now: Date = Date()) throws -> AssistantApproval {
        try request.validate()
        guard pending == nil, seen.insert(request.id).inserted, seen.count <= 8 else { throw AssistantError.protocolError }
        let value = AssistantApproval(request: request, fingerprint: assistantHash(try assistantJSON(request)),
                                      snapshotID: snapshotID, expiresAt: now.addingTimeInterval(120), simulated: simulated)
        pending = value; return value
    }
    mutating func decide(id: UUID, request: AssistantRequest, snapshotID: String, allow: Bool, now: Date = Date()) throws -> Bool {
        guard let value = pending, value.id == id else { throw AssistantError.changed }
        pending = nil
        guard now < value.expiresAt else { throw AssistantError.expired }
        guard value.snapshotID == snapshotID, value.fingerprint == assistantHash(try assistantJSON(request)) else { throw AssistantError.changed }
        return allow
    }
    mutating func cancel() { pending = nil }
}

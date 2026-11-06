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
    var confirmsScope = true
    var findings: [AssistantPrivacyFinding] = []
    var title: String { confirmsScope ? "课表内容确认" : "隐私内容确认" }
    var summary: String {
        let destination = simulated ? "本机模拟（不会联网）" : request.url
        let data = confirmsScope
            ? "本次问题、已完成的对话历史和启用记忆；按需查询课程/课节名称、相关编号、日期时间、学习量与进度、排程规则、冲突及余量。上述文字中若含联系方式、身份、健康、财务信息、私密标记或链接，也包含在本轮授权范围内，请确认适合发送。"
            : (["本次问题、对话历史、启用记忆"] + request.compactCategories).joined(separator: "；") + "。"
        return "接收方：\(destination)\n模型：\(request.configuration.model)\n\(data)"
    }
    var scopeNote: String {
        confirmsScope
            ? "本轮从本次发送到回答结束，只在这里确认一次；后续同一接收方、同一课表版本的范围内查询自动继续，不再逐条询问。新一轮重新确认；疑似密钥一律阻止，不能授权放行。"
            : "仅允许本轮向此接收方发送下列内容；相同内容在后续请求中可能重复携带。新的隐私内容仍会询问。"
    }
}

struct AssistantApprovalGate {
    private(set) var pending: AssistantApproval?
    private var seen = Set<String>()
    mutating func prepare(_ request: AssistantRequest, snapshotID: String, simulated: Bool, now: Date = Date(),
                          confirmsScope: Bool = true, findings: [AssistantPrivacyFinding] = []) throws -> AssistantApproval {
        try request.validate()
        guard pending == nil, seen.insert(request.id).inserted, seen.count <= 8 else { throw AssistantError.protocolError }
        let value = AssistantApproval(request: request, fingerprint: assistantHash(try assistantJSON(request)),
                                      snapshotID: snapshotID, expiresAt: now.addingTimeInterval(120), simulated: simulated,
                                      confirmsScope: confirmsScope, findings: findings)
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

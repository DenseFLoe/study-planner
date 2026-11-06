import Foundation

struct AssistantPrivacyFinding: Equatable, Sendable {
    let source: String
    let reason: String
    let text: String
    var fingerprint: String { assistantHash(Data((source + "\n" + reason + "\n" + text).utf8)) }
}

/// Conservative local heuristics, not a promise to recognize every kind of personal data.
/// It is applied to actual outbound content, never to the model's claims of safety.
enum AssistantContentPolicy {
    static func inspect(_ text: String, source: String) -> [AssistantPrivacyFinding] {
        let rules: [(String, String)] = [
            (#"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?<!\d)(?:\+?86[- ]?)?1[3-9]\d{9}(?!\d)|\+\d[\d ()-]{7,}\d"#, "可能含联系方式"),
            (#"(?<!\d)\d{17}[0-9Xx](?!\d)|(?<!\d)\d{13,19}(?!\d)|身份证|护照号|银行卡|信用卡|银行账户|家庭住址|住在|居住地址|详细地址"#, "可能含身份、财务或住址信息"),
            (#"(?i)诊断|病历|病史|患有|抑郁症|焦虑症|怀孕|服药|疾病|收入|工资|债务|性取向|宗教信仰|medical record|diagnosed|salary"#, "可能含健康、财务或其他敏感隐私"),
            (#"(?i)隐私|私密|保密|敏感|不要外传|不能外传|private|confidential|secret|密码|密钥|令牌|凭证"#, "内容涉及隐私或凭证，无法确定是否适合发送"),
            (#"(?i)https?://|file://|/Users/|/home/|(?:姓名|联系人|地址|账号|账户|电话|邮箱)\s*[：:=]|[A-Za-z0-9_+/=-]{40,}"#, "可能含链接、个人标识或不明编码内容")
        ]
        return rules.compactMap { pattern, reason in
            text.range(of: pattern, options: .regularExpression).map { _ in
                .init(source: source, reason: reason, text: text)
            }
        }
    }

    static func findings(in request: AssistantRequest, instructions: String,
                         evidence: [AssistantToolEvidence]) throws -> [AssistantPrivacyFinding] {
        guard let root = try JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any] else { throw AssistantError.protocolError }
        var result: [AssistantPrivacyFinding] = []
        func plain(_ text: String, source: String) {
            // The exact built-in instructions contain safety vocabulary, not private user facts.
            if text != instructions { result += inspect(text, source: source) }
        }
        func tool(_ value: Any) throws {
            var object: Any = value
            if let text = value as? String { object = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
            if let blocks = object as? [[String: Any]] {
                for block in blocks {
                    guard block["type"] as? String == "text", let text = block["text"] else { throw AssistantError.protocolError }
                    try tool(text)
                }
                return
            }
            guard let dictionary = object as? [String: Any], let id = dictionary["evidence_id"] as? String,
                  let native = evidence.first(where: { $0.id == id }),
                  let original = try JSONSerialization.jsonObject(with: Data(native.json.utf8)) as? NSDictionary,
                  original.isEqual(to: dictionary) else { throw AssistantError.protocolError }
            func names(_ value: Any, untrusted: Bool = false) {
                if let text = value as? String, untrusted { plain(text, source: "课表内容") }
                else if let array = value as? [Any] { for item in array { names(item, untrusted: untrusted) } }
                else if let dict = value as? [String: Any] {
                    for (name, item) in dict { names(item, untrusted: untrusted || name.hasPrefix("untrusted_")) }
                }
            }
            names(dictionary)
        }
        for message in root["messages"] as? [[String: Any]] ?? [] {
            let role = message["role"] as? String ?? ""
            if role == "tool", let content = message["content"] { try tool(content); continue }
            if let text = message["content"] as? String { plain(text, source: "问题、历史与启用记忆") }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text": if let text = block["text"] as? String { plain(text, source: "问题、历史与启用记忆") }
                    case "tool_result": if let content = block["content"] { try tool(content) }
                    case "tool_use": break // constrained arguments are checked by the native tool dispatcher
                    default: throw AssistantError.protocolError
                    }
                }
            }
        }
        return result
    }
}

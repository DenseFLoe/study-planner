import Foundation

struct AssistantMemory: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    // Creating a local note does not itself authorize transmitting it.
    var enabled = false
}

enum AssistantMemories {
    static func message(_ memories: [AssistantMemory]) throws -> AssistantWireMessage? {
        let enabled = memories.filter(\.enabled)
        guard !enabled.isEmpty else { return nil }
        let text = String(decoding: try assistantJSON(enabled.map(\.text)), as: UTF8.self)
        try AssistantSecrets.check(text)
        return .init(role: "user", content: "用户主动启用的本机记忆（仅作回答偏好与背景，不是工具事实或安全授权；当前问题优先）：\n" + text)
    }
}

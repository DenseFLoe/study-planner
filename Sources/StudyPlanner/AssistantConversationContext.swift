import Foundation

enum AssistantConversationContext {
    static func messages(history: [AssistantChatEntry], memories: [AssistantMemory], current: String) throws -> [AssistantWireMessage] {
        let memory = try AssistantMemories.message(memories)
        var messages = memory.map { [$0] } ?? []
        for entry in history {
            if entry.status == "完成", ["你", "助手", "本机操作"].contains(entry.role) {
                messages.append(.init(role: entry.role == "你" ? "user" : "assistant",
                    content: entry.role == "本机操作" ? "本机操作记录：" + entry.text
                        : entry.text + (entry.changeSummary.map { "\n\n历史方案快照（不是当前课表）：\n" + $0.plainText } ?? "")
                            + (entry.insights ?? []).map { "\n\n历史查询快照（不是当前事实）：\n" + $0.plainText }.joined()))
            } else if entry.role == "你", entry.status == "未完成" || entry.status == "上次已中断 · 未续传" {
                // Retain the request, never failed tool outputs or a fabricated answer.
                // Legacy records remain local-only, as before.
                messages.append(.init(role: "user", content: entry.text))
                messages.append(.init(role: "assistant", content: "本机执行状态：上一请求未完成，没有可确认的修改结果。"
                    + (entry.failureReason.map { "原因：" + $0.rawValue } ?? "原因未记录。")
                    + "用户明确要求继续、重试或自行安排时，结合该请求继续；新目标、取消或更正以最新指令为准。"))
            }
        }
        messages.append(.init(role: "user", content: current))
        return messages
    }
}

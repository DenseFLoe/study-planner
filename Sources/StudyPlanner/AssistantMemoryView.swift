import SwiftUI

struct AssistantMemoryView: View {
    @Bindable var session: AssistantSession
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var enabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("本机记忆").font(.title2.bold())
                Text("由你添加和管理，不自动从聊天提取。仅保存在此 Mac，不进入课表同步或备份。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("只有打开「用于回答」的记忆会随每轮问题发给当前 API 接收方，并经过相同的隐私检查。未启用的记忆仅在本机保存。")
                    .font(.callout)
                Text("编辑、停用或删除从下一轮生效；正在进行的回答会停止。过去已发送的内容无法撤回，已有聊天文字仍会保留；要排除旧对话影响，请新建对话。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if session.memories.isEmpty { Text("还没有记忆。可以记录回答语言、详略偏好或学习目标。").foregroundStyle(.secondary) }
                ForEach(session.memories) { memory in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(memory.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Toggle("用于回答", isOn: Binding(get: { memory.enabled }, set: { session.setMemoryEnabled(memory.id, $0) }))
                                .toggleStyle(.switch).controlSize(.small)
                            Spacer()
                            Button("编辑") { editingID = memory.id; draft = memory.text; enabled = memory.enabled }
                            Button("删除", role: .destructive) {
                                session.deleteMemory(memory.id)
                                if editingID == memory.id { reset() }
                            }
                        }
                    }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                Divider()
                Text(editingID == nil ? "添加记忆" : "编辑记忆").font(.headline)
                TextField("例如：用中文，先给结论，再解释关键步骤。", text: $draft, axis: .vertical)
                    .lineLimit(3...7).textFieldStyle(.roundedBorder).accessibilityLabel("记忆内容")
                Toggle("用于回答（会发送给当前模型）", isOn: $enabled)
                if !AssistantContentPolicy.inspect(draft, source: "记忆").isEmpty {
                    Text("这条内容可能涉及隐私。可仅保存在本机；启用后发送前还会询问。密钥不能保存为记忆。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = session.memoryError { Text(error).font(.callout).foregroundStyle(.red) }
                HStack {
                    if editingID != nil { Button("取消编辑") { reset() } }
                    Spacer()
                    Button(editingID == nil ? "添加记忆" : "保存修改") {
                        if session.saveMemory(id: editingID, text: draft, enabled: enabled) { reset() }
                    }.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(4)
        }
    }
    private func reset() { editingID = nil; draft = ""; enabled = false }
}

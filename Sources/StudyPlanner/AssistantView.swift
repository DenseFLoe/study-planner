import SwiftUI
import StudyCore

struct AssistantView: View {
    @Bindable var store: PlannerStore
    @State private var session: AssistantSession
    @State private var day: Date
    @State private var courseID: UUID?
    @State private var includeNames = false
    @State private var showConfiguration = true
    @AppStorage("dailyStudyLoadWarningMinutes") private var dailyWarningMinutes = 480
    @Environment(\.dismiss) private var dismiss

    init(store: PlannerStore, day: Date, courseID: UUID? = nil) {
        self.store = store
        _day = State(initialValue: day); _courseID = State(initialValue: courseID)
        _session = State(initialValue: AssistantSession(defaults: store.demo ? nil : .standard))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("日程助手", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.title2.bold())
                Spacer()
                Button("关闭") { session.close(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("依据本地数据解释排课与学习量。只读，不会更改日程。每次独立问答，不发送之前的对话。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    configuration
                    HStack {
                        DatePicker("查看日期", selection: $day, displayedComponents: .date)
                        Picker("课程", selection: $courseID) {
                            Text("课程概览（最多12门）").tag(nil as UUID?)
                            ForEach(store.courses) { course in Text(course.name).tag(Optional(course.id)) }
                        }.frame(maxWidth: 340)
                    }
                    Toggle("在证据中包含课程名称", isOn: $includeNames)
                    Text("默认使用课程编号；完整课程名会先在本机替换为「课程1」这类引用，发送前请核对。名称与编号冲突时需明确选择课程；也可用「课程1」明确引用编号。简称或别名不自动推断，其余文字原样发送。事项名称、备注、网址、账号和完整历史不加入证据。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("解释排课") { session.question = "为什么这样安排？请区分已确认事实、可能解释与缺失信息。" }
                        Button("核对超标") { session.question = "所选课程为什么看起来超标？请核对安排、有效完成和剩余量，区分每日均摊与硬上限。" }
                        Button("检查未排入") { session.question = "还有多少学习量未排入？这些数据能否证明截止前无法完成？" }
                    }.buttonStyle(.bordered).disabled(session.busy)
                    TextEditor(text: $session.question).font(.body)
                        .frame(height: 80).padding(6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        .accessibilityLabel("助手问题")
                    HStack {
                        Button("预览本次发送内容") {
                            Task { await session.prepare(state: store.state, day: day, courseID: courseID, includeNames: includeNames,
                                                         result: store.result, dailyWarningMinutes: dailyWarningMinutes) }
                        }.disabled(session.busy || session.preparing || !store.isReady)
                            .accessibilityIdentifier("assistantPreview")
                        if session.preparing { ProgressView().controlSize(.small); Text("正在本地整理证据…") }
                        if session.busy {
                            ProgressView().controlSize(.small)
                            Text("等待回答…")
                            Button("取消请求") { session.invalidate() }
                        }
                    }
                    if let preview = session.preview {
                        evidence(preview)
                        Text("将把以上问题、证据和助手规则发送至 \(preview.configuration.provider.title) 的 \(preview.configuration.endpoint)。服务商按自己的数据政策处理，可能产生 API 费用。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("同意发送本次内容") { session.send(currentState: store.state) }
                            .buttonStyle(.borderedProminent).disabled(store.demo)
                            .accessibilityIdentifier("assistantSend")
                        if store.demo { Text("示例预览禁用外部请求和钥匙串操作。").font(.caption) }
                    }
                    if let message = session.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                    if !session.answer.isEmpty {
                        Divider()
                        Label("助手回答 · 请对照证据核验", systemImage: "text.bubble").font(.headline)
                        // Verbatim text: model output cannot open links or execute actions.
                        Text(verbatim: session.answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let answered = session.answeredPreview {
                            DisclosureGroup("查看这次回答依据的快照") { evidence(answered) }
                        }
                    }
                }.padding(2)
            }
        }.padding(24).frame(minWidth: 620, idealWidth: 760, minHeight: 580, idealHeight: 760)
            .onDisappear { session.close() }
            .onChange(of: day) { _, _ in session.invalidate() }
            .onChange(of: courseID) { _, _ in session.invalidate() }
            .onChange(of: includeNames) { _, _ in session.invalidate() }
            .onChange(of: dailyWarningMinutes) { _, _ in session.invalidate() }
            .onChange(of: session.question) { _, _ in session.invalidate() }
            .onChange(of: session.configuration) { old, new in
                if old.endpoint != new.endpoint || old.provider != new.provider { session.key = "" }
                session.invalidate()
            }
            .onChange(of: store.state) { _, _ in
                session.invalidate(); session.message = "日程已更新，请重新预览最新数据。"
            }
    }

    private var configuration: some View {
        DisclosureGroup("API 配置 · \(session.configuration.provider.title)", isExpanded: $showConfiguration) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("服务商", selection: Binding(get: { session.configuration.provider }, set: { session.switchProvider($0) })) {
                    ForEach(AssistantProvider.allCases) { Text($0.title).tag($0) }
                }
                TextField("完整 HTTPS API 地址", text: $session.configuration.endpoint)
                Text(session.configuration.provider == .openAI ? "协议：Responses API" : "协议：Chat Completions API")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("模型名称（按服务商账户可用模型填写）", text: $session.configuration.model)
                SecureField("API 密钥（默认仅本次窗口使用）", text: $session.key)
                HStack {
                    Button("存入本机钥匙串") { vault { try AssistantVault.save(session.key, configuration: session.configuration); return "已保存到此服务地址的本机钥匙串。" } }
                    Button("从钥匙串载入") { vault { session.key = try AssistantVault.load(session.configuration); return "已载入此服务地址的密钥。" } }
                    Button("删除已存密钥") { vault { try AssistantVault.delete(session.configuration); session.key = ""; return "已删除此服务地址的钥匙串记录。" } }
                }.disabled(store.demo || session.busy)
                Text("自定义地址会收到密钥与本次内容，请确认属于你信任的服务。密钥按提供方和完整地址隔离；配置不参与云同步或日程备份。")
                    .font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).padding(.top, 8)
        }
    }

    private func evidence(_ preview: AssistantPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.resolutionNotice).font(.callout).foregroundStyle(.secondary)
            Text("实际发送问题：\(preview.question)").font(.headline)
            Text("仅本机对应关系：" + preview.evidence.courseAliases.joined(separator: "；"))
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: preview.evidence.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            DisclosureGroup("随请求发送的助手规则") { Text(AssistantWire.instructions).font(.caption).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func vault(_ operation: () throws -> String) {
        do { session.message = try operation() }
        catch { session.message = AssistantError.safe(error).localizedDescription }
    }
}

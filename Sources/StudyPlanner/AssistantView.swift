import SwiftUI
import StudyCore

struct AssistantView: View {
    @Bindable var store: PlannerStore
    @State private var session: AssistantSession
    private let day: Date
    private let courseID: UUID?
    @State private var showConfiguration = false
    @AppStorage("dailyStudyLoadWarningMinutes") private var dailyWarningMinutes = 480
    @Environment(\.dismiss) private var dismiss

    init(store: PlannerStore, day: Date, courseID: UUID? = nil) {
        self.store = store; self.day = day; self.courseID = courseID
        _session = State(initialValue: AssistantSession(defaults: store.demo ? nil : .standard))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("智能助手", systemImage: "bubble.left.and.text.bubble.right").font(.title2.bold())
                Spacer()
                Button("新对话") { session.reset() }
                Button("关闭") { session.close(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("直接说出问题，我会按需要查看软件功能、课表和当前状态，找到依据后回答。")
                .font(.callout).foregroundStyle(.secondary)
            configuration
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if session.entries.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("想了解什么？").font(.headline)
                                suggestion("今天为什么安排这么多？帮我查一下。")
                                suggestion("我这周实际学了多少？和计划差多少？")
                                suggestion("关掉窗口后还会监督学习吗？看看我现在的状态。")
                                suggestion("手机上的极限压缩结果是怎么来的？")
                            }.padding(.vertical, 10)
                        }
                        ForEach(session.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.role).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(verbatim: entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if let status = entry.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).background(entry.role == "你" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if !session.evidence.isEmpty {
                            DisclosureGroup("已查询的依据（\(session.evidence.count)项）") {
                                ForEach(session.evidence) { result in
                                    DisclosureGroup("[\(result.id)] \(result.title)\(result.denied ? " · 未提供" : "")") {
                                        Text(verbatim: result.content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                        if let approval = session.approval { approvalView(approval) }
                        if let message = session.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(2)
                }
                .onChange(of: session.entries.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.approval?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if session.busy || !session.activity.isEmpty {
                HStack {
                    if session.busy { ProgressView().controlSize(.small) }
                    Text(session.activity).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("停止") { session.stop() }
                }
            }
            TextEditor(text: $session.question).font(.body).frame(height: 66).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("助手问题")
                .disabled(session.busy || session.approval?.question == nil && session.approval != nil)
            HStack {
                Text("只读查询 · 发送个人资料前确认 · 对话仅留在本窗口")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("发送问题…") { session.prepare { context } }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.busy || session.approval != nil || !store.isReady || session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("assistantPreview")
            }
        }.padding(24).frame(minWidth: 620, idealWidth: 780, minHeight: 620, idealHeight: 820)
            .onAppear { showConfiguration = session.configuration.model.isEmpty }
            .onDisappear { session.close() }
            .onChange(of: dailyWarningMinutes) { _, _ in session.contextChanged() }
            .onChange(of: session.question) { _, _ in session.questionChanged() }
            .onChange(of: session.configuration) { old, new in
                if old.endpoint != new.endpoint || old.provider != new.provider { session.key = "" }
                session.reset()
            }
            .onChange(of: store.state) { _, _ in session.contextChanged() }
            .onChange(of: store.result) { _, _ in session.contextChanged() }
    }

    private var context: AssistantContext {
        .init(state: store.state, result: store.result,
              runtime: .init(ready: store.isReady, saving: store.orderSaveBusy, syncing: store.syncBusy,
                             cloudEnabled: store.cloudEnabled, hasError: store.errorMessage != nil,
                             supervisionBound: store.playbackSupervisor.hasBindings,
                             supervisedTasks: store.playbackSupervisor.activeTaskIDs.count,
                             websiteAutoUpdate: store.websiteUpdater.hasEnabledSources,
                             websiteUpdating: store.websiteUpdater.updating != nil,
                             compressionCalculating: store.compressedPlan.calculating,
                             backupCount: store.backupEntries.count,
                             cloudOutcome: AssistantRuntime.syncOutcome(store.cloudStatus),
                             deviceOutcome: AssistantRuntime.syncOutcome(store.syncStatus),
                             supervisionPaused: store.playbackSupervisor.summary == "屏幕休眠或会话未激活，监督已暂停"),
              selectedDay: day, selectedCourseID: courseID, dailyWarningMinutes: dailyWarningMinutes)
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) { session.question = text }.buttonStyle(.link).disabled(session.busy || session.approval != nil)
    }

    private func approvalView(_ approval: AssistantApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.question != nil ? "确认发送问题" : "查到了这些资料，是否发给助手分析？", systemImage: "hand.raised").font(.headline)
            if let question = approval.question {
                Text(verbatim: question).textSelection(.enabled)
                Text(approval.context.questionContext).font(.caption).foregroundStyle(.secondary)
                Text("问题按原文发送，可能包含你输入的个人信息。此次还会携带本窗口已确认发送的对话和资料（\(approval.historyCount)条上下文）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(approval.results) { result in
                DisclosureGroup("[\(result.id)] \(result.title)") {
                    Text(verbatim: result.content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            Text("发送至 \(approval.configuration.provider.title) · \(approval.configuration.endpoint)\n模型：\(approval.configuration.model)。每轮最多8次API请求，可能产生费用；服务商按自己的数据政策处理。确认的资料会随本窗口后续追问再次发送。")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            DisclosureGroup("查看助手规则和查询能力") {
                Text(AssistantAgentWire.instructions).font(.caption).textSelection(.enabled)
                ForEach(AssistantTools.definitions, id: \.name) { Text($0.title + "：" + $0.description).font(.caption) }
            }
            HStack {
                Button(approval.question != nil ? "同意发送并查询" : "同意发送这些资料") { session.approve(approval.id) }
                    .buttonStyle(.borderedProminent).disabled(store.demo).accessibilityIdentifier("assistantSend")
                if approval.question == nil {
                    Button("不发送，按已有信息回答") { session.approve(approval.id, includePrivateData: false) }.disabled(store.demo)
                }
                Button("取消") { session.stop() }
            }
            if store.demo { Text("示例模式禁用外部API和钥匙串操作。").font(.caption) }
        }.padding(12).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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

    private func vault(_ operation: () throws -> String) {
        do { session.message = try operation() }
        catch { session.message = AssistantError.safe(error).localizedDescription }
    }
}

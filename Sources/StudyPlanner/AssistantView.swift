import SwiftUI
import StudyCore

struct AssistantView: View {
    @Bindable var store: PlannerStore
    @State private var session: AssistantSession
    private let day: Date
    private let courseID: UUID?
    private let closeWindow: () -> Void
    @State private var showConfiguration = false
    @State private var selectedScopes: Set<String> = []
    @State private var deletingConversation: UUID?
    @AppStorage("dailyStudyLoadWarningMinutes") private var dailyWarningMinutes = 480

    init(store: PlannerStore, day: Date, courseID: UUID? = nil, session: AssistantSession? = nil, close: @escaping () -> Void = {}) {
        self.store = store; self.day = day; self.courseID = courseID; closeWindow = close
        _session = State(initialValue: session ?? AssistantSession(defaults: store.demo ? nil : .standard))
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 260, idealWidth: 280, maxWidth: 350)
            chat.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 580)
        .disabled(session.applyingProposal)
        .sheet(item: Binding(get: { session.approval }, set: { if $0 == nil && session.approval != nil { session.stop() } })) { approval in
            approvalView(approval)
        }
        .confirmationDialog("删除这段本机聊天记录？", isPresented: Binding(get: { deletingConversation != nil }, set: { if !$0 { deletingConversation = nil } })) {
            Button("删除记录", role: .destructive) { if let id = deletingConversation { session.deleteConversation(id) }; deletingConversation = nil }
            Button("取消", role: .cancel) { deletingConversation = nil }
        }
        .onChange(of: session.approval?.id) { _, _ in selectedScopes = [] }
        .onChange(of: dailyWarningMinutes) { _, _ in session.contextChanged() }
        .onChange(of: session.question) { _, _ in session.questionChanged() }
        .onChange(of: session.configuration) { old, new in
            if old.endpoint != new.endpoint || old.provider != new.provider { session.key = "" }
            session.reset()
        }
        .onChange(of: store.state) { _, _ in session.contextChanged() }
        .onChange(of: store.result) { _, _ in session.contextChanged() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("智能助手", systemImage: "bubble.left.and.text.bubble.right.fill").font(.title3.bold())
            Button { session.stop(); session.reset(); session.question = "" } label: {
                Label("新建对话", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("assistantNewConversation")
            Text("本机聊天记录").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if session.conversations.isEmpty { Text("开始聊天后会自动保存在这里").font(.callout).foregroundStyle(.secondary) }
                    ForEach(session.conversations) { item in
                        Button { session.selectConversation(item.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).lineLimit(2)
                                Text(item.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(session.conversationID == item.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .contextMenu { Button("删除本机记录", role: .destructive) { deletingConversation = item.id } }
                    }
                }
            }
            if let text = session.historyMessage { Text(text).font(.caption).foregroundStyle(.orange) }
            if !session.grantedScopes.isEmpty {
                Button("撤销重复查询授权（\(session.grantedScopes.count)项）") { session.revokeGrants() }.font(.caption)
            }
            Divider()
            configuration
            Text("记录只保存在这台 Mac。发送的问题及获准资料会交给所选 API 服务商处理。").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor))
    }

    private var chat: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("聊聊你的学习安排").font(.headline)
                    Text("\(session.configuration.provider.title) · \(session.configuration.model.isEmpty ? "待配置模型" : session.configuration.model)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: closeWindow)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.entries.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("想了解什么？").font(.title2.bold())
                                Text("直接提问，我会按需要查询课程、进度和排课依据。").foregroundStyle(.secondary)
                                suggestion("今天为什么安排这么多？帮我查一下。")
                                suggestion("我这周实际学了多少？和计划差多少？")
                                suggestion("帮我重新安排未来日程，先给我看预览。")
                            }.padding(.vertical, 24)
                        }
                        ForEach(session.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.role).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(verbatim: entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if let status = entry.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                            }.padding(14).background(entry.role == "你" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if !session.evidence.isEmpty {
                            DisclosureGroup("已查询的依据（\(session.evidence.count)项）") {
                                ForEach(session.evidence) { result in
                                    DisclosureGroup("[\(result.id)] \(result.title)\(result.denied ? " · 未提供" : "")") {
                                        Text(verbatim: result.content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    }.padding(.vertical, 4)
                                }
                            }.font(.callout)
                        }
                        if let draft = session.proposal { proposalView(draft) }
                        if let message = session.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(2)
                }
                .onChange(of: session.entries.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.proposal?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if session.busy || !session.activity.isEmpty {
                HStack {
                    if session.busy { ProgressView().controlSize(.small) }
                    Text(session.activity).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("停止") { session.stop() }.accessibilityIdentifier("assistantStop")
                }
            }
            TextEditor(text: $session.question).font(.body).frame(height: 72).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("助手问题").disabled(session.busy || session.approval != nil)
            HStack {
                Text(session.applyingProposal ? "正在保存…" : "发送前本机审核 · 修改先预览")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("发送") { session.prepare { context } }.keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(session.busy || session.approval != nil || !store.isReady || session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("assistantPreview")
            }
        }.padding(20)
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
        VStack(alignment: .leading, spacing: 16) {
            Label("确认发送", systemImage: "hand.raised.fill").font(.title2.bold())
            Text(approval.summary).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text("接收地址：\(approval.configuration.endpoint)\n模型：\(approval.configuration.model)")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let question = approval.question { Text(verbatim: question).textSelection(.enabled) }
                    Text("同时携带已确认的对话上下文。每轮最多8次标准速度请求，可能产生费用；授权不包含执行日程修改。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(approval.results.filter(\.privateData)) { result in
                        Toggle(isOn: Binding(get: { selectedScopes.contains(result.scope) }, set: { allowed in
                            if allowed { selectedScopes.insert(result.scope) } else { selectedScopes.remove(result.scope) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("本对话允许重复查询：" + result.category)
                                Text(AssistantPrivacy.scopeDescription(result.scope)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.toggleStyle(.checkbox)
                    }
                    if !approval.results.isEmpty {
                        Text("默认仅本次。勾选后只允许相同课程、日期、页码和相同内容；范围或内容变化会重新询问，关闭窗口后授权失效。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("查看实际发送内容") {
                        Text(verbatim: approval.details).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.accessibilityIdentifier("assistantPayloadDetails")
                    Text("本机规则会拦截可识别的凭证，但无法识别全部敏感信息。请核对后发送。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("取消", role: .cancel) { session.stop() }.keyboardShortcut(.cancelAction)
                if approval.question == nil {
                    Button("不提供新增资料") { session.approve(approval.id, includePrivateData: false) }.disabled(store.demo)
                }
                Spacer()
                Button("允许本次发送") { session.approve(approval.id, rememberScopes: selectedScopes) }
                    .buttonStyle(.borderedProminent).disabled(store.demo).accessibilityIdentifier("assistantSend")
            }
            if let message = session.message { Text(message).font(.caption).foregroundStyle(.orange) }
            if store.demo { Text("示例模式禁用外部 API 和钥匙串操作。").font(.caption) }
        }.padding(24).frame(width: 660, height: 500)
    }

    private func proposalView(_ draft: AssistantScheduleChange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("日程修改预览 · 尚未保存", systemImage: "calendar.badge.clock").font(.headline)
            Text(draft.title).textSelection(.enabled)
            Text("原安排 \(draft.baseline.tasks.count) 项 → 新安排 \(draft.preview.tasks.count) 项；本机检查：\(draft.result.risks.count) 项进度风险、\(draft.result.conflicts.count) 项约束冲突。")
            DisclosureGroup("核对修改前后完整安排") {
                agenda(draft.baseline, title: "修改前", calendar: draft.calendar)
                agenda(draft.preview, title: "修改后", calendar: draft.calendar)
                ForEach(Array(draft.result.risks.enumerated()), id: \.offset) { item in
                    Text("\(item.element.courseNames.joined(separator: "、"))：截至\(item.element.deadline.formatted(date: .numeric, time: .omitted))，剩余\(item.element.requiredMinutes)分钟，可用\(item.element.availableMinutes)分钟，未排入\(item.element.unscheduledMinutes)分钟。未排入不等于无解。")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(draft.result.conflicts.enumerated()), id: \.offset) { item in
                    Text("\(item.element.courseNames.joined(separator: "、"))：\(item.element.windowStart.formatted(date: .numeric, time: .omitted))至\(item.element.deadline.formatted(date: .numeric, time: .omitted))，需\(item.element.requiredMinutes)分钟，可用\(item.element.availableMinutes)分钟\(item.element.minimumContinuousMinutes.map { "，需连续\($0)分钟" } ?? "")。")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(draft.result.floatingIssues) { Text($0.explanation).font(.caption).foregroundStyle(.orange) }
                ForEach(Array(draft.result.diagnostics.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
            }
            Text("此预览5分钟内有效。确认会保存并按现有设置同步；数据变化后必须重新预览。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消修改") { session.cancelProposal() }
                Button("确认执行此预览") { Task { await session.applyProposal(draft.id) { await store.saveAssistantChange($0) } } }
                    .buttonStyle(.borderedProminent).disabled(session.busy || session.approval != nil || store.orderSaveBusy)
                    .accessibilityIdentifier("assistantApplyProposal")
            }
        }.padding(14).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private func agenda(_ state: PlannerState, title: String, calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            if state.tasks.isEmpty { Text("无学习任务").font(.caption) }
            ForEach(state.tasks) { task in
                Text("\(state.courses.first { $0.id == task.courseID }?.name ?? "历史课程") · \(task.start.formatted(date: .numeric, time: .shortened)) · \(task.durationMinutes)分钟\(task.isUnconfirmed ? "" : " · 已确认")")
                    .font(.caption).textSelection(.enabled)
            }
        }.padding(.vertical, 6)
    }

    private var configuration: some View {
        DisclosureGroup("API 设置 · \(session.configuration.provider.title)", isExpanded: $showConfiguration) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("服务商", selection: Binding(get: { session.configuration.provider }, set: { session.switchProvider($0) })) {
                        ForEach(AssistantProvider.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("完整 HTTPS API 地址", text: $session.configuration.endpoint)
                    TextField("模型名称", text: $session.configuration.model)
                    SecureField("API 密钥", text: $session.key)
                    Button("存入本机钥匙串") { vault { try AssistantVault.save(session.key, configuration: session.configuration); return "已保存到此服务地址的本机钥匙串。" } }
                    Button("从钥匙串载入") { vault { session.key = try AssistantVault.load(session.configuration); return "已载入此服务地址的密钥。" } }
                    Button("删除已存密钥") { vault { try AssistantVault.delete(session.configuration); session.key = ""; return "已删除密钥。" } }
                    Text("密钥按服务商和完整地址隔离；自定义地址会收到密钥，请确认可信。配置不参与同步。").font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(.top, 8)
            }.frame(maxHeight: 290)
        }.disabled(session.busy || session.approval != nil)
    }
    private func vault(_ operation: () throws -> String) {
        guard !store.demo else { session.message = "示例模式禁用钥匙串。"; return }
        do { session.message = try operation() }
        catch { session.message = AssistantError.safe(error).localizedDescription }
    }
}

import SwiftUI
import AppKit

struct AssistantView: View {
    @Bindable var session: AssistantSession
    @State private var sidebarVisible = true
    @State private var historySearch = ""
    @State private var panel: Panel?
    private enum Panel: Identifiable {
        case history, settings, memories, details
        case deletion(AssistantConversation)
        var id: String {
            switch self {
            case .history: "history"
            case .settings: "settings"
            case .memories: "memories"
            case .details: "details"
            case .deletion(let conversation): "deletion-" + conversation.id.uuidString
            }
        }
        var isDeletion: Bool { if case .deletion = self { true } else { false } }
    }
    var body: some View {
        Group {
            if session.isLoadingHistory {
                ProgressView("正在读取本机聊天记录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }.frame(minWidth: 390, minHeight: 520)
    }
    private var content: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            HStack(spacing: 0) {
                if wide && sidebarVisible {
                    sidebar.frame(width: 270)
                    Divider()
                }
                VStack(spacing: 0) {
                    header(wide: wide)
                    Divider()
                    transcript
                    Divider()
                    composer
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .sheet(item: $panel) { selected in
                VStack(alignment: .leading, spacing: 14) {
                    if !selected.isDeletion {
                        HStack {
                            Spacer()
                            Button("完成") { panel = nil }.keyboardShortcut(.cancelAction)
                        }
                    }
                    switch selected {
                    case .history: history
                    case .deletion(let conversation): deletionConfirmation(conversation)
                    case .settings:
                        Text("API 设置").font(.title2.bold())
                        ScrollView { settings }
                    case .memories: AssistantMemoryView(session: session)
                    case .details:
                        if let approval = session.approval { AssistantRequestDetailsView(request: approval.request) }
                        else { Text("此确认已结束。") }
                    }
                }.padding(18)
                    .frame(width: max(320, min(680, geometry.size.width - 36)), height: selected.isDeletion ? 300 : max(380, min(650, geometry.size.height - 40)))
                    .interactiveDismissDisabled(session.isDeletingConversation)
            }
        }
        .frame(minWidth: 390, minHeight: 520)
        .onChange(of: session.approval?.id) { _, _ in if panel?.id == "details" { panel = nil } }
    }
    private func header(wide: Bool) -> some View {
        HStack(spacing: 14) {
            Button {
                if wide { sidebarVisible.toggle() } else { panel = .history }
            } label: { Image(systemName: "sidebar.left") }
                .help("展开或收起聊天记录").accessibilityLabel("聊天记录")
            VStack(alignment: .leading, spacing: 3) {
                Text(session.conversations.first { $0.id == session.selectedID }?.title ?? "学习助手").font(.headline).lineLimit(1)
                Text(session.simulated ? "合成验收 · 不会联网" : "学习助手 · 日程修改确认后保存").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { session.newConversation() } label: { Image(systemName: "square.and.pencil") }.disabled(!session.canManageConversations).help("新建对话").accessibilityLabel("新建对话")
            Menu {
                Button("本机记忆", systemImage: "brain") { panel = .memories }
                Divider()
                Button("删除当前对话…", systemImage: "trash", role: .destructive) {
                    if let conversation = session.conversations.first(where: { $0.id == session.selectedID }) {
                        requestDeletion(conversation)
                    }
                }.disabled(!session.canManageConversations)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("对话操作").accessibilityLabel("对话操作")
            Button { panel = .settings } label: { Image(systemName: "slider.horizontal.3") }.help("API 设置").accessibilityLabel("API 设置")
        }.buttonStyle(.borderless).padding(16)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            history
            Divider()
            Button { panel = .memories } label: { Label("本机记忆 · 已启用 \(session.enabledMemoryCount) 条", systemImage: "brain") }
                .buttonStyle(.plain)
            Button { panel = .settings } label: { Label("API 设置", systemImage: "slider.horizontal.3") }
                .buttonStyle(.plain)
        }.padding(14).background(Color(nsColor: .windowBackgroundColor))
    }
    private var filteredConversations: [AssistantConversation] {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.conversations.filter { conversation in
            query.isEmpty || conversation.title.localizedStandardContains(query)
                || conversation.entries.contains { ["你", "助手"].contains($0.role) && $0.text.localizedStandardContains(query) }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("对话").font(.title3.bold())
                Spacer()
                Text("\(session.conversations.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button {
                session.newConversation(); historySearch = ""
                if panel?.id == "history" { panel = nil }
            } label: {
                Label("新建对话", systemImage: "square.and.pencil").frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).disabled(!session.canManageConversations)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索对话", text: $historySearch).textFieldStyle(.plain).accessibilityLabel("搜索对话")
                if !historySearch.isEmpty {
                    Button { historySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                }
            }.padding(9).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filteredConversations) { conversation in
                        conversationRow(conversation)
                    }
                    if filteredConversations.isEmpty {
                        Text("没有找到相关对话").font(.callout).foregroundStyle(.secondary).padding(.vertical, 28)
                    }
                }
            }
            Text("聊天记录仅保存在这台 Mac").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func conversationRow(_ conversation: AssistantConversation) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                session.select(conversation.id)
                if panel?.id == "history" { panel = nil }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(conversation.title).font(.callout.weight(.medium)).lineLimit(2)
                    Text(conversation.entries.last(where: { ["你", "助手"].contains($0.role) })?.text ?? "开始一个新问题")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("删除对话…", systemImage: "trash", role: .destructive) { requestDeletion(conversation) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("对话菜单：" + conversation.title)
        }.padding(11)
            .background(session.selectedID == conversation.id ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 11))
            .contextMenu {
                Button("删除对话…", systemImage: "trash", role: .destructive) { requestDeletion(conversation) }
            }
            .disabled(!session.canManageConversations)
    }
    private func requestDeletion(_ conversation: AssistantConversation) {
        panel = .deletion(conversation)
    }
    private func deletionConfirmation(_ conversation: AssistantConversation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("删除这段对话？", systemImage: "trash").font(.title2.bold())
            Text(conversation.title).font(.headline).lineLimit(2)
            Text("将永久删除本机的这段聊天记录，已保存的课表和本机记忆仍会保留。已发送到服务商的内容无法撤回。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if conversation.id == session.selectedID && session.busy {
                Text("当前回答也会停止。").font(.callout).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                Button("取消") { panel = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                if session.isDeletingConversation { ProgressView().controlSize(.small) }
                Button("删除对话", role: .destructive) {
                    Task {
                        let deleted = await session.deleteConversation(conversation.id)
                        if deleted { historySearch = "" }
                        panel = nil
                    }
                }.buttonStyle(.borderedProminent).tint(.red)
            }.disabled(session.isDeletingConversation)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("服务商", selection: Binding(get: { session.configuration.provider }, set: { session.useProvider($0) })) {
                ForEach(AssistantProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("服务基础地址（到 /v1）", text: $session.configuration.baseURL).accessibilityLabel("API 服务地址")
            Text("兼容接口用 Chat Completions；Anthropic 用 Messages。填写基础地址，不含最终接口路径。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("模型名称", text: $session.configuration.model).accessibilityLabel("模型名称")
            if session.simulated {
                Text("合成验收使用本机模拟接口，不接受真实密钥。").font(.caption).foregroundStyle(.secondary)
            } else {
                SecureField("API 密钥", text: $session.key).accessibilityLabel("API 密钥")
                ViewThatFits(in: .horizontal) {
                    HStack { keyButtons }
                    VStack(alignment: .leading) { keyButtons }
                }
                Text("密钥仅通过认证请求头发送到你设置的地址；不会作为聊天、记忆或工具数据发送。关闭窗口清空输入，更换地址须重新提供。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder)
    }
    @ViewBuilder private var keyButtons: some View {
        Button("载入密钥") { session.loadKey() }
        Button("保存到钥匙串") { session.saveKey() }.disabled(session.key.isEmpty)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if session.entries.isEmpty { welcome }
                    ForEach(session.entries) { entry in
                        messageRow(entry).id(entry.id)
                    }
                    if let message = session.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if let message = session.historyMessage { Text(message).font(.callout).foregroundStyle(.red) }
                    if let approval = session.approval { approvalCard(approval) }
                    if let change = session.pendingChange, !session.busy { changeCard(change) }
                    if let undo = session.undoChange {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("可撤销：" + undo.title).font(.callout)
                            Button("撤销上次助手修改") { Task { await session.undoLastChange() } }
                                .disabled(session.busy || session.applyingChange)
                            Text("仅在日程未再次变化时恢复；修改前的自动备份也可在「数据与备份」中查看。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.frame(maxWidth: 780).frame(maxWidth: .infinity).padding(18)
            }
            .onChange(of: session.entries.last?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.approval?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.message) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 34)).foregroundStyle(Color.accentColor)
            Text("一起安排好今天").font(.system(size: 28, weight: .semibold))
            Text("查询课表、梳理进度，或把想调整的安排告诉我。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                suggestion("今天安排了哪些课程？", icon: "calendar")
                suggestion("帮我看看各门课程的学习进度", icon: "chart.bar")
                suggestion("检查一下近期课表有没有时间冲突", icon: "clock")
            }.padding(.vertical, 6)
            Label("发送前确认数据范围，修改日程前预览并确认。", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 500, alignment: .leading).frame(maxWidth: .infinity).padding(.vertical, 36)
    }
    private func suggestion(_ text: String, icon: String) -> some View {
        Button { session.question = text } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20)
                Text(text).font(.callout).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
            }.padding(13).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(!session.canManageConversations)
    }
    private func messageRow(_ entry: AssistantChatEntry) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if entry.role == "你" { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 9) {
                if entry.role == "本机证据" {
                    DisclosureGroup {
                        ForEach(AssistantDetailNode.parse(entry.text)) { AssistantDetailTree(node: $0) }
                    } label: { Label("查看本机证据", systemImage: "doc.text.magnifyingglass") }.font(.callout)
                } else {
                    HStack(spacing: 8) {
                        Label(entry.role, systemImage: entry.role == "你" ? "person.crop.circle" : "sparkles")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        if let status = entry.status, status != "完成" {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if entry.role == "助手" { AssistantMarkdownView(text: entry.text) }
                    else { Text(entry.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.padding(16)
                .frame(maxWidth: entry.role == "你" ? 600 : .infinity, alignment: .leading)
                .background(entry.role == "你" ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 16))
            if entry.role != "你" { Spacer(minLength: 0) }
        }
    }
    private func changeCard(_ change: AssistantChange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("核对日程修改", systemImage: "calendar.badge.exclamationmark").font(.headline)
            Text(change.title).font(.headline).textSelection(.enabled)
            Text(change.summary).font(.callout).textSelection(.enabled)
            DisclosureGroup("查看全部差异（\(change.details.count) 条）") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(change.details.enumerated()), id: \.offset) { _, detail in
                            Text(detail).font(.callout).textSelection(.enabled)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 300)
            }
            Text("尚未保存。删除课程会连同其任务和学习记录一起删除；保存前自动备份。方案两分钟内有效，课表更新或任务开始后需重新生成。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消修改") { session.dismissChange(change.id) }
                Spacer()
                Button("确认应用") { Task { await session.confirmChange(change.id) } }.buttonStyle(.borderedProminent)
            }.disabled(session.applyingChange)
        }.padding(14).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private func approvalCard(_ approval: AssistantApproval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(approval.title, systemImage: approval.findings.isEmpty ? "checkmark.shield" : "hand.raised").font(.headline)
            Text(approval.summary).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !approval.findings.isEmpty {
                Text("需要你判断的内容").font(.subheadline.bold())
                ForEach(Array(approval.findings.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(finding.source + " · " + finding.reason).font(.caption).foregroundStyle(.orange)
                        Text(finding.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button("查看本次发送详情") { panel = .details }
            Text(approval.scopeNote).font(.caption).foregroundStyle(.secondary)
            Text("两分钟内有效；已发送的内容无法撤回。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("拒绝") { session.decide(approval.id, allow: false) }
                Spacer()
                Button(approval.simulated ? "确认并继续模拟" : "确认并继续") { session.decide(approval.id, allow: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(14).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if session.busy || session.applyingChange { ProgressView().controlSize(.mini) }
                Text(session.isDeletingConversation ? "正在删除对话…" : session.activity).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("询问课表，或描述要做的日程修改…", text: $session.question, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain).padding(12)
                    .disabled(session.isDeletingConversation)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("助手问题")
                if session.busy {
                    Button { session.stop() } label: { Image(systemName: "stop.fill").padding(5) }.help("停止").accessibilityLabel("停止")
                } else {
                    Button { session.send() } label: { Image(systemName: "arrow.up").padding(5) }
                        .buttonStyle(.borderedProminent).disabled(!session.canSend).keyboardShortcut(.return, modifiers: .command)
                        .help("发送（⌘↩）").accessibilityLabel("发送")
                }
            }
            HStack {
                Button("记忆 \(session.enabledMemoryCount)") { panel = .memories }.buttonStyle(.borderless)
                    .help("这些启用的记忆会随问题发送")
                Spacer()
                Text("⌘ ↩ 发送").foregroundStyle(.tertiary)
                Button("重试上个问题") { session.retry() }.buttonStyle(.borderless).disabled(!session.canRetry)
            }.font(.caption)
        }.padding(14).frame(maxWidth: 820).frame(maxWidth: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor final class AssistantWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) var session: AssistantSession?
    func show(store: PlannerStore) {
        if session == nil {
            session = AssistantSession(historyStore: store.demo ? nil : AssistantHistoryStore.local, snapshot: { [weak store] in
                guard let store, store.isReady, !store.orderSaveBusy else { return nil }
                return .init(state: store.state, now: Date(), id: store.assistantSnapshotID)
            }, applyChange: { [weak store] replacement, baseline, validUntil in
                guard let store else { return nil }
                return await store.applyAssistantChange(replacement, from: baseline, validUntil: validUntil)
            })
        }
        guard let session else { return }; show(session: session)
    }
    func show(session: AssistantSession) {
        self.session = session
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = session.simulated ? "智能助手 · 合成验收" : "智能助手 · 学习日程"
        window.collectionBehavior = [.fullScreenNone]
        window.contentViewController = NSHostingController(rootView: AssistantView(session: session))
        window.minSize = NSSize(width: 390, height: 560); window.isReleasedWhenClosed = false; window.delegate = self
        // Hosting a GeometryReader initially uses its minimum fitting size; restore the desktop default explicitly.
        window.setContentSize(NSSize(width: 1080, height: 780))
        if !session.simulated { window.setFrameAutosaveName("StudyAssistantSDKWindow") }
        window.center(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { session?.close(); window = nil }
}

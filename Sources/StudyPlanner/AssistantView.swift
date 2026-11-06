import SwiftUI
import AppKit

struct AssistantView: View {
    @Bindable var session: AssistantSession
    @State private var sidebarVisible = true
    @State private var settingsExpanded = false
    @State private var panel: Panel?
    private enum Panel: String, Identifiable {
        case history, settings, memories, details
        var id: String { rawValue }
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            HStack(spacing: 0) {
                if wide && sidebarVisible {
                    sidebar.frame(width: 250)
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
                    HStack {
                        Spacer()
                        Button("完成") { panel = nil }.keyboardShortcut(.cancelAction)
                    }
                    switch selected {
                    case .history: history
                    case .settings:
                        Text("API 设置").font(.title2.bold())
                        ScrollView { settings }
                    case .memories: AssistantMemoryView(session: session)
                    case .details:
                        if let approval = session.approval { AssistantRequestDetailsView(request: approval.request) }
                        else { Text("此确认已结束。") }
                    }
                }.padding(18)
                    .frame(width: max(320, min(680, geometry.size.width - 36)), height: max(380, min(650, geometry.size.height - 40)))
            }
        }
        .frame(minWidth: 390, minHeight: 520)
        .onChange(of: session.approval?.id) { _, _ in if panel == .details { panel = nil } }
    }
    private func header(wide: Bool) -> some View {
        HStack(spacing: 14) {
            Button {
                if wide { sidebarVisible.toggle() } else { panel = .history }
            } label: { Image(systemName: "sidebar.left") }
                .help("展开或收起聊天记录").accessibilityLabel("聊天记录")
            VStack(alignment: .leading, spacing: 3) {
                Text("学习助手").font(.headline)
                Text(session.simulated ? "合成验收 · 不会联网" : "只读课表 · 本机对话").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { session.newConversation() } label: { Image(systemName: "square.and.pencil") }.help("新建对话").accessibilityLabel("新建对话")
            Button { panel = .memories } label: { Image(systemName: "brain") }.help("本机记忆").accessibilityLabel("本机记忆")
            Button { panel = .settings } label: { Image(systemName: "slider.horizontal.3") }.help("API 设置").accessibilityLabel("API 设置")
        }.buttonStyle(.borderless).padding(16)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            history
            Divider()
            Button { panel = .memories } label: { Label("本机记忆 · 已启用 \(session.enabledMemoryCount) 条", systemImage: "brain") }
                .buttonStyle(.plain)
            DisclosureGroup("API 设置", isExpanded: $settingsExpanded) {
                ScrollView { settings.padding(.top, 8) }.frame(maxHeight: 330)
            }
        }.padding(14).background(Color(nsColor: .windowBackgroundColor))
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("聊天记录").font(.headline)
            Button("新建对话") { session.newConversation(); if panel == .history { panel = nil } }
            List {
                ForEach(session.conversations.sorted { $0.updatedAt > $1.updatedAt }) { conversation in
                    Button {
                        session.select(conversation.id)
                        if panel == .history { panel = nil }
                    } label: {
                        HStack { Image(systemName: "bubble.left"); Text(conversation.title).lineLimit(2); Spacer(minLength: 0) }
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(session.selectedID == conversation.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }.listStyle(.plain)
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
                    if session.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle).foregroundStyle(Color.accentColor)
                            Text("今天想了解什么？").font(.title2.bold())
                            Text("查课表、看进度，或一起理清排程冲突。").foregroundStyle(.secondary)
                            Button("今天安排了哪些课程？") { session.question = "今天安排了哪些课程？" }
                            Text("本轮课表内容只确认一次。敏感或不确定的内容会单独询问；本机判断可能有遗漏，请留意发送范围。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 32)
                    }
                    ForEach(session.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            if entry.role == "本机证据" {
                                DisclosureGroup("查看本机证据") {
                                    ForEach(AssistantDetailNode.parse(entry.text)) { AssistantDetailTree(node: $0) }
                                }.font(.callout)
                            } else {
                                HStack {
                                    Text(entry.role).font(.caption.bold()).foregroundStyle(.secondary)
                                    if entry.status != "完成" { Text(entry.status ?? "").font(.caption).foregroundStyle(.secondary) }
                                }
                                if entry.role == "助手" { AssistantMarkdownView(text: entry.text) }
                                else { Text(entry.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                        }.padding(14)
                            .background(entry.role == "你" ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                            .id(entry.id)
                    }
                    if let message = session.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if let message = session.historyMessage { Text(message).font(.callout).foregroundStyle(.red) }
                    if let approval = session.approval { approvalCard(approval) }
                    Color.clear.frame(height: 1).id("bottom")
                }.frame(maxWidth: 780).frame(maxWidth: .infinity).padding(18)
            }
            .onChange(of: session.entries.last?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.approval?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.message) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
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
                if session.busy { ProgressView().controlSize(.mini) }
                Text(session.activity).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("询问课程、课表或学习进度…", text: $session.question, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain).padding(10)
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
            session = AssistantSession(historyStore: store.demo ? nil : .local, snapshot: { [weak store] in
                guard let store, store.isReady, !store.orderSaveBusy else { return nil }
                return .init(state: store.state, now: Date(), id: store.assistantSnapshotID)
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

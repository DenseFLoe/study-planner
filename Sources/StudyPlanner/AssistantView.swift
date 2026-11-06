import SwiftUI
import AppKit

struct AssistantView: View {
    @Bindable var session: AssistantSession
    @State private var settingsExpanded = false
    @State private var detailsExpanded = false
    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("学习助手").font(.title2.bold())
                        Text(session.simulated ? "模拟验收 · 合成课表 · 不会联网" : "只读真实课表 · 对话保存在此 Mac")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if session.busy { ProgressView().controlSize(.small) }
                }.padding()
                Divider()
                transcript
                if let message = session.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal).padding(.bottom, 6) }
                if let history = session.historyMessage { Text(history).foregroundStyle(.red).padding(.horizontal) }
                if let approval = session.approval { approvalCard(approval) }
                Divider()
                composer
            }.frame(minWidth: 480)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: session.approval?.id) { _, _ in detailsExpanded = false }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("本机对话").font(.headline); Spacer(); Button { session.newConversation() } label: { Image(systemName: "square.and.pencil") }.help("新建对话").accessibilityLabel("新建对话") }
            List {
                ForEach(session.conversations.sorted { $0.updatedAt > $1.updatedAt }) { conversation in
                    Button { session.select(conversation.id) } label: {
                        HStack { Image(systemName: "bubble.left"); Text(conversation.title).lineLimit(2); Spacer() }
                            .padding(8).background(session.selectedID == conversation.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }.listStyle(.plain)
            Divider()
            DisclosureGroup("API 设置", isExpanded: $settingsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("服务商", selection: Binding(get: { session.configuration.provider }, set: { session.useProvider($0) })) {
                            ForEach(AssistantProvider.allCases) { Text($0.rawValue).tag($0) }
                        }
                        TextField("服务基础地址（到 /v1）", text: $session.configuration.baseURL)
                            .accessibilityLabel("API 服务地址")
                        Text("兼容接口用 Chat Completions；Anthropic 用 Messages。填写基础地址，不含最终接口路径。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("模型名称", text: $session.configuration.model).accessibilityLabel("模型名称")
                        SecureField("API 密钥", text: $session.key).accessibilityLabel("API 密钥")
                        if !session.simulated {
                            HStack { Button("载入密钥") { session.loadKey() }; Button("保存到钥匙串") { session.saveKey() }.disabled(session.key.isEmpty) }
                            Text("密钥只用于当前地址的认证；关闭窗口清空输入。更换地址或服务商需重新填入。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.textFieldStyle(.roundedBorder).padding(.top, 8)
                }.frame(maxHeight: 295)
            }
        }.padding(14).background(Color(nsColor: .windowBackgroundColor))
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if session.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("从一个问题开始").font(.title3.bold())
                            Text("例如：今天安排了哪些课程？\n这门课还剩多少？为什么当前课表存在冲突？")
                            Text("模型选择只读工具，本机核算事实。新增查询结果在你确认后才发送。")
                                .foregroundStyle(.secondary)
                        }.padding(.vertical, 30)
                    }
                    ForEach(session.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            if entry.role == "本机证据" {
                                DisclosureGroup("查看本机证据") { Text(entry.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            } else {
                                HStack { Text(entry.role).font(.caption.bold()); if entry.status != "完成" { Text(entry.status ?? "").font(.caption).foregroundStyle(.secondary) } }
                                Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(12).background(entry.role == "你" ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .id(entry.id)
                    }
                }.padding()
            }.onChange(of: session.entries.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }
    private func approvalCard(_ approval: AssistantApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发送前确认").font(.headline)
            // A bounded, vertically scrollable summary must not be compressed to an ellipsis
            // when the window is small or the exact request disclosure is open.
            ScrollView {
                Text(approval.summary).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(height: 104)
            DisclosureGroup("查看实际待发送内容", isExpanded: $detailsExpanded) {
                ScrollView([.vertical, .horizontal]) {
                    Text(approval.request.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(8)
                }.frame(height: 110)
            }
            HStack {
                Text("本次有效至 \(approval.expiresAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("拒绝") { session.decide(approval.id, allow: false) }
                Button(approval.simulated ? "允许本次模拟" : "确认发送") { session.decide(approval.id, allow: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(12).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).padding(12)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.activity).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(alignment: .bottom) {
                TextField("询问课程、课表或学习进度…", text: $session.question, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityLabel("助手问题")
                VStack {
                    Button("发送") { session.send() }.disabled(!session.canSend).keyboardShortcut(.return, modifiers: .command)
                    Button("停止") { session.stop() }.disabled(!session.busy)
                }
            }
            HStack { Text("⌘↩ 发送").font(.caption).foregroundStyle(.secondary); Spacer(); Button("重试上个问题") { session.retry() }.disabled(!session.canRetry) }
        }.padding(12)
    }
}

@MainActor final class AssistantWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) var session: AssistantSession?
    func show(store: PlannerStore) {
        if session == nil {
            session = AssistantSession(historyStore: store.demo ? nil : .local, snapshot: { [weak store] in
                guard let store, store.isReady, !store.orderSaveBusy else { return nil }
                return .init(state: store.state, now: Date())
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
        window.minSize = NSSize(width: 780, height: 620); window.isReleasedWhenClosed = false; window.delegate = self
        if !session.simulated { window.setFrameAutosaveName("StudyAssistantSDKWindow") }
        window.center(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { session?.close(); window = nil }
}

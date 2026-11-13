import SwiftUI
import AppKit

struct AssistantView: View {
    @Bindable var session: AssistantSession
    @State private var sidebarVisible = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var questionFocused: Bool
    @State private var historySearch = ""
    @State private var selectingHistory = false
    @State private var selectedConversations = Set<UUID>()
    @State private var panel: Panel?
    private enum Panel {
        case settings, memories, details
        case deletion([AssistantConversation])
        var id: String {
            switch self {
            case .settings: "settings"
            case .memories: "memories"
            case .details: "details"
            case .deletion(let conversations): "deletion-" + conversations.map(\.id.uuidString).joined(separator: "-")
            }
        }
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
    private var canvas: Color { colorScheme == .dark ? Color(red: 0.08, green: 0.085, blue: 0.10) : .white }
    private var surface: Color { colorScheme == .dark ? Color(white: 0.14) : Color(red: 0.965, green: 0.969, blue: 0.977) }
    private let blue = Color(red: 0.25, green: 0.42, blue: 1)
    private var content: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    header
                    transcript
                    composer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keep the transcript mounted so returning preserves its scroll position and draft.
                .opacity(panel == nil ? 1 : 0)
                .accessibilityHidden(sidebarVisible || panel != nil)
                .disabled(sidebarVisible || panel != nil)
                if let selected = panel {
                    panelPage(selected)
                }
                if sidebarVisible && panel == nil {
                    Button { toggleSidebar() } label: { Color.black.opacity(0.15) }
                        .buttonStyle(.plain).accessibilityLabel("关闭聊天记录")
                    sidebar.frame(width: min(300, geometry.size.width - 64))
                        .background(canvas)
                        .shadow(color: .black.opacity(0.06), radius: 18, x: 6)
                        .transition(.move(edge: .leading))
                }
            }
            .background(canvas).tint(blue)
        }
        .frame(minWidth: 390, minHeight: 520)
        .onChange(of: session.approval?.id) { _, _ in if panel?.id == "details" { panel = nil } }
        .onExitCommand {
            if panel != nil && !session.isDeletingConversation { panel = nil }
            else if sidebarVisible { toggleSidebar() }
        }
    }
    private func showPanel(_ selected: Panel) {
        questionFocused = false
        sidebarVisible = false
        panel = selected
    }
    private func panelPage(_ selected: Panel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { panel = nil } label: {
                    Label(selected.id == "details" ? "返回确认" : "返回对话", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(session.isDeletingConversation)
                Spacer()
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                switch selected {
                case .deletion(let conversations): deletionConfirmation(conversations)
                case .settings:
                    Text("API 设置").font(.title2.bold())
                    ScrollView { settings.padding(4) }
                case .memories: AssistantMemoryView(session: session)
                case .details:
                    if let approval = session.approval { AssistantRequestDetailsView(request: approval.request) }
                    else { Text("此确认已结束。") }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvas)
    }
    private func toggleSidebar() {
        questionFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Button { toggleSidebar() } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().frame(width: 17, height: 1.5)
                    Capsule().frame(width: 11, height: 1.5)
                }.frame(width: 38, height: 38)
                    // Plain buttons otherwise hit-test only the two thin strokes, including a gap at the center.
                    .contentShape(Rectangle())
            }.help("聊天记录").accessibilityLabel("聊天记录")
            Spacer(minLength: 0)
            Menu {
                Button("本机记忆", systemImage: "brain") { showPanel(.memories) }
                Button("API 设置", systemImage: "slider.horizontal.3") { showPanel(.settings) }
                Button("重试上个问题", systemImage: "arrow.clockwise") { session.retry() }.disabled(!session.canRetry)
                Divider()
                Button("删除当前对话…", systemImage: "trash", role: .destructive) {
                    if let conversation = session.conversations.first(where: { $0.id == session.selectedID }) {
                        requestDeletion(conversation)
                    }
                }.disabled(!session.canManageConversations)
                Button("多选删除对话…", systemImage: "checklist") {
                    selectingHistory = true; selectedConversations = []; sidebarVisible = true
                }.disabled(!session.canManageConversations)
                Button("清空全部对话…", systemImage: "trash.slash", role: .destructive) {
                    showPanel(.deletion(session.conversations))
                }.disabled(!session.canManageConversations)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 34, height: 38)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("对话操作").accessibilityLabel("对话操作")
            Button {
                session.newConversation(); questionFocused = true
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 19, weight: .regular)).frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }.disabled(!session.canManageConversations).help("新建对话").accessibilityLabel("新建对话")
        }
        .overlay {
            Text(session.visibleEntries.isEmpty ? "学习助手" : (session.conversations.first { $0.id == session.selectedID }?.title ?? "学习助手"))
                .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity).padding(.horizontal, 92).allowsHitTesting(false)
        }
        .buttonStyle(.plain).foregroundStyle(.primary).padding(.horizontal, 16).padding(.vertical, 10)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("历史对话").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { toggleSidebar() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭聊天记录")
            }
            history
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill").foregroundStyle(blue).font(.system(size: 20))
                Text("学习助手").font(.system(size: 14, weight: .medium))
                Spacer()
                Button { showPanel(.memories) } label: { Image(systemName: "brain") }
                    .help("本机记忆").accessibilityLabel("本机记忆")
                Button { showPanel(.settings) } label: { Image(systemName: "slider.horizontal.3") }
                    .help("API 设置").accessibilityLabel("API 设置")
            }.buttonStyle(.plain).padding(.vertical, 4)
        }.padding(20)
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
                Text("全部对话").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(session.conversations.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(selectingHistory ? "完成" : "多选") {
                    selectingHistory.toggle(); selectedConversations = []
                }.buttonStyle(.borderless).disabled(!session.canManageConversations)
            }
            Button {
                session.newConversation(); historySearch = ""
                sidebarVisible = false
            } label: {
                Label("开启新对话", systemImage: "plus.bubble").font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .foregroundStyle(blue).background(blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(!session.canManageConversations)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索对话", text: $historySearch).textFieldStyle(.plain).accessibilityLabel("搜索对话")
                if !historySearch.isEmpty {
                    Button { historySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                }
            }.padding(9).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            if selectingHistory {
                HStack {
                    Button("全选结果") { selectedConversations.formUnion(filteredConversations.map(\.id)) }
                    Spacer()
                    Button("删除已选（\(selectedConversations.count)）", role: .destructive) {
                        showPanel(.deletion(session.conversations.filter { selectedConversations.contains($0.id) }))
                    }.disabled(selectedConversations.isEmpty)
                }.font(.caption).disabled(!session.canManageConversations)
            }
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
            HStack {
                Text("聊天记录仅保存在这台 Mac").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("清空…", role: .destructive) { showPanel(.deletion(session.conversations)) }
                    .buttonStyle(.borderless).font(.caption).disabled(!session.canManageConversations)
            }
        }
    }
    private func conversationRow(_ conversation: AssistantConversation) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                if selectingHistory {
                    if !selectedConversations.insert(conversation.id).inserted { selectedConversations.remove(conversation.id) }
                } else {
                    session.select(conversation.id)
                    sidebarVisible = false
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    if selectingHistory {
                        Image(systemName: selectedConversations.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conversation.title).font(.callout.weight(.medium)).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(selectingHistory ? (selectedConversations.contains(conversation.id) ? "已选择" : "未选择") : "")
            Menu {
                Button("删除对话…", systemImage: "trash", role: .destructive) { requestDeletion(conversation) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("对话菜单：" + conversation.title)
        }.padding(11)
            .background(session.selectedID == conversation.id ? surface : .clear,
                        in: RoundedRectangle(cornerRadius: 11))
            .contextMenu {
                Button("删除对话…", systemImage: "trash", role: .destructive) { requestDeletion(conversation) }
            }
            .disabled(!session.canManageConversations)
    }
    private func requestDeletion(_ conversation: AssistantConversation) {
        showPanel(.deletion([conversation]))
    }
    private func deletionConfirmation(_ conversations: [AssistantConversation]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(conversations.count == 1 ? "删除这段对话？" : "删除这 \(conversations.count) 段对话？", systemImage: "trash").font(.title2.bold())
            Text(conversations.prefix(3).map(\.title).joined(separator: "、") + (conversations.count > 3 ? "等" : ""))
                .font(.headline).lineLimit(2)
            Text("删除后无法恢复。课表、设置和本机记忆会保留。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if conversations.contains(where: { $0.id == session.selectedID }) && session.busy {
                Text("当前回答也会停止。").font(.callout).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                Button("取消") { panel = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                if session.isDeletingConversation { ProgressView().controlSize(.small) }
                Button("删除对话", role: .destructive) {
                    Task {
                        let deleted = await session.deleteConversations(Set(conversations.map(\.id)))
                        if deleted { historySearch = ""; selectedConversations = []; selectingHistory = false }
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
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if session.visibleEntries.isEmpty {
                            welcome.frame(minHeight: max(180, geometry.size.height - 48))
                        }
                        ForEach(session.visibleEntries) { entry in
                            VStack(alignment: .leading, spacing: 14) {
                                messageRow(entry)
                                if let steps = entry.steps, !steps.isEmpty {
                                    AssistantProgressView(steps: steps, status: entry.status)
                                }
                                if let failure = entry.failureReason {
                                    Text(failure.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                            }.id(entry.id)
                        }
                        if let message = session.message {
                            Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if let message = session.historyMessage { Text(message).font(.callout).foregroundStyle(.red) }
                        if let approval = session.approval { approvalCard(approval) }
                        if let change = session.pendingChange, !session.busy { changeCard(change) }
                        if let undo = session.undoChange {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("可撤销：" + undo.title).font(.callout)
                                Button("撤销上次助手修改") { Task { await session.undoLastChange() } }
                                    .disabled(session.busy || session.applyingChange)
                                Text("仅在日程未再次变化时恢复；修改前的自动备份也可在「数据与备份」中查看。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 18)
                }
                .onChange(of: session.entries.last?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.selectedID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.approval?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.pendingChange?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.message) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.activity) { _, _ in if session.busy { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }
    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 37, weight: .medium)).foregroundStyle(blue)
                .accessibilityHidden(true)
            Text("嗨！今天想学些什么？").font(.system(size: 22, weight: .semibold))
            Text("查课表、看进度，用图表一起看懂学习安排。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.bottom, 28)
    }
    private func messageRow(_ entry: AssistantChatEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.role == "你" {
                HStack {
                    Spacer(minLength: 40)
                    Text(entry.text).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                        .padding(.horizontal, 17).padding(.vertical, 13)
                        .background(surface, in: RoundedRectangle(cornerRadius: 20))
                }
            } else {
                if entry.role == "助手" {
                    AssistantMarkdownView(text: entry.text)
                } else {
                    Text(entry.text).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let status = entry.status, status != "完成" {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if entry.role == "助手" {
                    HStack(spacing: 18) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(AssistantMarkdown.copyText(entry.text), forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .help("复制回答").accessibilityLabel("复制回答")
                        if entry.id == session.visibleEntries.last?.id {
                            Button { session.retry() } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(!session.canRetry).help("重新生成").accessibilityLabel("重新生成")
                        }
                    }.font(.system(size: 13)).foregroundStyle(.secondary).buttonStyle(.plain).padding(.top, 2)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
            Button("查看本次发送详情") { showPanel(.details) }
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
        VStack(spacing: 10) {
            if session.busy || session.applyingChange || session.isDeletingConversation {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(session.isDeletingConversation ? "正在删除对话…" : session.activity)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12)
            }
            VStack(alignment: .leading, spacing: 14) {
                TextField("发消息，或描述你的学习安排", text: $session.question, axis: .vertical)
                    .font(.system(size: 15)).lineSpacing(4).lineLimit(2...6).textFieldStyle(.plain)
                    .focused($questionFocused).disabled(session.isDeletingConversation)
                    .accessibilityLabel("助手问题")
                    .padding(.horizontal, 4).padding(.top, 4)
                HStack(spacing: 8) {
                    Button { showPanel(.memories) } label: {
                        Label("本机记忆", systemImage: "brain")
                    }.buttonStyle(AssistantChipStyle(selected: session.enabledMemoryCount > 0, blue: blue))
                        .help("管理随问题发送的本机记忆（已启用 \(session.enabledMemoryCount) 条）")
                    Button { showPanel(.settings) } label: {
                        Label("模型设置", systemImage: "slider.horizontal.3")
                    }.buttonStyle(AssistantChipStyle(selected: false, blue: blue)).accessibilityLabel("API 设置")
                    Spacer(minLength: 0)
                    Menu {
                        Button("今天安排了哪些课程？", systemImage: "calendar") { session.question = "今天安排了哪些课程？"; questionFocused = true }
                        Button("查看各门课程的学习进度", systemImage: "chart.bar") { session.question = "帮我看看各门课程的学习进度"; questionFocused = true }
                        Button("生成近七天学习图表", systemImage: "chart.xyaxis.line") { session.question = "请用图表对比近七天每天的实际学习分钟和计划分钟，并简要说明。"; questionFocused = true }
                        Button("检查近期课表的时间冲突", systemImage: "clock") { session.question = "检查一下近期课表有没有时间冲突"; questionFocused = true }
                    } label: {
                        Image(systemName: "plus.circle").font(.system(size: 22, weight: .light)).frame(width: 26, height: 34)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(session.busy || !session.canManageConversations).help("快捷提问").accessibilityLabel("快捷提问")
                    if session.busy {
                        Button { session.stop() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 12)).frame(width: 34, height: 34)
                                .foregroundStyle(.white).background(blue, in: Circle())
                        }.buttonStyle(.plain).help("停止回答").accessibilityLabel("停止")
                    } else {
                        Button { session.send() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)).frame(width: 34, height: 34)
                                .foregroundStyle(session.canSend ? .white : Color.secondary.opacity(0.65))
                                .background(session.canSend ? blue : Color.primary.opacity(0.06), in: Circle())
                        }.buttonStyle(.plain).disabled(!session.canSend).keyboardShortcut(.return, modifiers: .command)
                            .help("发送（⌘↩）").accessibilityLabel("发送")
                    }
                }
            }
            .padding(14).background(surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.035), lineWidth: 1) }
            AssistantUsageBar(usage: session.latestUsage, busy: session.busy,
                              hasHistory: session.entries.contains { $0.role == "你" })
            Text(session.simulated ? "合成验收 · 不会联网" : "内容由 AI 生成 · 日程修改须经你确认")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }.frame(maxWidth: 744).frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 8)
    }

}

private struct AssistantProgressView: View {
    let steps: [String]
    let status: String?
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 8) {
                        if index == steps.count - 1 && status == "处理中" {
                            ProgressView().controlSize(.mini).frame(width: 14)
                        } else {
                            Image(systemName: index == steps.count - 1 && status != "完成" ? "pause.circle" : "checkmark.circle")
                                .frame(width: 14).foregroundStyle(.secondary)
                        }
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.top, 8)
        } label: {
            Label("查询过程 · \(status == "处理中" ? "进行中" : status == "完成" ? "已完成" : "已停止")", systemImage: "list.bullet")
        }.font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.1)).frame(width: 2) }
            .onAppear { expanded = status == "处理中" }
            .onChange(of: status) { _, value in expanded = value == "处理中" }
    }
}

private struct AssistantChipStyle: ButtonStyle {
    let selected: Bool
    let blue: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(selected ? blue : .primary)
            .background(selected ? blue.opacity(0.09) : Color.primary.opacity(configuration.isPressed ? 0.08 : 0.025), in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? blue.opacity(0.18) : Color.primary.opacity(0.08), lineWidth: 0.7) }
            .opacity(configuration.isPressed ? 0.7 : 1)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = session.simulated ? "智能助手 · 合成验收" : "智能助手 · 学习日程"
        window.collectionBehavior = [.fullScreenNone]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .controlBackgroundColor
        window.contentViewController = NSHostingController(rootView: AssistantView(session: session))
        window.minSize = NSSize(width: 390, height: 560); window.isReleasedWhenClosed = false; window.delegate = self
        // Hosting a GeometryReader initially uses its minimum fitting size; restore the desktop default explicitly.
        window.setContentSize(NSSize(width: 860, height: 760))
        if !session.simulated { window.setFrameAutosaveName("StudyAssistantSDKWindow") }
        window.center(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { session?.close(); window = nil }
}

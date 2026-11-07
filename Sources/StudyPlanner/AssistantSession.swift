import Foundation
import Observation
import StudyCore

@MainActor @Observable final class AssistantSession {
    var configuration: AssistantConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            if busy { stop(reason: .changed) }
            if configuration.provider != oldValue.provider || configuration.baseURL != oldValue.baseURL {
                if !key.isEmpty { knownKeys.insert(key) }
                key = ""
            }
            schedulePersistence()
        }
    }
    var key = "" {
        didSet {
            if key != oldValue && busy { stop(reason: .changed) }
        }
    }
    var question = "" { didSet { if question != oldValue && busy { stop(reason: .changed) } } }
    private(set) var conversations: [AssistantConversation]
    private(set) var selectedID: UUID
    private(set) var memories: [AssistantMemory]
    private(set) var memoryError: String?
    private(set) var approval: AssistantApproval?
    private(set) var busy = false
    private(set) var pendingChange: AssistantChange?
    private(set) var undoChange: AssistantUndo?
    private(set) var applyingChange = false
    private(set) var activity = "按需查询 · 修改须核对确认"
    private(set) var message: String?
    private(set) var historyMessage: String?
    private(set) var isLoadingHistory = false
    private(set) var isDeletingConversation = false
    private(set) var evidence: [AssistantToolEvidence] = []
    let simulated: Bool
    @ObservationIgnored private let historyWriter: AssistantHistoryWriter
    @ObservationIgnored private var persistenceID = UUID()
    @ObservationIgnored private let snapshotProvider: @MainActor () -> AssistantSnapshot?
    @ObservationIgnored private let transportFactory: @MainActor () -> any AssistantTransport
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let applyChange: @MainActor (PlannerState, PlannerState, Date?) async -> PlannerState?
    @ObservationIgnored private var historyWritable = true
    @ObservationIgnored private var historyLoadTask: Task<Void, Never>?
    @ObservationIgnored private var runner: AssistantRunner?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Error>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var knownKeys = Set<String>()
    @ObservationIgnored private var changeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var deletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(historyStore: (any AssistantHistoryPersistence)? = AssistantHistoryStore.local, directory: URL? = AssistantRunner.bundledDirectory,
         simulated: Bool = false, snapshot: @escaping @MainActor () -> AssistantSnapshot?,
         transportFactory: @escaping @MainActor () -> any AssistantTransport = { AssistantHTTPTransport() },
         applyChange: @escaping @MainActor (PlannerState, PlannerState, Date?) async -> PlannerState? = { _, _, _ in nil }) {
        self.snapshotProvider = snapshot; self.directory = directory; self.applyChange = applyChange
        self.historyWriter = AssistantHistoryWriter(store: historyStore)
        self.simulated = simulated; self.transportFactory = transportFactory
        configuration = .init(); memories = []
        let initial = AssistantConversation()
        conversations = [initial]; selectedID = initial.id
        if historyStore != nil {
            isLoadingHistory = true; historyWritable = false
            historyLoadTask = Task { @MainActor [weak self, historyWriter] in
                let result = await historyWriter.load()
                guard let self else { return }
                switch result {
                case .success(let saved):
                    // Keep persistence disabled while applying the loaded configuration.
                    self.configuration = saved.configuration
                    self.conversations = saved.conversations
                    self.selectedID = saved.selectedID ?? saved.conversations[0].id
                    self.memories = saved.memories
                    self.historyWritable = true
                case .failure:
                    self.historyMessage = AssistantError.history.rawValue
                }
                self.isLoadingHistory = false
                self.historyLoadTask = nil
            }
        }
    }
    func waitUntilReady() async { await historyLoadTask?.value }
    var entries: [AssistantChatEntry] { conversations.first { $0.id == selectedID }?.entries ?? [] }
    var visibleEntries: [AssistantChatEntry] { entries.filter { $0.role != "本机证据" } }
    var canRetry: Bool { !busy && canManageConversations && entries.contains { $0.role == "你" } }
    var canManageConversations: Bool { historyWritable && !isLoadingHistory && !applyingChange && !isDeletingConversation }
    var canSend: Bool { !busy && canManageConversations && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var enabledMemoryCount: Int { memories.filter(\.enabled).count }
    @discardableResult func saveMemory(id: UUID? = nil, text: String, enabled: Bool) -> Bool {
        do {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 2000, id != nil || memories.count < 50 else { throw AssistantError.limit }
            try checkContent(text)
            guard historyWritable else { throw AssistantError.history }
            var next = memories
            if let id {
                guard let index = next.firstIndex(where: { $0.id == id }) else { throw AssistantError.changed }
                next[index] = .init(id: id, text: text, enabled: enabled)
            } else { next.append(.init(text: text, enabled: enabled)) }
            stop(reason: .changed)
            let original = memories; memories = next
            guard persist() else { memories = original; throw AssistantError.history }
            memoryError = nil; return true
        } catch { memoryError = AssistantError.safe(error).rawValue; return false }
    }
    func deleteMemory(_ id: UUID) {
        guard historyWritable, memories.contains(where: { $0.id == id }) else { return }
        stop(reason: .changed)
        let original = memories; memories.removeAll { $0.id == id }
        if !persist() { memories = original; memoryError = AssistantError.history.rawValue }
        else { memoryError = nil }
    }
    func setMemoryEnabled(_ id: UUID, _ enabled: Bool) {
        guard let memory = memories.first(where: { $0.id == id }) else { return }
        saveMemory(id: id, text: memory.text, enabled: enabled)
    }
    private func checkContent(_ text: String) throws {
        try AssistantSecrets.check(text, key: key)
        for secret in knownKeys { try AssistantSecrets.check(text, key: secret) }
    }
    func newConversation() {
        guard canManageConversations else { return }
        stop(); guard conversations.count < 100 else { message = "最多保留100个对话，请先删除不需要的记录。"; return }
        let value = AssistantConversation(); conversations.insert(value, at: 0); selectedID = value.id
        question = ""; evidence = []; message = nil; activity = "按需查询 · 修改须核对确认"; schedulePersistence()
    }
    func select(_ id: UUID) {
        guard canManageConversations else { return }
        guard id != selectedID, conversations.contains(where: { $0.id == id }) else { return }
        stop(); selectedID = id; question = ""; evidence = []; message = nil; activity = "按需查询 · 修改须核对确认"; schedulePersistence()
    }
    @discardableResult func deleteConversation(_ id: UUID) async -> Bool {
        await deleteConversations([id])
    }
    @discardableResult func deleteConversations(_ ids: Set<UUID>) async -> Bool {
        guard canManageConversations else { return false }
        guard conversations.contains(where: { ids.contains($0.id) }) else { return false }
        let originalSelection = selectedID
        let wasSelected = ids.contains(selectedID)
        if wasSelected { stop() } // Invalidates approval and ignores even a late transport response.
        let removed = conversations.enumerated().filter { ids.contains($0.element.id) }
        isDeletingConversation = true
        defer {
            isDeletingConversation = false
            let waiters = deletionWaiters; deletionWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        conversations.removeAll { ids.contains($0.id) }
        var placeholderID: UUID?
        if conversations.isEmpty {
            let placeholder = AssistantConversation()
            conversations = [placeholder]; placeholderID = placeholder.id
        }
        if wasSelected {
            selectedID = conversations.max(by: { $0.updatedAt < $1.updatedAt })!.id
            question = ""; evidence = []; message = nil; activity = "按需查询 · 修改须核对确认"
        }
        if await persistInBackground() { return true }
        // Restore only this deletion, retaining any newer answer/configuration changes.
        if let placeholderID { conversations.removeAll { $0.id == placeholderID } }
        for item in removed { conversations.insert(item.element, at: min(item.offset, conversations.count)) }
        if wasSelected { selectedID = originalSelection }
        message = "对话删除未保存，记录已恢复。请稍后重试。"
        schedulePersistence() // Ordered after any snapshots queued while deletion was saving.
        return false
    }
    func useProvider(_ provider: AssistantProvider) {
        configuration = .init(provider: provider, baseURL: provider.baseURL, model: "")
    }
    func saveKey() {
        guard !simulated else { return }
        do { try AssistantVault.save(key, config: configuration); knownKeys.insert(key); message = "密钥已保存在此 Mac 钥匙串，仅对应当前服务地址。" }
        catch { message = AssistantError.safe(error).rawValue }
    }
    func loadKey() {
        guard !simulated else { return }
        do { key = try AssistantVault.load(configuration); knownKeys.insert(key); message = "已载入当前地址的密钥。" }
        catch { message = AssistantError.safe(error).rawValue }
    }
    func retry() {
        guard !busy, let last = entries.last(where: { $0.role == "你" }) else { return }
        question = last.text; send()
    }
    func send() {
        guard canSend else { return }
        pendingChange = nil
        do {
            let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.utf8.count <= 6000 else { throw AssistantError.limit }
            try checkContent(text)
            try checkContent(String(decoding: assistantJSON(configuration), as: UTF8.self))
            _ = try configuration.endpoint()
            if !simulated { try AssistantSecrets.validateKey(key); knownKeys.insert(key) }
            guard let directory else { throw AssistantError.runtime }
            let history = entries, memories = memories
            append(.init(role: "你", text: text, status: "处理中"))
            question = ""; evidence = []; message = nil
            let id = UUID(), conversationID = selectedID, config = configuration, secret = key
            let secrets = knownKeys.union([secret])
            runID = id; busy = true; recordActivity("正在准备查询…")
            work = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let messages = try await Task.detached(priority: .userInitiated) {
                        let memory = try AssistantMemories.message(memories)
                        let messages = (memory.map { [$0] } ?? []) + history.filter { $0.status == "完成" && ["你", "助手", "本机操作"].contains($0.role) }
                            .map { AssistantWireMessage(role: $0.role == "你" ? "user" : "assistant", content: $0.role == "本机操作" ? "本机操作记录：" + $0.text : $0.text) }
                            + [.init(role: "user", content: text)]
                        let data = try assistantJSON(messages)
                        guard data.count <= 200_000 else { throw AssistantError.limit }
                        let text = String(decoding: data, as: UTF8.self)
                        try AssistantSecrets.check(text)
                        for key in secrets where !key.isEmpty { try AssistantSecrets.check(text, key: key) }
                        return messages
                    }.value
                    guard self.runID == id else { return }
                    guard await self.persistInBackground() else { throw AssistantError.history }
                    guard self.runID == id else { return }
                    var answer = "", scopeConfirmed = false, refreshes = 0
                    while true {
                        try Task.checkCancellation()
                        guard self.runID == id else { return }
                        let snapshot = try await self.freshSnapshot()
                        let runner = AssistantRunner(); self.runner = runner
                        let transport = self.transportFactory()
                        guard transport.simulated == self.simulated else { throw AssistantError.protocolError }
                        do {
                            answer = try await runner.run(configuration: config, messages: messages, snapshot: snapshot,
                                key: secret, directory: directory, transport: transport,
                                currentSnapshotID: { [weak self] in self?.snapshotProvider()?.id ?? "unavailable" },
                                scopeAlreadyConfirmed: scopeConfirmed,
                                approve: { [weak self] approval in
                                    guard let self, self.runID == id else { throw AssistantError.stopped }
                                    let allow = try await self.waitForApproval(approval)
                                    if allow { scopeConfirmed = true }
                                    return allow
                                }, activity: { [weak self] value in if self?.runID == id { self?.recordActivity(value) } },
                                evidence: { [weak self] value in if self?.runID == id { self?.evidence.append(value) } },
                                proposal: { [weak self] value in if self?.runID == id { self?.pendingChange = value } })
                            guard self.runID == id else { return }
                            guard self.snapshotProvider()?.id == snapshot.id else { throw AssistantError.snapshotChanged }
                            break
                        } catch AssistantError.snapshotChanged {
                            guard self.runID == id else { return }
                            self.evidence = []; self.pendingChange = nil
                            // Bound automatic re-queries so continuous edits cannot incur unlimited requests.
                            guard refreshes < 3 else { throw AssistantError.snapshotChanged }
                            refreshes += 1
                            self.recordActivity("课表已更新，正在重新查询…")
                            try await Task.sleep(for: .milliseconds(250))
                        }
                    }
                    guard self.runID == id, self.selectedID == conversationID else { return }
                    self.recordActivity("查询完成")
                    self.markPending("完成")
                    self.append(.init(role: "助手", text: AssistantMarkdown.answerText(answer), status: "完成"))
                    self.activity = "回答完成 · 可继续追问"
                } catch {
                    guard self.runID == id else { return }
                    self.pendingChange = nil
                    self.markPending("未完成")
                    self.message = AssistantError.safe(error).rawValue; self.activity = "本轮已结束 · 可重试"
                }
                guard self.runID == id else { return }
                await self.persistInBackground()
                guard self.runID == id else { return }
                self.finish()
            }
        } catch { message = AssistantError.safe(error).rawValue }
    }
    private func freshSnapshot() async throws -> AssistantSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            try Task.checkCancellation()
            if let snapshot = snapshotProvider() { return snapshot }
            guard ContinuousClock.now < deadline else { throw AssistantError.snapshotChanged }
            recordActivity("正在等待课表更新完成…")
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func recordActivity(_ value: String) {
        activity = value
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }),
              let entry = conversations[index].entries.lastIndex(where: { $0.role == "你" && $0.status == "处理中" }) else { return }
        var steps = conversations[index].entries[entry].steps ?? []
        guard steps.last != value, steps.count < 120 else { return }
        steps.append(value); conversations[index].entries[entry].steps = steps
    }
    func dismissChange(_ id: UUID) {
        guard !busy, !applyingChange, pendingChange?.id == id else { return }
        pendingChange = nil
        append(.init(role: "本机操作", text: "已取消修改方案，日程未改变。", status: "完成"))
        schedulePersistence()
    }
    func confirmChange(_ id: UUID) async {
        guard !busy, !applyingChange, !isDeletingConversation, let change = pendingChange, change.id == id else { return }
        do {
            guard let snapshot = snapshotProvider() else { throw AssistantError.changed }
            try change.validate(snapshot: snapshot)
        } catch {
            pendingChange = nil
            message = "修改方案已过期或日程已变化，未写入；请重新发送指令并核对新预览。"
            return
        }
        pendingChange = nil; applyingChange = true; activity = "正在保存已确认的修改…"
        defer { finishChange() }
        let saved = await applyChange(change.after, change.before, change.validUntil)
        if let actual = saved {
            undoChange = .init(title: change.title, before: change.before, after: actual)
            append(.init(role: "本机操作", text: "已应用：" + change.title + "\n" + change.summary + "\n修改前已创建自动备份，可撤销本次修改。", status: "完成"))
            message = nil
        } else {
            message = "修改未保存。课表可能已有更新，或备份/写入失败；请查看主窗口提示，重新查询后再提出方案。"
        }
        activity = "本机操作结束"
        await persistInBackground()
    }
    func undoLastChange() async {
        guard !busy, !applyingChange, !isDeletingConversation, let undo = undoChange else { return }
        guard let current = snapshotProvider(), current.state == undo.after else {
            message = "修改后日程已有更新，不能直接撤销以免覆盖新数据。请到「数据与备份」核对修改前的自动备份。"; return
        }
        pendingChange = nil; applyingChange = true; activity = "正在撤销助手修改…"
        defer { finishChange() }
        let saved = await applyChange(undo.before, undo.after, nil)
        if saved != nil {
            undoChange = nil; message = nil
            append(.init(role: "本机操作", text: "已撤销：" + undo.title + "。", status: "完成"))
        } else { message = "撤销未保存，当前数据已保留。请查看主窗口提示。" }
        activity = "本机操作结束"
        await persistInBackground()
    }

    private func finishChange() {
        applyingChange = false
        let waiters = changeWaiters; changeWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    private func waitForApproval(_ value: AssistantApproval) async throws -> Bool {
        approval = value
        return try await withCheckedThrowingContinuation { continuation in
            decision = continuation
            expiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, value.expiresAt.timeIntervalSinceNow))) } catch { return }
                guard let self, self.approval?.id == value.id else { return }
                self.stop(reason: .expired)
            }
        }
    }
    func decide(_ id: UUID, allow: Bool) {
        guard let value = approval, value.id == id, let decision else { return }
        self.decision = nil; approval = nil; expiry?.cancel(); expiry = nil
        guard Date() < value.expiresAt else { decision.resume(throwing: AssistantError.expired); return }
        decision.resume(returning: allow)
    }
    func stop(reason: AssistantError = .stopped) {
        pendingChange = nil
        guard busy || decision != nil else { return }
        runID = nil
        if let runner { Task { await runner.cancel() } }
        work?.cancel()
        let pending = decision; decision = nil; approval = nil; expiry?.cancel(); expiry = nil
        pending?.resume(throwing: reason)
        markPending("未完成"); busy = false; runner = nil; work = nil
        message = reason.rawValue; activity = "本轮已停止 · 可重试"; schedulePersistence()
    }
    func close() {
        // AppKit's close callback must return immediately, even with queued disk work.
        // Keep this session and its writer alive across reopening so saves stay ordered.
        // Edits already enqueue their snapshots; idle closes must not pile up duplicate writes.
        stop()
        key = ""
    }
    func prepareToQuit() async -> Bool {
        stop(); key = ""
        if applyingChange { await withCheckedContinuation { changeWaiters.append($0) } }
        if isDeletingConversation { await withCheckedContinuation { deletionWaiters.append($0) } }
        await waitUntilReady()
        guard historyWritable else { return true } // Preserve an unreadable original file.
        return await persistInBackground()
    }
    private func finish() {
        busy = false; runID = nil; runner = nil; work = nil; approval = nil
        expiry?.cancel(); expiry = nil
    }
    private func append(_ entry: AssistantChatEntry) {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        conversations[index].entries.append(entry); conversations[index].updatedAt = Date()
    }
    private func markPending(_ status: String) {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        for j in conversations[index].entries.indices where conversations[index].entries[j].status == "处理中" {
            conversations[index].entries[j].status = status
        }
    }
    @discardableResult private func persist() -> Bool {
        guard historyWritable else { return false }
        persistenceID = UUID()
        do {
            let workspace = AssistantWorkspace(configuration: configuration, conversations: conversations, selectedID: selectedID, memories: memories)
            // Do not allow configuration fields or responses to smuggle the active credential into history.
            try historyWriter.save(workspace, secrets: knownKeys.union([key])); historyMessage = nil; return true
        } catch { historyMessage = AssistantError.safe(error) == .sensitive ? AssistantError.sensitive.rawValue : AssistantError.history.rawValue; return false }
    }
    @discardableResult private func persistInBackground() async -> Bool {
        guard historyWritable else { return false }
        let id = UUID(); persistenceID = id
        let workspace = AssistantWorkspace(configuration: configuration, conversations: conversations, selectedID: selectedID, memories: memories)
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            // Enqueue before yielding MainActor so edits cannot overtake an older snapshot.
            historyWriter.enqueue(workspace, secrets: knownKeys.union([key])) { continuation.resume(returning: $0) }
        }
        do {
            try result.get()
            if persistenceID == id { historyMessage = nil }
            return true
        } catch {
            if persistenceID == id {
                historyMessage = AssistantError.safe(error) == .sensitive ? AssistantError.sensitive.rawValue : AssistantError.history.rawValue
            }
            return false
        }
    }
    private func schedulePersistence() {
        guard historyWritable else { return }
        let id = UUID(); persistenceID = id
        let workspace = AssistantWorkspace(configuration: configuration, conversations: conversations, selectedID: selectedID, memories: memories)
        historyWriter.enqueue(workspace, secrets: knownKeys.union([key])) { [weak self] result in
            Task { @MainActor in
                guard let self, self.persistenceID == id else { return }
                switch result {
                case .success: self.historyMessage = nil
                case .failure(let error):
                    self.historyMessage = AssistantError.safe(error) == .sensitive ? AssistantError.sensitive.rawValue : AssistantError.history.rawValue
                }
            }
        }
    }
}

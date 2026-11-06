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
    private(set) var activity = "只读查询 · 本轮课表内容确认一次"
    private(set) var message: String?
    private(set) var historyMessage: String?
    private(set) var evidence: [AssistantToolEvidence] = []
    let simulated: Bool
    @ObservationIgnored private let historyWriter: AssistantHistoryWriter
    @ObservationIgnored private var persistenceID = UUID()
    @ObservationIgnored private let snapshotProvider: @MainActor () -> AssistantSnapshot?
    @ObservationIgnored private let transportFactory: @MainActor () -> any AssistantTransport
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var historyWritable = true
    @ObservationIgnored private var runner: AssistantRunner?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Error>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var knownKeys = Set<String>()

    init(historyStore: AssistantHistoryStore? = .local, directory: URL? = AssistantRunner.bundledDirectory,
         simulated: Bool = false, snapshot: @escaping @MainActor () -> AssistantSnapshot?,
         transportFactory: @escaping @MainActor () -> any AssistantTransport = { AssistantHTTPTransport() }) {
        self.snapshotProvider = snapshot; self.directory = directory
        self.historyWriter = AssistantHistoryWriter(store: historyStore)
        self.simulated = simulated; self.transportFactory = transportFactory
        var saved = AssistantWorkspace(), loadFailed = false
        do { saved = try historyStore?.load() ?? saved } catch { loadFailed = true }
        configuration = saved.configuration
        memories = saved.memories
        let loaded = saved.conversations.isEmpty ? [AssistantConversation()] : saved.conversations
        conversations = loaded
        selectedID = loaded.contains { $0.id == saved.selectedID } ? saved.selectedID! : loaded[0].id
        for i in conversations.indices {
            for j in conversations[i].entries.indices where conversations[i].entries[j].status == "处理中" {
                conversations[i].entries[j].status = "上次已中断 · 未续传"
            }
        }
        historyWritable = !loadFailed
        if loadFailed { historyMessage = AssistantError.history.rawValue }
    }
    var entries: [AssistantChatEntry] { conversations.first { $0.id == selectedID }?.entries ?? [] }
    var canRetry: Bool { !busy && entries.contains { $0.role == "你" } }
    var canSend: Bool { !busy && historyWritable && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        stop(); guard conversations.count < 100 else { message = "最多保留100个对话。"; return }
        let value = AssistantConversation(); conversations.insert(value, at: 0); selectedID = value.id
        question = ""; evidence = []; message = nil; activity = "只读查询 · 本轮课表内容确认一次"; schedulePersistence()
    }
    func select(_ id: UUID) {
        guard id != selectedID, conversations.contains(where: { $0.id == id }) else { return }
        stop(); selectedID = id; question = ""; evidence = []; message = nil; activity = "只读查询 · 本轮课表内容确认一次"; schedulePersistence()
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
        do {
            let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.utf8.count <= 6000 else { throw AssistantError.limit }
            try checkContent(text)
            try checkContent(String(decoding: assistantJSON(configuration), as: UTF8.self))
            _ = try configuration.endpoint()
            if !simulated { try AssistantSecrets.validateKey(key); knownKeys.insert(key) }
            guard let snapshot = snapshotProvider() else { throw AssistantError.changed }
            guard let directory else { throw AssistantError.runtime }
            let history = entries, memories = memories
            let transport = transportFactory()
            guard transport.simulated == simulated else { throw AssistantError.protocolError }
            append(.init(role: "你", text: text, status: "处理中"))
            question = ""; evidence = []; message = nil
            let id = UUID(), conversationID = selectedID, config = configuration, secret = key
            let secrets = knownKeys.union([secret])
            runID = id; busy = true; activity = "正在准备本机查询…"
            let runner = AssistantRunner(); self.runner = runner
            work = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let messages = try await Task.detached(priority: .userInitiated) {
                        let memory = try AssistantMemories.message(memories)
                        let messages = (memory.map { [$0] } ?? []) + history.filter { $0.status == "完成" && ["你", "助手"].contains($0.role) }
                            .map { AssistantWireMessage(role: $0.role == "你" ? "user" : "assistant", content: $0.text) }
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
                    let answer = try await runner.run(configuration: config, messages: messages, snapshot: snapshot,
                        key: secret, directory: directory, transport: transport,
                        currentSnapshotID: { [weak self] in self?.snapshotProvider()?.id ?? "unavailable" },
                        approve: { [weak self] approval in
                            guard let self, self.runID == id else { throw AssistantError.stopped }
                            return try await self.waitForApproval(approval)
                        }, activity: { [weak self] value in if self?.runID == id { self?.activity = value } },
                        evidence: { [weak self] value in if self?.runID == id { self?.evidence.append(value) } })
                    guard self.runID == id, self.selectedID == conversationID else { return }
                    self.markPending("完成")
                    for item in self.evidence { self.append(.init(role: "本机证据", text: item.json, status: "完成")) }
                    self.append(.init(role: "助手", text: answer, status: "完成"))
                    self.activity = "回答完成 · 可继续追问"
                    // Citation presence is only a reference check, never a semantic correctness claim.
                    let pattern = #"\[E[0-9]+\]"#
                    let refs = answer.matches(of: try! Regex(pattern)).map { String($0.output[0].substring!) }
                    let valid = Set(self.evidence.map { "[\($0.id)]" })
                    if refs.isEmpty || refs.contains(where: { !valid.contains($0) }) {
                        self.message = "回答缺少有效证据引用，请展开本机证据核对；模型文字尚未作语义核验。"
                    }
                } catch {
                    guard self.runID == id else { return }
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
        guard busy || decision != nil else { return }
        runID = nil
        if let runner { Task { await runner.cancel() } }
        work?.cancel()
        let pending = decision; decision = nil; approval = nil; expiry?.cancel(); expiry = nil
        pending?.resume(throwing: reason)
        markPending("未完成"); busy = false; runner = nil; work = nil
        message = reason.rawValue; activity = "本轮已停止 · 可重试"; schedulePersistence()
    }
    func close() { stop(); key = ""; persist() }
    func prepareToQuit() async -> Bool {
        stop(); key = ""
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

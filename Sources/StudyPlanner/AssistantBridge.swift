import Foundation

protocol AssistantTransport: Sendable {
    var simulated: Bool { get }
    func send(_ request: AssistantRequest, key: String) async throws -> String
}
final class AssistantNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
struct AssistantHTTPTransport: AssistantTransport {
    let simulated = false
    var configurationFactory: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    func send(_ request: AssistantRequest, key: String) async throws -> String {
        try request.validate(key: key); try AssistantSecrets.validateKey(key); try Task.checkCancellation()
        let configuration = configurationFactory()
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: AssistantNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var wire = URLRequest(url: try request.configuration.endpoint(), cachePolicy: .reloadIgnoringLocalCacheData)
        wire.httpMethod = "POST"; wire.httpBody = Data(request.body.utf8)
        for (key, value) in request.headers { wire.setValue(value, forHTTPHeaderField: key) }
        if request.configuration.provider == .anthropic { wire.setValue(key, forHTTPHeaderField: "x-api-key") }
        else { wire.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await session.bytes(for: wire)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url == wire.url else { throw AssistantError.network }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw AssistantError.limit }; data.append(byte)
            }
            let text = String(decoding: data, as: UTF8.self)
            try AssistantSecrets.check(text, key: key); return text
        } catch { throw AssistantError.safe(error) }
    }
}

struct AssistantWireMessage: Codable, Sendable { let role: String; let content: String }

/// Protocol work runs on this actor, outside the UI executor. Model responses can
/// only select the same native whitelist used by the previous SDK bridge.
actor AssistantRunner {
    private var started = false
    private var deadline: ContinuousClock.Instant?
    private(set) var cancelled = false
    private(set) var sentRequests = 0
    private(set) var toolCount = 0

    func cancel() { cancelled = true }
    private func check() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw AssistantError.stopped }
        if let deadline, ContinuousClock.now >= deadline { throw AssistantError.limit }
    }
    func run(configuration: AssistantConfiguration, messages: [AssistantWireMessage], snapshot: AssistantSnapshot,
             key: String, transport: any AssistantTransport,
             currentSnapshotID: @escaping @MainActor () async throws -> String,
             scopeAlreadyConfirmed: Bool = false,
             approve: @escaping @MainActor (AssistantApproval) async throws -> Bool,
             activity: @escaping @MainActor (String) -> Void,
             evidence: @escaping @MainActor (AssistantToolEvidence) -> Void,
             proposal: @escaping @MainActor (AssistantChange) -> Void = { _ in },
             insights: @escaping @MainActor ([AssistantInsight]) -> Void = { _ in },
             usage: @escaping @MainActor (AssistantUsageEvent) -> Void = { _ in }) async throws -> String {
        guard !started else { throw AssistantError.protocolError }
        started = true; deadline = .now.advanced(by: .seconds(1200))
        try check()
        _ = try configuration.endpoint()
        try AssistantSecrets.check(String(decoding: assistantJSON(messages), as: UTF8.self), key: key)
        try AssistantSecrets.check(configuration.baseURL, key: key)
        try AssistantSecrets.check(configuration.model, key: key)
        let instructions = AssistantTools.instructions + "\n" + AssistantActions.instructions + "\n" + AssistantActions.macInstructions + "\n" + AssistantCharts.instructions + "\n" + AssistantInsights.instructions + "\n本机日期：\(snapshot.stamp(snapshot.now))；当前时间：\(snapshot.stamp(snapshot.now, time: true))；时区：\(snapshot.calendar.timeZone.identifier)。"
        var conversation = AssistantWire.messages(messages, configuration: configuration, instructions: instructions)
        var gate = AssistantApprovalGate(), callIDs = Set<String>()
        var queriedEvidence: [AssistantToolEvidence] = []
        var insightQueries: [AssistantInsightQuery] = []
        var scopeConfirmed = scopeAlreadyConfirmed, proposed = false
        while true {
            try check()
            guard try await currentSnapshotID() == snapshot.id else { throw AssistantError.snapshotChanged }
            guard sentRequests < 8 else { throw AssistantError.limit }
            let request = try AssistantWire.request(configuration: configuration, messages: conversation, instructions: instructions)
            try request.validate(key: key)
            let findings = try AssistantContentPolicy.findings(in: request, instructions: instructions, evidence: queriedEvidence)
            // The initial approval covers this turn's data scope, including private
            // free text. Still verify every actual result and reject credentials below.
            if !scopeConfirmed {
                let confirmation = try gate.prepare(request, snapshotID: snapshot.id, simulated: transport.simulated,
                                                    confirmsScope: !scopeConfirmed, findings: findings)
                await activity("请确认本轮课表内容")
                let allow = try await approve(confirmation)
                try check()
                // Approval covers the turn's query scope. A newer schedule is re-read
                // below before sending; the recipient and request remain immutable.
                guard try gate.decide(id: confirmation.id, request: request, snapshotID: snapshot.id, allow: allow) else { throw AssistantError.refused }
                scopeConfirmed = true
            }
            try check()
            guard try await currentSnapshotID() == snapshot.id else { throw AssistantError.snapshotChanged }
            await activity(sentRequests == 0 ? "正在分析问题…" : "正在整理查询结果…")
            try check()
            sentRequests += 1
            let requestStart = Date(), clockStart = ContinuousClock.now
            await usage(.requestStarted)
            try check()
            let response = try await transport.send(request, key: key)
            guard response.utf8.count <= 1_048_576 else { throw AssistantError.limit }
            try AssistantSecrets.check(response, key: key)
            let elapsed = clockStart.duration(to: .now).components
            await usage(.response(AssistantTokenUsage.parse(response, provider: configuration.provider),
                start: requestStart, end: Date(), seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
            try check()
            // Keep billed usage even when the schedule changed or the reply cannot be used.
            guard try await currentSnapshotID() == snapshot.id else { throw AssistantError.snapshotChanged }
            let reply = try AssistantWire.reply(response, configuration: configuration)
            if reply.calls.isEmpty {
                let answer = AssistantCharts.materialize(reply.text, evidence: queriedEvidence,
                    capturedAt: snapshot.stamp(snapshot.now, time: true) + " " + snapshot.calendar.timeZone.identifier)
                if !proposed { await insights(AssistantInsights.build(insightQueries, answer: answer)) }
                return answer
            }
            guard toolCount + reply.calls.count <= 24 else { throw AssistantError.limit }
            // Validate the whole batch before executing any tool or publishing a preview.
            for call in reply.calls {
                guard callIDs.insert(call.id).inserted else { throw AssistantError.protocolError }
            }
            conversation.append(reply.message)
            var results: [[String: Any]] = []
            for call in reply.calls {
                try check()
                guard try await currentSnapshotID() == snapshot.id else { throw AssistantError.snapshotChanged }
                let name = call.name, arguments = call.input
                await activity(AssistantTools.activity(for: name))
                toolCount += 1
                await usage(.tool)
                let evidenceID = "E\(toolCount)"
                let previous = queriedEvidence
                let alreadyProposed = proposed
                let toolSnapshot = transport.simulated ? snapshot : AssistantSnapshot(
                    state: snapshot.state, now: Date(), calendar: snapshot.calendar, id: snapshot.id)
                let (result, change) = try await Task.detached(priority: .userInitiated) {
                    if AssistantActions.allDefinitions.contains(where: { $0.name == name }) {
                        return try AssistantActions.execute(name: name, input: arguments, snapshot: toolSnapshot, id: evidenceID, alreadyProposed: alreadyProposed)
                    }
                    return (try AssistantTools.query(name: name, input: arguments, snapshot: toolSnapshot, id: evidenceID, previous: previous), nil as AssistantChange?)
                }.value
                try check()
                guard try await currentSnapshotID() == snapshot.id else { throw AssistantError.snapshotChanged }
                try AssistantSecrets.check(result.json, key: key)
                if let change {
                    try AssistantSecrets.check(change.title + change.summary + change.details.joined(separator: "\n"), key: key)
                    proposed = true; await proposal(change)
                }
                queriedEvidence.append(result); await evidence(result)
                insightQueries.append(.init(name: name, input: arguments, evidence: result))
                if name == "preview_focus_today", change != nil {
                    // The complete result is already computed locally. Deliver it
                    // immediately, without spending the review window on another API round.
                    return "已生成完整安排，尚未保存。请核对下方方案和全部差异，点击「确认应用」后才会保存。"
                }
                if configuration.provider == .anthropic {
                    results.append(["type": "tool_result", "tool_use_id": call.id, "content": result.json])
                } else {
                    conversation.append(["role": "tool", "tool_call_id": call.id, "content": result.json])
                }
            }
            if configuration.provider == .anthropic { conversation.append(["role": "user", "content": results]) }
        }
    }
}

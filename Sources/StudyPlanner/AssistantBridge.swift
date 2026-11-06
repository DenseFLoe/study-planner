import Foundation
import Darwin

protocol AssistantTransport: Sendable {
    var simulated: Bool { get }
    func send(_ request: AssistantRequest, key: String) async throws -> String
}
private final class AssistantNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
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
private struct AssistantFrame: Decodable {
    let type: String
    var id: String?; var url: String?; var body: String?
    var name: String?; var input: [String: String]?; var text: String?
    var node: String?; var `protocol`: Int?; var restrictions: [String: Bool]?
}
private struct AssistantReply: Encodable {
    var type = "reply"
    let id: String
    var approved: Bool? = nil
    var body: String? = nil
    var resultJSON: String? = nil
}

/// File hashing, request validation and pipe writes must never occupy the UI executor.
actor AssistantRunner {
    nonisolated static var bundledDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("AgentPrototype") }
    private var process: Process?
    private(set) var cancelled = false
    private(set) var sentRequests = 0
    private(set) var toolCount = 0

    func cancel() { cancelled = true; stopProcess() }
    private func stopProcess() {
        guard let process, process.isRunning else { return }
        process.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            // This is only the disposable, read-only SDK child, never the application saving user data.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func run(configuration: AssistantConfiguration, messages: [AssistantWireMessage], snapshot: AssistantSnapshot,
             key: String, directory: URL, transport: any AssistantTransport,
             currentSnapshotID: @escaping @MainActor () -> String,
             approve: @escaping @MainActor (AssistantApproval) async throws -> Bool,
             activity: @escaping @MainActor (String) -> Void,
             evidence: @escaping @MainActor (AssistantToolEvidence) -> Void) async throws -> String {
        guard process == nil else { throw AssistantError.protocolError }
        try Task.checkCancellation()
        guard !cancelled else { throw AssistantError.stopped }
        _ = try configuration.endpoint()
        try AssistantSecrets.check(String(decoding: assistantJSON(messages), as: UTF8.self), key: key)
        try AssistantSecrets.check(configuration.baseURL, key: key)
        try AssistantSecrets.check(configuration.model, key: key)
        let helper = directory.appendingPathComponent("assistant-helper.cjs"), node = directory.appendingPathComponent("node")
        struct Manifest: Decodable { let assistantProtocol: Int; let assistantSHA256: String; let node: String }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.assistantProtocol == 2,
              manifest.node == "26.7.0", let helperData = try? Data(contentsOf: helper), helperData.count < 16_777_216,
              assistantHash(helperData) == manifest.assistantSHA256,
              FileManager.default.isExecutableFile(atPath: node.path) else { throw AssistantError.runtime }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = node
        child.arguments = ["--permission", "--allow-fs-read=\(helper.path)", helper.path]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "zh_CN.UTF-8", "NODE_NO_WARNINGS": "1", "TMPDIR": "/private/tmp"]
        child.currentDirectoryURL = directory
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        process = child; try child.run()
        let frames = Self.frames(output.fileHandleForReading)
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1200)) } catch { return }; await self?.cancel()
        }
        defer { timeout.cancel(); stopProcess(); try? input.fileHandleForWriting.close() }
        struct Start: Encodable {
            var type = "start"; let provider: String; let baseURL: String; let model: String
            let instructions: String; let messages: [AssistantWireMessage]; let tools: [AssistantToolDefinition]
        }
        let instructions = AssistantTools.instructions + "\n本机日期：\(snapshot.stamp(snapshot.now))；时区：\(snapshot.calendar.timeZone.identifier)。"
        try Self.write(Start(provider: configuration.provider.wire, baseURL: configuration.baseURL, model: configuration.model,
                             instructions: instructions,
                             messages: messages, tools: AssistantTools.definitions), input.fileHandleForWriting)
        var ready = false, gate = AssistantApprovalGate(), frameIDs = Set<String>()
        var queriedEvidence: [AssistantToolEvidence] = []
        var scopeConfirmed = false
        for try await bytes in frames {
            if cancelled || Task.isCancelled { throw AssistantError.stopped }
            guard await currentSnapshotID() == snapshot.id else { throw AssistantError.changed }
            let frame = try JSONDecoder().decode(AssistantFrame.self, from: bytes)
            switch frame.type {
            case "ready":
                guard !ready, frame.protocol == 2, frame.node == "v26.7.0", let restrictions = frame.restrictions,
                      Set(restrictions.keys) == ["network", "fileRead", "fileWrite", "subprocess"],
                      restrictions.values.allSatisfy({ $0 }) else { throw AssistantError.protocolError }
                ready = true
            case "request":
                guard ready, sentRequests < 8, let id = frame.id, frameIDs.insert(id).inserted,
                      let url = frame.url, let body = frame.body else { throw AssistantError.protocolError }
                let request = AssistantRequest(id: id, configuration: configuration, url: url, body: body)
                try request.validate(key: key)
                let findings = try AssistantContentPolicy.findings(in: request, instructions: instructions, evidence: queriedEvidence)
                // The initial approval covers this turn's read-only scope, including private
                // free text. Still verify every actual result and reject credentials below.
                if !scopeConfirmed {
                    let confirmation = try gate.prepare(request, snapshotID: snapshot.id, simulated: transport.simulated,
                                                        confirmsScope: !scopeConfirmed, findings: findings)
                    await activity("请确认本轮课表内容")
                    let allow = try await approve(confirmation)
                    if cancelled || Task.isCancelled { gate.cancel(); throw AssistantError.stopped }
                    guard try gate.decide(id: confirmation.id, request: request, snapshotID: await currentSnapshotID(), allow: allow) else { throw AssistantError.refused }
                    scopeConfirmed = true
                }
                if cancelled || Task.isCancelled { gate.cancel(); throw AssistantError.stopped }
                guard await currentSnapshotID() == snapshot.id else { throw AssistantError.changed }
                await activity(transport.simulated ? "模拟服务正在回答…" : "等待模型回答…")
                sentRequests += 1
                let response = try await transport.send(request, key: key)
                if cancelled || Task.isCancelled { throw AssistantError.stopped }
                guard response.utf8.count <= 1_048_576 else { throw AssistantError.limit }
                try AssistantSecrets.check(response, key: key)
                try Self.write(AssistantReply(id: id, approved: true, body: response), input.fileHandleForWriting)
            case "tool":
                guard ready, sentRequests > 0, toolCount < 24, let id = frame.id, frameIDs.insert(id).inserted,
                      let name = frame.name, let arguments = frame.input else { throw AssistantError.protocolError }
                await activity("正在本机查询：\(AssistantTools.definitions.first { $0.name == name }?.description ?? "受限查询")")
                toolCount += 1
                let evidenceID = "E\(toolCount)"
                let previous = queriedEvidence
                let result = try await Task.detached(priority: .userInitiated) {
                    try AssistantTools.query(name: name, input: arguments, snapshot: snapshot, id: evidenceID, previous: previous)
                }.value
                if cancelled || Task.isCancelled { throw AssistantError.stopped }
                try AssistantSecrets.check(result.json, key: key)
                queriedEvidence.append(result); await evidence(result)
                try Self.write(AssistantReply(id: id, resultJSON: result.json), input.fileHandleForWriting)
            case "done":
                guard ready, sentRequests > 0, let text = frame.text, !text.isEmpty, text.utf8.count <= 64_000 else { throw AssistantError.protocolError }
                try AssistantSecrets.check(text, key: key)
                return text
            default: throw AssistantError.protocolError
            }
        }
        throw cancelled ? AssistantError.stopped : AssistantError.protocolError
    }
    private static func write<T: Encodable>(_ value: T, _ handle: FileHandle) throws {
        var data = try assistantJSON(value); guard data.count <= 1_048_576 else { throw AssistantError.limit }
        data.append(0x0a); try handle.write(contentsOf: data)
    }
    nonisolated private static func frames(_ handle: FileHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var buffer = Data()
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        buffer.append(data)
                        guard buffer.count <= 2_097_152 else { throw AssistantError.limit }
                        while let newline = buffer.firstIndex(of: 0x0a) {
                            let frame = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                            guard frame.count <= 1_048_576 else { throw AssistantError.limit }
                            continuation.yield(frame)
                        }
                    }
                    guard buffer.isEmpty else { throw AssistantError.protocolError }; continuation.finish()
                } catch { continuation.finish(throwing: error) }
                try? handle.close()
            }
        }
    }
}

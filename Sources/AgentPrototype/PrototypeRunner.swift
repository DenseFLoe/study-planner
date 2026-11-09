import Foundation
import Darwin

struct PrototypeRunResult: Codable, Sendable {
    let provider: String
    let modelSteps: Int
    let approvedRequests: Int
    let executedTools: Int
    let externalRequests: Int
    let restrictions: [String: Bool]
    let answer: String
}

private struct BridgeFrame: Decodable {
    let type: String
    let id: String?
    let provider: String?
    let url: String?
    let method: String?
    let headers: [String: String]?
    let body: String?
    let name: String?
    let input: [String: String]?
    let text: String?
    let steps: Int?
    let restrictions: [String: Bool]?
    let node: String?
    let `protocol`: Int?
    func request() throws -> PrototypeRequest {
        guard let id, let provider, let url, let method, let headers, let body else { throw PrototypeFailure.invalidRequest }
        return .init(id: id, provider: provider, url: url, method: method, headers: headers, body: body)
    }
}

private struct BridgeReply: Encodable {
    var type = "reply"
    let id: String
    var approved: Bool? = nil
    var body: String? = nil
    var result: PrototypeEvidence? = nil
}

/// Separate from PlannerStore, repositories, sync, account stores and all live HTTP code.
@MainActor
final class PrototypeRunner {
    private var process: Process?
    private(set) var sentToSimulator = 0
    private(set) var evidence: [PrototypeEvidence] = []
    private(set) var cancelled = false

    static var bundledDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("AgentPrototype", isDirectory: true) }

    func cancel() {
        cancelled = true
        stopProcess()
    }

    private func stopProcess() {
        guard let process, process.isRunning else { return }
        process.terminate()
        // Only our disposable synthetic helper, never the application's saving process.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func run(provider: String, directory: URL,
             approve: @escaping @MainActor (PrototypeApproval) async -> Bool,
             onEvidence: @escaping @MainActor (PrototypeEvidence) -> Void = { _ in }) async throws -> PrototypeRunResult {
        guard process == nil, ["openai", "anthropic"].contains(provider) else { throw PrototypeFailure.invalidRequest }
        let helper = directory.appendingPathComponent("helper.cjs")
        let node = directory.appendingPathComponent("node")
        struct Manifest: Decodable { let syntheticOnly: Bool; let helperSHA256: String; let `protocol`: Int; let node: String }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.syntheticOnly, manifest.protocol == 1, manifest.node == "26.7.0",
              let helperData = try? Data(contentsOf: helper), helperData.count < 16_777_216,
              digest(helperData) == manifest.helperSHA256, FileManager.default.isExecutableFile(atPath: node.path) else {
            throw PrototypeFailure.missingRuntime
        }
        let fixture = try PrototypeFixture()
        var gate = PrototypeApprovalGate()
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = node
        child.arguments = ["--permission", "--allow-fs-read=\(helper.path)", helper.path]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "zh_CN.UTF-8", "NODE_NO_WARNINGS": "1"]
        child.currentDirectoryURL = directory
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        process = child
        try child.run()
        let frames = Self.frames(from: output.fileHandleForReading)
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(130)) } catch { return }
            self?.cancel()
        }
        defer {
            timeout.cancel(); stopProcess()
            try? input.fileHandleForWriting.close()
        }
        struct Start: Encodable { var type = "start"; let provider: String }
        try Self.write(Start(provider: provider), to: input.fileHandleForWriting)
        var restrictions: [String: Bool] = [:]
        var ready = false
        for try await bytes in frames {
            if cancelled || Task.isCancelled { throw CancellationError() }
            let frame = try JSONDecoder().decode(BridgeFrame.self, from: bytes)
            switch frame.type {
            case "ready":
                guard !ready, frame.protocol == 1, frame.provider == provider, frame.node == "v26.7.0",
                      let checks = frame.restrictions, checks.count == 4, checks.values.allSatisfy({ $0 }) else {
                    throw PrototypeFailure.bridge("辅助进程限制未通过，验证已停止。")
                }
                restrictions = checks; ready = true
            case "request":
                guard ready, frame.provider == provider else { throw PrototypeFailure.invalidRequest }
                let request = try frame.request()
                let approval = try gate.prepare(request, snapshotID: fixture.snapshotID)
                let allow = await approve(approval)
                if cancelled || Task.isCancelled { throw CancellationError() }
                guard try gate.decide(approval, request: request, snapshotID: fixture.snapshotID, allow: allow) else {
                    // Refusal stops the whole run. No rejection message is sent to an external model.
                    throw PrototypeFailure.bridge("你已拒绝发送；本轮验证已停止。")
                }
                sentToSimulator += 1
                let response = try fixture.response(provider: provider, step: sentToSimulator)
                try Self.write(BridgeReply(id: request.id, approved: true, body: response), to: input.fileHandleForWriting)
            case "tool":
                guard ready, let id = frame.id, let name = frame.name, let arguments = frame.input,
                      evidence.count < 2, sentToSimulator == evidence.count + 1,
                      name == (evidence.isEmpty ? "query_schedule" : "diagnose_conflict") else {
                    throw PrototypeFailure.invalidRequest
                }
                let result = try fixture.query(name: name, input: arguments)
                evidence.append(result); onEvidence(result)
                try Self.write(BridgeReply(id: id, result: result), to: input.fileHandleForWriting)
            case "done":
                guard ready, let text = frame.text, frame.steps == 3, sentToSimulator == 3 else { throw PrototypeFailure.invalidEvidence }
                try fixture.validateAnswer(text, evidence: evidence)
                return .init(provider: provider, modelSteps: 3, approvedRequests: gate.accepted,
                    executedTools: evidence.count, externalRequests: 0, restrictions: restrictions, answer: text)
            default: throw PrototypeFailure.bridge("本机辅助程序提前结束或返回无效协议；未使用真实 API。")
            }
        }
        throw PrototypeFailure.bridge("本机辅助程序退出，验证未完成。")
    }

    private static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        var bytes = try wireData(value); bytes.append(0x0a)
        try handle.write(contentsOf: bytes)
    }

    nonisolated private static func frames(from handle: FileHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var buffer = Data()
                    while true {
                        // read(upToCount:) may wait to fill its count on Foundation pipes.
                        // availableData delivers a short JSON frame before the peer awaits our reply.
                        let data = handle.availableData
                        if data.isEmpty { break }
                        buffer.append(data)
                        guard buffer.count <= 1_048_576 else { throw PrototypeFailure.invalidRequest }
                        while let newline = buffer.firstIndex(of: 0x0a) {
                            let frame = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                            continuation.yield(frame)
                        }
                    }
                    guard buffer.isEmpty else { throw PrototypeFailure.invalidRequest }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                try? handle.close()
            }
        }
    }
}

public enum AgentPrototypeProbe {
    /// Explicit developer entry point. It does not initialize the normal application's store.
    @MainActor public static func run() async -> Bool {
        guard let directory = PrototypeRunner.bundledDirectory else { print("Missing prototype bundle"); return false }
        do {
            for provider in ["openai", "anthropic"] {
                let runner = PrototypeRunner()
                defer { withExtendedLifetime(runner) {} }
                let result = try await runner.run(provider: provider, directory: directory, approve: { _ in true })
                print(String(decoding: try wireData(result), as: UTF8.self))
            }
            for rejectAt in [1, 2] {
                let runner = PrototypeRunner()
                var prompts = 0
                do {
                    _ = try await runner.run(provider: "openai", directory: directory, approve: { _ in
                        prompts += 1; return prompts != rejectAt
                    })
                    throw PrototypeFailure.bridge("Refusal unexpectedly completed")
                } catch {
                    guard prompts == rejectAt, runner.sentToSimulator == rejectAt - 1,
                          runner.evidence.count == rejectAt - 1 else { throw error }
                    print("Refusal at step \(rejectAt): no subsequent simulator requests or tools")
                }
            }
            let runner = PrototypeRunner()
            do {
                _ = try await runner.run(provider: "openai", directory: directory, approve: { _ in runner.cancel(); return true })
                throw PrototypeFailure.bridge("Cancellation unexpectedly completed")
            } catch {
                guard runner.cancelled, runner.sentToSimulator == 0, runner.evidence.isEmpty else { throw error }
                print("Cancellation before approval: zero simulator requests and tools")
            }
            print("SYNTHETIC_AGENT_PROBE_PASS externalRequests=0 credentialsUsed=0")
            return true
        } catch { print("SYNTHETIC_AGENT_PROBE_FAIL: \(error.localizedDescription)"); return false }
    }
}

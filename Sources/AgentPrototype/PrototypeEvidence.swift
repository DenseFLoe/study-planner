import Foundation
import CryptoKit
import StudyCore

enum PrototypeFailure: Error, LocalizedError {
    case invalidRequest, approvalExpired, approvalMismatch, missingRuntime, invalidEvidence, bridge(String)
    var errorDescription: String? {
        switch self {
        case .invalidRequest: "验证请求不符合合成数据边界，已停止。"
        case .approvalExpired: "审批已过期，请重新开始验证。"
        case .approvalMismatch: "请求或数据版本已变化，原审批不能使用。"
        case .missingRuntime: "此安装包未包含合成验证运行时，请使用 agent-prototype DMG。"
        case .invalidEvidence: "回答没有通过本机证据核验。"
        case .bridge(let reason): reason
        }
    }
}

func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func wireData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

struct PrototypeRequest: Codable, Equatable, Sendable {
    let id: String
    let provider: String
    let url: String
    let method: String
    let headers: [String: String]
    let body: String

    func validate() throws {
        let expectedPath = provider == "openai" ? "/v1/chat/completions" : "/v1/messages"
        guard ["openai", "anthropic"].contains(provider),
              url == "https://synthetic-provider.invalid" + expectedPath, method == "POST",
              !id.isEmpty, id.utf8.count < 100, body.utf8.count <= 524_288,
              let data = body.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["model"] as? String == "synthetic-chat", object["stream"] as? Bool != true,
              object["messages"] is [[String: Any]] else { throw PrototypeFailure.invalidRequest }
        // Only empty serializer placeholders may reach this synthetic-only path.
        for (key, value) in headers {
            if key.lowercased() == "authorization", !["Bearer", "Bearer "].contains(value) { throw PrototypeFailure.invalidRequest }
            if key.lowercased() == "x-api-key", !value.isEmpty { throw PrototypeFailure.invalidRequest }
            if key.lowercased() == "cookie" { throw PrototypeFailure.invalidRequest }
        }
    }

    var details: String {
        let headerLines = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        return "\(method) \(url)\n\(headerLines)\n\n\(body)"
    }
}

struct PrototypeApproval: Identifiable, Sendable {
    let id: UUID
    let request: PrototypeRequest
    let requestDigest: String
    let snapshotID: String
    let expiresAt: Date
    var summary: String {
        let contents = request.body.contains("requiredStudyMinutes")
            ? "合成问题、前面的对话，以及本机计算的学习分钟数、可用时段和排程证据"
            : "合成问题、任务说明和可查询工具的定义"
        return "将把\(contents)交给本机模拟接口，用于验证查询和解释流程。\n协议：\(request.provider)；显示的 .invalid 地址仅作协议标识，不会联网。"
    }
}

/// One-shot, short-lived approval bound to exact serialized bytes, recipient and snapshot.
/// This gate has deliberately no URLSession, Keychain or live provider implementation.
struct PrototypeApprovalGate {
    private(set) var pending: PrototypeApproval?
    private(set) var accepted = 0
    private var seen = Set<String>()

    mutating func prepare(_ request: PrototypeRequest, snapshotID: String, now: Date = Date()) throws -> PrototypeApproval {
        try request.validate()
        guard pending == nil, !seen.contains(request.id), seen.count < 4 else { throw PrototypeFailure.invalidRequest }
        seen.insert(request.id)
        let approval = PrototypeApproval(id: UUID(), request: request,
            requestDigest: digest(try wireData(request)), snapshotID: snapshotID,
            expiresAt: now.addingTimeInterval(120))
        pending = approval
        return approval
    }

    mutating func decide(_ approval: PrototypeApproval, request: PrototypeRequest,
                         snapshotID: String, allow: Bool, now: Date = Date()) throws -> Bool {
        guard let stored = pending, stored.id == approval.id else { throw PrototypeFailure.approvalMismatch }
        pending = nil // Every decision or mismatch consumes this permission.
        guard now < stored.expiresAt else { throw PrototypeFailure.approvalExpired }
        guard stored.snapshotID == snapshotID, stored.requestDigest == digest(try wireData(request)) else {
            throw PrototypeFailure.approvalMismatch
        }
        if allow { accepted += 1 }
        return allow
    }
}

struct PrototypeEvidence: Codable, Equatable, Sendable {
    let evidenceID: String
    let snapshotID: String
    let kind: String
    let status: String
    let capturedAt: String
    let timeZone: String
    let requiredStudyMinutes: Int
    let minimumRestMinutes: Int
    let availableMinutes: Int
    let unscheduledMinutes: Int
    let source: String
}

struct PrototypeFixture: Sendable {
    let snapshotID: String
    let schedule: PrototypeEvidence
    let conflict: PrototypeEvidence
    let expectedAnswer: String

    init(extraMinutes: Int = 0) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: .init(year: 2026, month: 9, day: 14, hour: 8))!
        var state = PlannerState()
        var course = Course(name: "合成课程 A", totalMinutes: 120, startDate: now, deadline: now)
        course.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        course.type = .lessonBasedRecorded
        course.manualLessons = [60, 60].enumerated().map {
            .init(id: "synthetic-lesson-\($0.offset)", name: "合成第\($0.offset + 1)节", durationMinutes: $0.element)
        }
        state.courses = [course]
        state.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: 600 + extraMinutes)]
        state.settings.availability[0].id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let snapshot = digest(try wireData(state))
        snapshotID = snapshot
        let engine = ScheduleEngine(calendar: calendar)
        state.tasks = engine.generate(state: state, now: now).tasks
        let result = engine.assessSavedPlan(state: state, now: now)
        let rest = result.conflicts.compactMap(\.restConflict).first
        let missing = result.risks.first?.unscheduledMinutes ?? 0
        func evidence(_ id: String, source: String) -> PrototypeEvidence {
            .init(evidenceID: id, snapshotID: snapshot, kind: "syntheticSavedPlan",
                  status: rest == nil ? "scheduled" : "provenRestConflict",
                  capturedAt: "2026-09-14T08:00:00+08:00", timeZone: "Asia/Shanghai",
                  requiredStudyMinutes: 120, minimumRestMinutes: rest?.minimumRestMinutes ?? 0,
                  availableMinutes: 120 + extraMinutes, unscheduledMinutes: missing, source: source)
        }
        schedule = evidence("E1", source: "ScheduleEngine.assessSavedPlan")
        conflict = evidence("E2", source: "ScheduleRestConflict")
        expectedAnswer = "[E1][E2] 合成课程需要 120 分钟学习，现有窗口为 120 分钟，课间至少还需 15 分钟休息，所以不能同时容纳。当前未排入 60 分钟不等于客观缺少 60 分钟。"
    }

    func query(name: String, input: [String: String]) throws -> PrototypeEvidence {
        guard input == ["date": "2026-09-14"] else { throw PrototypeFailure.invalidRequest }
        switch name {
        case "query_schedule": return schedule
        case "diagnose_conflict": return conflict
        default: throw PrototypeFailure.invalidRequest
        }
    }

    func validateAnswer(_ text: String, evidence: [PrototypeEvidence]) throws {
        // A deterministic fixture assertion, not a general semantic/hallucination validator.
        guard text == expectedAnswer, evidence.map(\.evidenceID) == ["E1", "E2"],
              evidence.allSatisfy({ $0.snapshotID == snapshotID }),
              conflict.minimumRestMinutes == 15, conflict.unscheduledMinutes == 60 else {
            throw PrototypeFailure.invalidEvidence
        }
    }

    func response(provider: String, step: Int) throws -> String {
        guard (1...3).contains(step) else { throw PrototypeFailure.invalidRequest }
        let name = step == 1 ? "query_schedule" : "diagnose_conflict"
        let answer: [String: Any]
        if provider == "openai" {
            let message: [String: Any] = step < 3
                ? ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call-\(step)", "type": "function",
                    "function": ["name": name, "arguments": "{\"date\":\"2026-09-14\"}"]]]]
                : ["role": "assistant", "content": expectedAnswer]
            answer = ["id": "synthetic-\(step)", "object": "chat.completion", "created": 0,
                      "model": "synthetic-chat", "choices": [["index": 0, "message": message,
                        "finish_reason": step < 3 ? "tool_calls" : "stop"]],
                      "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]]
        } else {
            let content: [[String: Any]] = step < 3
                ? [["type": "tool_use", "id": "call-\(step)", "name": name, "input": ["date": "2026-09-14"]]]
                : [["type": "text", "text": expectedAnswer]]
            answer = ["id": "synthetic-\(step)", "type": "message", "role": "assistant", "model": "synthetic-chat",
                      "content": content, "stop_reason": step < 3 ? "tool_use" : "end_turn", "stop_sequence": NSNull(),
                      "usage": ["input_tokens": 0, "output_tokens": 0]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]), as: UTF8.self)
    }
}

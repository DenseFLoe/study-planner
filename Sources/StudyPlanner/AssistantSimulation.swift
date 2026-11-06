import Foundation
import AppKit
import StudyCore

/// Fixed synthetic responses exercise SDK-selected tool calls, not real-model reasoning.
/// This transport has no networking, keychain or planner repository dependency.
actor AssistantMockTransport: AssistantTransport {
    nonisolated let simulated = true
    private(set) var requests: [AssistantRequest] = []
    let script: [(String, [String: String])]
    let delay: Duration
    let failAt: Int?
    init(script: [(String, [String: String])] = AssistantSimulation.script, delay: Duration = .zero, failAt: Int? = nil) {
        self.script = script; self.delay = delay; self.failAt = failAt
    }
    func send(_ request: AssistantRequest, key: String) async throws -> String {
        guard key.isEmpty, URL(string: request.url)?.host == "assistant-simulator.invalid" else { throw AssistantError.protocolError }
        requests.append(request)
        if delay != .zero { try await Task.sleep(for: delay) }
        if requests.count == failAt { throw AssistantError.network }
        let step = requests.count, tool = step <= script.count ? script[step - 1] : nil
        let text = "[E1][E2] 合成演示完成：已查询本机课程与证据。此回答用于检查界面和审批流程，不代表真实模型的推理能力。"
        let response: [String: Any]
        if request.configuration.provider == .anthropic {
            let content: [[String: Any]] = tool.map { [["type": "tool_use", "id": "call-\(step)", "name": $0.0, "input": $0.1]] }
                ?? [["type": "text", "text": text]]
            response = ["id": "mock-\(step)", "type": "message", "role": "assistant", "model": request.configuration.model,
                "content": content, "stop_reason": tool == nil ? "end_turn" : "tool_use", "stop_sequence": NSNull(),
                "usage": ["input_tokens": 0, "output_tokens": 0]]
        } else {
            var message: [String: Any] = ["role": "assistant", "content": tool == nil ? text as Any : NSNull()]
            if let tool {
                let arguments = String(decoding: try assistantJSON(tool.1), as: UTF8.self)
                message["tool_calls"] = [["id": "call-\(step)", "type": "function", "function": ["name": tool.0, "arguments": arguments]]]
            }
            response = ["id": "mock-\(step)", "object": "chat.completion", "created": 0, "model": request.configuration.model,
                "choices": [["index": 0, "message": message, "finish_reason": tool == nil ? "stop" : "tool_calls"]],
                "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]), as: UTF8.self)
    }
}

enum AssistantSimulation {
    static let courseID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let script: [(String, [String: String])] = [
        ("list_courses", ["offset": "0"]),
        ("inspect_course", ["course": courseID.uuidString, "offset": "0"]),
        ("inspect_schedule", ["date": "2026-09-14", "offset": "0"]),
        ("inspect_progress", ["start_date": "2026-09-14", "end_date": "2026-09-14", "course": ""]),
        ("inspect_rules", [:]), ("inspect_conflicts", ["offset": "0"])
    ]
    static func snapshot() -> AssistantSnapshot {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: .init(year: 2026, month: 9, day: 14, hour: 8))!
        var state = PlannerState()
        var course = Course(name: "合成课程 A", totalMinutes: 120, startDate: now, deadline: now)
        course.id = courseID; course.type = .lessonBasedRecorded
        course.manualLessons = [60, 60].enumerated().map { .init(id: "demo-\($0.offset)", name: "合成课节\($0.offset + 1)", durationMinutes: $0.element) }
        state.courses = [course]
        state.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: 600)]
        state.settings.availability[0].id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        state.tasks = ScheduleEngine(calendar: calendar).generate(state: state, now: now).tasks
        return .init(state: state, now: now, calendar: calendar)
    }
    static func configuration(provider: AssistantProvider = .openai) -> AssistantConfiguration {
        .init(provider: provider, baseURL: "https://assistant-simulator.invalid/v1", model: "synthetic-chat")
    }
    @MainActor static func session(history: AssistantHistoryStore? = nil, directory: URL? = AssistantRunner.bundledDirectory) -> AssistantSession {
        let snapshot = snapshot()
        let session = AssistantSession(historyStore: history, directory: directory, simulated: true,
                                       snapshot: { snapshot }, transportFactory: { AssistantMockTransport() })
        session.configuration = configuration()
        session.question = "我的课程和课表是什么情况？请核对进度、规则及冲突。"
        return session
    }
    @MainActor static func preview() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = AssistantWindowController()
        controller.show(session: session())
        // Keep the same controller/session alive for closing/reopening via the menu.
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        menu.addItem(appItem); appItem.submenu = appMenu
        let reopen = NSMenuItem(title: "重新打开助手", action: #selector(AssistantPreviewActions.reopen), keyEquivalent: "j")
        let actions = AssistantPreviewActions(controller: controller)
        reopen.target = actions; appMenu.addItem(reopen)
        appMenu.addItem(NSMenuItem(title: "退出模拟助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        app.mainMenu = menu
        withExtendedLifetime(actions) { app.run() }
    }
    @MainActor static func probe() async -> Bool {
        guard let directory = AssistantRunner.bundledDirectory else { return false }
        do {
            let snapshot = snapshot()
            var checkState = snapshot.state
            let first = ScheduledTask(courseID: courseID, start: snapshot.now, durationMinutes: 120)
            let overlap = ScheduledTask(courseID: courseID, start: snapshot.now.addingTimeInterval(3600), durationMinutes: 60)
            var completed = first; completed.id = UUID(); completed.status = .completed
            var floating = first; floating.id = UUID(); floating.durationMinutes = 30
            floating.floatingWindowStart = snapshot.now; floating.floatingWindowEnd = snapshot.now.addingTimeInterval(4 * 3600)
            checkState.tasks = [first, overlap, completed, floating]
            let checked = try AssistantTimeCheck.inspect(snapshot: .init(state: checkState, now: snapshot.now, calendar: snapshot.calendar),
                day: snapshot.calendar.startOfDay(for: snapshot.now), offset: 0)
            guard checked["fixed_overlap_count"] as? Int == 1, checked["excluded_confirmed_task_count"] as? Int == 1,
                  checked["floating_window_count"] as? Int == 1 else { return false }
            for provider in [AssistantProvider.openai, .anthropic, .deepseek] {
                let runner = AssistantRunner(), transport = AssistantMockTransport()
                var approvals: [AssistantApproval] = [], evidence: [AssistantToolEvidence] = []
                _ = try await runner.run(configuration: configuration(provider: provider),
                    messages: [.init(role: "user", content: "合成查询")], snapshot: snapshot, key: "", directory: directory,
                    transport: transport, currentSnapshotID: { snapshot.id }, approve: { approval in
                        approvals.append(approval)
                        guard approvals.count == 1 || !approval.request.categories.isEmpty else { throw AssistantError.protocolError }
                        return true
                    }, activity: { _ in }, evidence: { evidence.append($0) })
                guard approvals.count == 7, evidence.count == 6, runner.toolCount == 6, runner.sentRequests == 7,
                      let summary = approvals.last?.summary,
                      summary.contains("课程/课节名称"), summary.contains("日期时间"),
                      summary.contains("冲突及余量"), summary.contains("相关编号") else { return false }
                let captured = await transport.requests
                guard let last = captured.last,
                      AssistantDetailNode.parse(last.body).map(\.plainText).joined().contains("本机时间核对") else { return false }
                guard captured == approvals.map(\.request),
                      let course = try JSONSerialization.jsonObject(with: Data(evidence[1].json.utf8)) as? [String: Any],
                      let courseData = course["data"] as? [String: Any], let lessons = courseData["lessons"] as? [[String: Any]],
                      let schedule = try JSONSerialization.jsonObject(with: Data(evidence[2].json.utf8)) as? [String: Any],
                      let scheduleData = schedule["data"] as? [String: Any], let rows = scheduleData["rows"] as? [[String: Any]],
                      let task = rows.first, let reference = task["lesson_id"] as? String,
                      task["lesson_match"] as? String == "matched", task["untrusted_lesson_name"] as? String == "合成课节1",
                      lessons.first?["lesson_id"] as? String == reference, lessons.first?["position"] as? Int == 1 else { return false }
            }
            print("ASSISTANT_PACKAGE_PROBE_PASS protocols=3 queries=18 externalRequests=0 credentialsUsed=0 privacy=verified lessonLinks=verified timeCheck=verified readableDetails=verified")
            return true
        } catch { print("ASSISTANT_PACKAGE_PROBE_FAIL: \(AssistantError.safe(error).rawValue)"); return false }
    }
}
@MainActor private final class AssistantPreviewActions: NSObject {
    let controller: AssistantWindowController
    init(controller: AssistantWindowController) { self.controller = controller }
    @objc func reopen() { if let session = controller.session { controller.show(session: session) } }
}

import AppKit

/// Opt-in packaged-app acceptance: real AppKit windows, temporary history, no network or vault.
@MainActor enum AssistantWindowProbe {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { exit(await check() ? 0 : 2) }
        app.run()
    }
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AssistantError.protocolError }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func check() async -> Bool {
        let controller = AssistantWindowController()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("assistant-window-probe-" + UUID().uuidString)
        defer { controller.window?.close(); try? FileManager.default.removeItem(at: root) }
        do {
            let store = AssistantHistoryStore(url: root.appendingPathComponent("workspace.json"))
            let selected = AssistantConversation()
            let archive = (0..<8).map { _ in
                AssistantConversation(entries: (0..<10).map { _ in
                    .init(role: "助手", text: String(repeating: "合成的窗口验收记录。", count: 20), status: "完成")
                })
            }
            try await Task.detached {
                try store.save(.init(configuration: AssistantSimulation.configuration(), conversations: [selected] + archive, selectedID: selected.id))
            }.value
            let snapshot = AssistantSimulation.snapshot()
            let slow = AssistantMockTransport(script: [], delay: .seconds(30))
            let fast = AssistantMockTransport(script: [])
            var useFast = false
            let session = AssistantSession(historyStore: store, simulated: true, snapshot: { snapshot },
                                           transportFactory: { useFast ? fast : slow })
            // Close before the asynchronous read completes, then reopen the same session.
            controller.show(session: session); controller.window?.performClose(nil)
            await session.waitUntilReady()
            guard session.selectedID == selected.id else { throw AssistantError.history }
            var longest = Duration.zero
            for _ in 0..<12 {
                let start = ContinuousClock.now
                controller.show(session: session)
                guard controller.window?.isVisible == true, controller.session === session else { throw AssistantError.protocolError }
                try await Task.sleep(for: .milliseconds(20))
                controller.window?.performClose(nil)
                longest = max(longest, start.duration(to: .now))
                guard controller.window == nil else { throw AssistantError.protocolError }
            }
            // Cancellation before approval, while awaiting approval, and during transport.
            controller.show(session: session)
            session.question = "准备中关闭"; session.send(); controller.window?.performClose(nil)
            controller.show(session: session)
            session.question = "确认时关闭"; session.send()
            try await waitUntil { session.approval != nil || !session.busy }
            guard let approval = session.approval else { throw AssistantError.protocolError }
            controller.window?.performClose(nil); session.decide(approval.id, allow: true)
            guard await slow.requests.isEmpty else { throw AssistantError.protocolError }
            controller.show(session: session)
            session.question = "请求中关闭"; session.send()
            try await waitUntil { session.approval != nil || !session.busy }
            guard let approval = session.approval else { throw AssistantError.protocolError }
            session.decide(approval.id, allow: true)
            try await waitUntil { await slow.requests.count == 1 }
            let closing = ContinuousClock.now
            controller.window?.performClose(nil)
            longest = max(longest, closing.duration(to: .now))
            guard !session.busy, session.approval == nil, session.key.isEmpty else { throw AssistantError.protocolError }
            // The reopened window must be usable immediately while old cleanup/save completes.
            useFast = true; controller.show(session: session); session.newConversation()
            let latest = session.selectedID
            session.question = "重新打开后查询"; session.send()
            try await waitUntil {
                if let approval = session.approval { session.decide(approval.id, allow: true) }
                return !session.busy
            }
            guard session.entries.filter({ $0.role == "助手" }).count == 1 else { throw AssistantError.protocolError }
            controller.window?.performClose(nil)
            guard await session.prepareToQuit() else { throw AssistantError.history }
            let saved = try await Task.detached { try store.load() }.value
            guard saved.selectedID == latest, saved.conversations.count == 10,
                  !saved.conversations.flatMap(\.entries).contains(where: { $0.status == "处理中" }),
                  longest < .seconds(1) else { throw AssistantError.protocolError }
            print("ASSISTANT_WINDOW_PROBE_PASS cycles=12 closeDuringLoad=1 cancellationPhases=3 reopenAndSend=1 externalRequests=0 credentialsUsed=0 maxCycle=\(longest)")
            return true
        } catch {
            print("ASSISTANT_WINDOW_PROBE_FAIL: \(AssistantError.safe(error).rawValue)")
            return false
        }
    }
}

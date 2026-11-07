import XCTest
import StudyCore
@testable import StudyPlanner

final class AssistantTests: XCTestCase {
    private func request(id: String = "r1", body: String? = nil, config: AssistantConfiguration = AssistantSimulation.configuration()) throws -> AssistantRequest {
        .init(id: id, configuration: config, url: try config.endpoint().absoluteString,
              body: body ?? "{\"model\":\"synthetic-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"合成问题\"}]}")
    }
    private func history() throws -> AssistantHistoryStore {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("assistant-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return .init(url: directory.appendingPathComponent("workspace.json"))
    }
    private func payload(_ evidence: AssistantToolEvidence) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(evidence.json.utf8)) as? [String: Any])
        return try XCTUnwrap(object["data"] as? [String: Any])
    }
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out", file: file, line: line); throw AssistantError.protocolError
    }
    @MainActor private func session(_ transport: AssistantMockTransport? = nil,
                                   history: AssistantHistoryStore? = nil,
                                   snapshot: AssistantSnapshot = AssistantSimulation.snapshot()) async throws -> AssistantSession {
        let value = AssistantSession(historyStore: history, simulated: true, snapshot: { snapshot },
            transportFactory: { transport ?? AssistantMockTransport(script: Array(AssistantSimulation.script.prefix(2))) })
        await value.waitUntilReady()
        value.configuration = AssistantSimulation.configuration(); value.question = "合成问题"; return value
    }
    @MainActor private func complete(_ session: AssistantSession) async throws {
        while session.busy {
            try await waitUntil { session.approval != nil || !session.busy }
            if let approval = session.approval { session.decide(approval.id, allow: true) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testExactApprovalExpiryRefusalReplayAndChange() throws {
        let request = try request(), now = Date(timeIntervalSince1970: 100)
        for mode in ["approve", "reject", "expire", "body", "recipient", "snapshot"] {
            var gate = AssistantApprovalGate()
            let approval = try gate.prepare(request, snapshotID: "s1", simulated: true, now: now)
            var changed = request
            if mode == "body" { changed = try self.request(body: request.body + " ") }
            if mode == "recipient" {
                var config = request.configuration; config.baseURL = "https://other.invalid/v1"; changed = try self.request(config: config)
            }
            if ["approve", "reject"].contains(mode) {
                XCTAssertEqual(try gate.decide(id: approval.id, request: changed, snapshotID: "s1", allow: mode == "approve", now: now), mode == "approve")
            } else {
                XCTAssertThrowsError(try gate.decide(id: approval.id, request: changed, snapshotID: mode == "snapshot" ? "s2" : "s1", allow: true, now: mode == "expire" ? now.addingTimeInterval(120) : now))
            }
            XCTAssertNil(gate.pending)
            XCTAssertThrowsError(try gate.decide(id: approval.id, request: request, snapshotID: "s1", allow: true, now: now))
            XCTAssertThrowsError(try gate.prepare(request, snapshotID: "s1", simulated: true, now: now))
        }
    }
    func testBodyCategoriesAreParsedFromActualToolBlocks() throws {
        let body = "{\"model\":\"synthetic-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"category:假类别\"},{\"role\":\"tool\",\"content\":\"{\\\"category\\\":\\\"课程名称\\\"}\"}]}"
        let value = try request(body: body)
        XCTAssertEqual(value.categories, ["课程名称"])
        XCTAssertTrue(value.details.hasSuffix(body))
        XCTAssertFalse(value.details.contains("Bearer test"))
    }
    func testEndpointAndSecretGuards() throws {
        for url in ["http://example.com/v1", "https://u:p@example.com/v1", "https://example.com/v1?token=x", "https://example.com/v1#x"] {
            var config = AssistantSimulation.configuration(); config.baseURL = url
            XCTAssertThrowsError(try config.endpoint())
        }
        XCTAssertThrowsError(try AssistantSecrets.check("sk-syntheticabcdefgh"))
        XCTAssertThrowsError(try AssistantSecrets.check("prefix fake-credential suffix", key: "fake-credential"))
        XCTAssertThrowsError(try request(body: "{\"model\":\"wrong\",\"messages\":[]}").validate())
    }
    func testAllToolsUseSnapshotAndKeepDataReadOnly() throws {
        let snapshot = AssistantSimulation.snapshot(), original = try assistantJSON(snapshot.state)
        let results = try AssistantSimulation.script.enumerated().map { try AssistantTools.execute(name: $0.element.0, input: $0.element.1, snapshot: snapshot, id: "E\($0.offset + 1)") }
        XCTAssertEqual(results.count, 6)
        XCTAssertTrue(results[1].json.contains("\"remaining_minutes\":120"))
        XCTAssertTrue(results[4].json.contains("\"break_minutes\":15"))
        XCTAssertTrue(results[5].json.contains("\"minimum_rest_minutes\":15"))
        XCTAssertTrue(results[5].json.contains("\"unscheduled_minutes\":60"))
        XCTAssertTrue(results[5].json.contains("\"proven_capacity_deficit\":null"))
        XCTAssertEqual(try assistantJSON(snapshot.state), original)
        for name in ["write_file", "replan", "preview_schedule_change", "read_file"] {
            XCTAssertThrowsError(try AssistantTools.execute(name: name, input: [:], snapshot: snapshot, id: "E1"))
        }
        XCTAssertThrowsError(try AssistantTools.execute(name: "list_courses", input: ["offset": "0", "path": "/tmp"], snapshot: snapshot, id: "E1"))
        XCTAssertThrowsError(try AssistantTools.execute(name: "inspect_schedule", input: ["date": "2026-02-30", "offset": "0"], snapshot: snapshot, id: "E1"))
    }
    func testToolPrivacyPaginationAndMissingData() throws {
        let basis = AssistantSimulation.snapshot()
        var state = basis.state
        state.courses[0].notes = "private-note-must-not-leak"
        for i in 0..<25 { state.courses.append(Course(name: "课程\(i)", totalMinutes: 20, startDate: basis.now, deadline: basis.now)) }
        let snapshot = AssistantSnapshot(state: state, now: basis.now, calendar: basis.calendar)
        let first = try AssistantTools.execute(name: "list_courses", input: ["offset": "0"], snapshot: snapshot, id: "E1")
        XCTAssertTrue(first.json.contains("\"next_offset\":\"20\""))
        for item in AssistantSimulation.script {
            XCTAssertFalse(try AssistantTools.execute(name: item.0, input: item.1, snapshot: snapshot, id: "E1").json.contains("private-note"))
        }
        let empty = AssistantSnapshot(state: PlannerState(), now: basis.now)
        XCTAssertTrue(try AssistantTools.execute(name: "list_courses", input: ["offset": "0"], snapshot: empty, id: "E1").json.contains("\"total\":0"))
    }
    func testScheduleIdentifiesSavedLessonAndMatchesCourseDespiteReorderingOrRename() throws {
        let basis = AssistantSimulation.snapshot()
        var state = basis.state
        // Equal durations and duplicate names cannot be used to infer identity.
        state.courses[0].manualLessons![0].name = "同名课节"
        state.courses[0].manualLessons![1].name = "同名课节"
        state.courses[0].lessonOrder = ["demo-1", "demo-0"]
        let taskID = try XCTUnwrap(state.tasks.first?.id)
        var rows: [[String: Any]] = []
        for (id, position) in [("demo-0", 2), ("demo-1", 1)] {
            state.tasks[0].lessonID = id
            state.tasks[0].lessonName = "排课时的名称"
            let snapshot = AssistantSnapshot(state: state, now: basis.now, calendar: basis.calendar)
            let original = try assistantJSON(snapshot.state)
            let schedule = try payload(AssistantTools.execute(name: "inspect_schedule", input: ["date": "2026-09-14", "offset": "0"], snapshot: snapshot, id: "E1"))
            let row = try XCTUnwrap((schedule["rows"] as? [[String: Any]])?.first)
            let course = try payload(AssistantTools.execute(name: "inspect_course", input: ["course": AssistantSimulation.courseID.uuidString, "offset": "0"], snapshot: snapshot, id: "E2"))
            let reference = try XCTUnwrap(row["lesson_id"] as? String)
            let lesson = try XCTUnwrap((course["lessons"] as? [[String: Any]])?.first { $0["lesson_id"] as? String == reference })
            XCTAssertEqual(row["task_id"] as? String, taskID.uuidString)
            XCTAssertEqual(row["lesson_match"] as? String, "matched")
            XCTAssertEqual(row["untrusted_lesson_name"] as? String, "排课时的名称")
            XCTAssertEqual(lesson["position"] as? Int, position)
            XCTAssertEqual(lesson["untrusted_name"] as? String, "同名课节")
            XCTAssertEqual(try assistantJSON(snapshot.state), original)
            rows.append(row)
        }
        XCTAssertNotEqual(rows[0]["lesson_id"] as? String, rows[1]["lesson_id"] as? String)
        XCTAssertEqual(rows[0]["start"] as? String, rows[1]["start"] as? String)
    }
    func testScheduleMissingLessonFactsAreExplicitAndNamesNeverResolveIdentity() throws {
        let basis = AssistantSimulation.snapshot()
        let cases: [(String?, String?, String)] = [(nil, nil, "not_recorded"), (nil, "合成课节1", "not_recorded"),
                                                 ("", "合成课节1", "not_recorded"), ("removed", "合成课节1", "not_found"),
                                                 ("demo-0", nil, "matched")]
        for (id, name, expected) in cases {
            var state = basis.state
            state.tasks[0].lessonID = id; state.tasks[0].lessonName = name
            let snapshot = AssistantSnapshot(state: state, now: basis.now, calendar: basis.calendar)
            let result = try payload(AssistantTools.execute(name: "inspect_schedule", input: ["date": "2026-09-14", "offset": "0"], snapshot: snapshot, id: "E1"))
            let row = try XCTUnwrap((result["rows"] as? [[String: Any]])?.first)
            XCTAssertEqual(row["lesson_match"] as? String, expected)
            XCTAssertEqual(row["lesson_id"] is NSNull, id == nil || id == "")
            XCTAssertEqual(row["untrusted_lesson_name"] is NSNull, name == nil)
            XCTAssertEqual(row["untrusted_lesson_name"] as? String, name)
            XCTAssertTrue((result["note"] as? String)?.contains("不按名称或顺序猜测") == true)
        }
    }
    func testLessonReferencesAreStableAcrossPagesAndHideSourceIdentifiers() throws {
        let basis = AssistantSimulation.snapshot()
        var state = basis.state
        state.courses[0].totalMinutes = 25 * 60
        state.courses[0].manualLessons = (0..<25).map {
            .init(id: "quark:synthetic-private-share-id:file-\($0)", name: "课节\($0 + 1)", durationMinutes: 60)
        }
        state.tasks[0].lessonID = state.courses[0].manualLessons![20].id
        state.tasks[0].lessonName = "课节21"
        let snapshot = AssistantSnapshot(state: state, now: basis.now, calendar: basis.calendar)
        let schedule = try AssistantTools.execute(name: "inspect_schedule", input: ["date": "2026-09-14", "offset": "0"], snapshot: snapshot, id: "E1")
        let page = try AssistantTools.execute(name: "inspect_course", input: ["course": AssistantSimulation.courseID.uuidString, "offset": "20"], snapshot: snapshot, id: "E2")
        let row = try XCTUnwrap((payload(schedule)["rows"] as? [[String: Any]])?.first)
        let lesson = try XCTUnwrap((payload(page)["lessons"] as? [[String: Any]])?.first)
        let reference = try XCTUnwrap(lesson["lesson_id"] as? String)
        XCTAssertEqual(reference, row["lesson_id"] as? String)
        XCTAssertEqual(lesson["position"] as? Int, 21)
        XCTAssertEqual(reference.count, 64)
        XCTAssertFalse(page.json.contains("synthetic-private-share-id"))
        XCTAssertFalse(schedule.json.contains("synthetic-private-share-id"))
        state.courses[0].manualLessons![20].name = "修改后的名称"
        state.courses[0].lessonOrder = state.courses[0].manualLessons!.map(\.id).reversed()
        let changed = AssistantSnapshot(state: state, now: basis.now, calendar: basis.calendar)
        let first = try payload(AssistantTools.execute(name: "inspect_course", input: ["course": AssistantSimulation.courseID.uuidString, "offset": "0"], snapshot: changed, id: "E3"))
        let renamed = try XCTUnwrap((first["lessons"] as? [[String: Any]])?.first { $0["lesson_id"] as? String == reference })
        XCTAssertEqual(renamed["position"] as? Int, 5)
        XCTAssertEqual(renamed["untrusted_name"] as? String, "修改后的名称")
    }
    func testArithmeticUsesOnlyExistingNumericEvidenceAndMissingFactsAreExplicit() throws {
        let snapshot = AssistantSimulation.snapshot()
        let course = try AssistantTools.execute(name: "inspect_course", input: ["course": AssistantSimulation.courseID.uuidString, "offset": "0"], snapshot: snapshot, id: "E1")
        let calculated = try AssistantTools.execute(name: "calculate", input: ["left": "E1.data.total_minutes", "right": "E1.data.completed_minutes", "operation": "subtract"], snapshot: snapshot, id: "E2", previous: [course])
        XCTAssertTrue(calculated.json.contains("\"result\":120"))
        for path in ["120", "E9.data.total_minutes", "E1.data.auto_schedule", "E1.data.untrusted_name"] {
            XCTAssertThrowsError(try AssistantTools.execute(name: "calculate", input: ["left": path, "right": "E1.data.total_minutes", "operation": "add"], snapshot: snapshot, id: "E2", previous: [course]))
        }
        let missing = try AssistantTools.query(name: "inspect_course", input: ["course": UUID().uuidString, "offset": "0"], snapshot: snapshot, id: "E2", previous: [])
        XCTAssertTrue(missing.json.contains("没有可用事实"))
    }
    func testHistoryRoundtripMigrationAndCorruptionPreservesFile() throws {
        let store = try history()
        let conversation = AssistantConversation(entries: [.init(role: "你", text: "仅合成历史", status: "完成")])
        let workspace = AssistantWorkspace(conversations: [conversation], selectedID: conversation.id)
        try store.save(workspace)
        XCTAssertEqual(try store.load().selectedID, conversation.id)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try Data("corrupt".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "corrupt")
        let legacy = store.url.deletingLastPathComponent().appendingPathComponent("legacy.json")
        let data = try assistantJSON([conversation]); try data.write(to: legacy)
        let migrated = AssistantHistoryStore(url: store.url.deletingLastPathComponent().appendingPathComponent("new.json"), legacyURL: legacy)
        XCTAssertEqual(try migrated.load().conversations[0].entries[0].status, "旧版记录 · 仅本机查看")
        XCTAssertEqual(try Data(contentsOf: legacy), data)
    }
    func testHistoryRejectsSymlinkAndDuplicateIDs() throws {
        let store = try history(), target = store.url.deletingLastPathComponent().appendingPathComponent("target.json")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
        XCTAssertThrowsError(try store.save(AssistantWorkspace()))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
        let clean = try history(), conversation = AssistantConversation()
        XCTAssertThrowsError(try clean.save(.init(conversations: [conversation, conversation])))
    }
    @MainActor func testNativeSerializersExecuteAllSixReadOnlyToolsAfterOneScopeConfirmation() async throws {
        let snapshot = AssistantSimulation.snapshot()
        for provider in [AssistantProvider.openai, .anthropic, .deepseek] {
            let runner = AssistantRunner(), mock = AssistantMockTransport()
            var approvals: [AssistantApproval] = [], results: [AssistantToolEvidence] = []
            let answer = try await runner.run(configuration: AssistantSimulation.configuration(provider: provider),
                messages: [.init(role: "user", content: "合成问题")], snapshot: snapshot, key: "",
                transport: mock, currentSnapshotID: { snapshot.id }, approve: { approvals.append($0); return true },
                activity: { _ in }, evidence: { results.append($0) })
            XCTAssertEqual(approvals.count, 1); XCTAssertEqual(results.count, 6); XCTAssertFalse(answer.isEmpty)
            XCTAssertTrue(approvals[0].request.categories.isEmpty)
            let captured = await mock.requests
            XCTAssertEqual(captured.count, 7)
            XCTAssertEqual(captured.first, approvals.first?.request)
            XCTAssertEqual(captured.last?.categories.count, 6)
            XCTAssertFalse(captured[0].body.contains("合成课程 A"))
            XCTAssertTrue(captured[1].body.contains("合成课程 A"))
        }
    }
    @MainActor func testDirectQueryPrivacySummaryMatchesActuallyApprovedToolData() async throws {
        let basis = AssistantSimulation.snapshot()
        var state = basis.state
        state.courses[0].name = "合成普通课程名称"
        state.settings.actualStudyStart = basis.now
        let snapshot = AssistantSnapshot(state: state, now: basis.now, calendar: basis.calendar)
        let cases: [(String, [String: String], [String], [String])] = [
            ("inspect_conflicts", ["offset": "0"], ["课程/课节名称", "日期时间", "冲突及余量"], ["合成普通课程名称", "start_date", "deadline", "2026-09-14"]),
            ("inspect_schedule", ["date": "2026-09-14", "offset": "0"], ["课程/课节名称", "日期时间", "相关编号", "冲突及余量"], ["合成课节1", "lesson_id", "task_id", "2026-09-14", "fixed_overlap_count"]),
            ("inspect_course", ["course": AssistantSimulation.courseID.uuidString, "offset": "0"], ["课程/课节名称", "相关编号", "日期时间"], ["合成普通课程名称", "合成课节1", "lesson_id", "position", "start_date", "deadline"]),
            ("inspect_rules", [:], ["日期时间", "排程规则"], ["actual_study_start", "2026-09-14 08:00:00"]),
            ("inspect_time_conflicts", ["date": "2026-09-14", "offset": "0"], ["日期时间", "相关编号", "冲突及余量"], ["fixed_overlap_count", "floating_window_count", "2026-09-14"])
        ]
        for provider in [AssistantProvider.openai, .anthropic, .deepseek] {
            for (tool, input, summaryTerms, bodyTerms) in cases {
                let runner = AssistantRunner(), mock = AssistantMockTransport(script: [(tool, input)])
                var approvals: [AssistantApproval] = [], results: [AssistantToolEvidence] = []
                _ = try await runner.run(configuration: AssistantSimulation.configuration(provider: provider),
                    messages: [.init(role: "user", content: "合成单项查询")], snapshot: snapshot, key: "",
                    transport: mock, currentSnapshotID: { snapshot.id }, approve: { approvals.append($0); return true },
                    activity: { _ in }, evidence: { results.append($0) })
                XCTAssertEqual(approvals.count, 1); XCTAssertEqual(results.count, 1)
                let captured = await mock.requests
                XCTAssertEqual(captured.count, 2)
                let first = try XCTUnwrap(approvals.first)
                var detailsGate = AssistantApprovalGate()
                let outgoing = try detailsGate.prepare(XCTUnwrap(captured.last), snapshotID: snapshot.id, simulated: true, confirmsScope: false)
                XCTAssertTrue(first.request.categories.isEmpty)
                XCTAssertFalse(first.request.body.contains("合成普通课程名称"))
                XCTAssertFalse(first.request.body.contains("合成课节1"))
                XCTAssertEqual(outgoing.request.categories, [try XCTUnwrap(results.first).category])
                for term in summaryTerms { XCTAssertTrue(outgoing.summary.contains(term), "\(tool): missing summary \(term)") }
                for term in bodyTerms { XCTAssertTrue(outgoing.request.body.contains(term), "\(tool): missing actual data \(term)") }
                XCTAssertTrue(outgoing.request.details.hasSuffix(outgoing.request.body))
                let readable = AssistantDetailNode.parse(outgoing.request.body).map(\.plainText).joined(separator: "\n")
                XCTAssertTrue(readable.contains("本机查询事实"))
                XCTAssertTrue(readable.contains("本次资料类别"))
                XCTAssertTrue(readable.contains(try XCTUnwrap(results.first).category))
                if tool == "inspect_conflicts" { XCTAssertTrue(readable.contains("合成普通课程名称")); XCTAssertTrue(readable.contains("截止日期")) }
                if tool == "inspect_schedule" { XCTAssertTrue(readable.contains("合成课节1")); XCTAssertTrue(readable.contains("本机时间核对")) }
                XCTAssertEqual(captured.first, first.request)
            }
        }
    }
    @MainActor func testRefusingInitialScopeNeverQueriesOrTransmitsPrivateCourse() async throws {
        let basis = AssistantSimulation.snapshot()
        var state = basis.state; state.courses[0].name = "合成私密课程"
        let snapshot = AssistantSnapshot(state: state, now: basis.now, calendar: basis.calendar)
        let mock = AssistantMockTransport(), session = try await session(mock, snapshot: snapshot)
        session.send(); try await waitUntil { session.approval != nil }
        XCTAssertEqual(session.approval?.title, "课表内容确认")
        XCTAssertTrue(session.evidence.isEmpty)
        session.decide(session.approval!.id, allow: false)
        try await waitUntil { !session.busy }
        let requests = await mock.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(session.entries.contains { $0.role == "助手" })
    }
    @MainActor func testNativeCalculationUsesNativeEvidenceWithinConfirmedScope() async throws {
        let snapshot = AssistantSimulation.snapshot(), runner = AssistantRunner()
        let mock = AssistantMockTransport(script: [
            ("inspect_course", ["course": AssistantSimulation.courseID.uuidString, "offset": "0"]),
            ("calculate", ["left": "E1.data.total_minutes", "right": "E1.data.completed_minutes", "operation": "subtract"])
        ])
        var approvals: [AssistantApproval] = []
        _ = try await runner.run(configuration: AssistantSimulation.configuration(), messages: [.init(role: "user", content: "合成计算")],
            snapshot: snapshot, key: "", transport: mock, currentSnapshotID: { snapshot.id },
            approve: { approvals.append($0); return true }, activity: { _ in }, evidence: { _ in })
        XCTAssertEqual(approvals.count, 1)
        let captured = await mock.requests
        XCTAssertEqual(captured.count, 3)
        XCTAssertTrue(captured[2].categories.contains("软件核算的数值与计算依据"))
        XCTAssertTrue(captured[2].body.contains("result"))
    }
    @MainActor func testRefuseRetryAndDuplicateDecisions() async throws {
        let session = try await session()
        session.send(); try await waitUntil { session.approval != nil }
        let old = session.approval!.id
        session.decide(old, allow: false); session.decide(old, allow: true)
        try await waitUntil { !session.busy }
        session.retry(); try await waitUntil { session.approval != nil }
        let next = session.approval!.id; XCTAssertNotEqual(next, old)
        session.decide(old, allow: true); XCTAssertEqual(session.approval?.id, next)
        try await complete(session)
        XCTAssertEqual(session.entries.filter { $0.role == "助手" }.count, 1)
        XCTAssertEqual(session.entries.filter { $0.role == "你" && $0.status == "完成" }.count, 1)
    }
    @MainActor func testQuestionRecipientModelAndKeyChangesInvalidatePendingApproval() async throws {
        for kind in ["question", "recipient", "model", "key"] {
            let mock = AssistantMockTransport(), session = try await session(mock)
            session.send(); try await waitUntil { session.approval != nil }
            let id = session.approval!.id
            switch kind {
            case "question": session.question = "变化后的问题"
            case "recipient": session.configuration.baseURL = "https://changed.invalid/v1"
            case "model": session.configuration.model = "different-model"
            default: session.key = "synthetic-value"
            }
            session.decide(id, allow: true)
            XCTAssertNil(session.approval); XCTAssertFalse(session.busy)
            let requests = await mock.requests; XCTAssertTrue(requests.isEmpty)
        }
    }
    @MainActor func testSnapshotChangesBeforeApprovalAutomaticallyRequeriesLatestData() async throws {
        var snapshot = AssistantSimulation.snapshot()
        let mock = AssistantMockTransport()
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { snapshot }, transportFactory: { mock })
        session.configuration = AssistantSimulation.configuration(); session.question = "合成"; session.send()
        try await waitUntil { session.approval != nil }
        var state = snapshot.state; state.courses[0].name = "已变化"
        snapshot = .init(state: state, now: snapshot.now, calendar: snapshot.calendar)
        session.decide(session.approval!.id, allow: true)
        try await waitUntil { !session.busy }
        let requests = await mock.requests
        XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(requests.last?.body.contains("已变化") == true)
        XCTAssertNil(session.message)
        XCTAssertEqual(session.entries.filter { $0.role == "你" }.count, 1)
        XCTAssertEqual(session.entries.filter { $0.role == "助手" }.count, 1)
        XCTAssertTrue(session.entries.first?.steps?.contains("课表已更新，正在重新查询…") == true)
        XCTAssertFalse(session.entries.contains { $0.role == "本机证据" || $0.text.contains("[E1]") })
    }
    @MainActor func testSwitchAndCloseCancelPendingApprovalsAndPreserveHistory() async throws {
        let store = try history(), mock = AssistantMockTransport(), session = try await session(mock, history: store)
        let original = session.selectedID
        session.send(); try await waitUntil { session.approval != nil }
        let id = session.approval!.id
        session.newConversation(); session.decide(id, allow: true)
        XCTAssertFalse(session.busy); XCTAssertNotEqual(original, session.selectedID)
        session.select(original); XCTAssertEqual(session.entries.first?.text, "合成问题")
        session.retry(); try await waitUntil { session.approval != nil }
        session.close(); XCTAssertNil(session.approval); XCTAssertEqual(session.key, "")
        let flushed = await session.prepareToQuit()
        XCTAssertTrue(flushed)
        let reopened = try await self.session(history: store)
        XCTAssertEqual(reopened.selectedID, original)
        XCTAssertEqual(reopened.conversations.count, 2)
        XCTAssertTrue(reopened.entries.allSatisfy { $0.status != "处理中" })
        let requests = await mock.requests; XCTAssertTrue(requests.isEmpty)
    }
    private actor UpdatingTransport: AssistantTransport {
        nonisolated let simulated = true
        let mock = AssistantMockTransport(script: [("list_courses", ["offset": "0"])])
        let update: @MainActor () -> Void
        init(update: @escaping @MainActor () -> Void) { self.update = update }
        func send(_ request: AssistantRequest, key: String) async throws -> String {
            let response = try await mock.send(request, key: key)
            if await mock.requests.count == 2 { await update() }
            return response
        }
    }
    @MainActor func testChangeDuringResponseDiscardsOldEvidenceAndPersistsProcessWithoutRepeatingApproval() async throws {
        let store = try history()
        var snapshot = AssistantSimulation.snapshot()
        let updating = UpdatingTransport {
            var state = snapshot.state; state.courses[0].name = "合成最新课程"
            snapshot = .init(state: state, now: snapshot.now, calendar: snapshot.calendar)
        }
        let final = AssistantMockTransport(script: [("list_courses", ["offset": "0"])])
        var attempts = 0
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { snapshot }, transportFactory: {
            attempts += 1
            return attempts == 1 ? updating : final
        })
        await session.waitUntilReady()
        session.configuration = AssistantSimulation.configuration(); session.question = "查看课程进度"; session.send()
        try await waitUntil { session.approval != nil }
        session.decide(try XCTUnwrap(session.approval).id, allow: true)
        try await waitUntil { !session.busy }
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(session.message)
        XCTAssertEqual(session.evidence.count, 1)
        XCTAssertTrue(session.evidence[0].json.contains("合成最新课程"))
        let requests = await final.requests
        XCTAssertFalse(requests[0].body.contains("合成课程 A"))
        XCTAssertTrue(requests[1].body.contains("合成最新课程"))
        XCTAssertEqual(session.entries.filter { $0.role == "你" }.count, 1)
        XCTAssertEqual(session.entries.filter { $0.role == "助手" }.count, 1)
        XCTAssertTrue(session.entries.first?.steps?.contains("课表已更新，正在重新查询…") == true)
        let saved = try store.load()
        XCTAssertEqual(saved.conversations[0].entries[0].steps, session.entries[0].steps)
        XCTAssertFalse(saved.conversations[0].entries.contains { $0.role == "本机证据" })
    }
    @MainActor func testRepeatedScheduleChangesAreBoundedAndNeverPublishStaleAnswer() async throws {
        var snapshot = AssistantSimulation.snapshot(), attempts = 0
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { snapshot }, transportFactory: {
            attempts += 1
            return UpdatingTransport {
                snapshot = .init(state: snapshot.state, now: snapshot.now, calendar: snapshot.calendar, id: UUID().uuidString)
            }
        })
        session.configuration = AssistantSimulation.configuration(); session.question = "合成连续变化"; session.send()
        try await waitUntil { session.approval != nil }
        session.decide(try XCTUnwrap(session.approval).id, allow: true)
        try await waitUntil { !session.busy }
        XCTAssertEqual(attempts, 4)
        XCTAssertTrue(session.evidence.isEmpty)
        XCTAssertNil(session.pendingChange)
        XCTAssertFalse(session.entries.contains { $0.role == "助手" })
        XCTAssertEqual(session.message, AssistantError.snapshotChanged.rawValue)
    }
    @MainActor func testLegacyEvidenceIsHiddenAndAnswerReferencesAreRemoved() async throws {
        let store = try history()
        let conversation = AssistantConversation(entries: [
            .init(role: "你", text: "合成问题", status: "完成"),
            .init(role: "本机证据", text: "合成证据", status: "完成"),
            .init(role: "助手", text: "已完成60分钟。[E1][E2, E3]", status: "完成")
        ])
        try store.save(.init(conversations: [conversation], selectedID: conversation.id))
        let session = AssistantSession(historyStore: store, simulated: true, snapshot: { nil })
        await session.waitUntilReady()
        XCTAssertEqual(session.visibleEntries.map(\.role), ["你", "助手"])
        XCTAssertEqual(AssistantMarkdown.answerText(session.visibleEntries[1].text), "已完成60分钟。")
    }
    @MainActor func testStoppingInFlightIgnoresLateResponse() async throws {
        let mock = AssistantMockTransport(delay: .seconds(3)), session = try await session(mock)
        session.send(); try await waitUntil { session.approval != nil }
        session.decide(session.approval!.id, allow: true)
        try await Task.sleep(for: .milliseconds(100)); session.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(session.busy); XCTAssertTrue(session.evidence.isEmpty)
        XCTAssertFalse(session.entries.contains { $0.role == "助手" })
    }
    @MainActor func testContinuousFollowupUsesCompletedConversationOnly() async throws {
        let snapshot = AssistantSimulation.snapshot()
        var mocks: [AssistantMockTransport] = []
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { snapshot }, transportFactory: {
            let value = AssistantMockTransport(script: Array(AssistantSimulation.script.prefix(2))); mocks.append(value); return value
        })
        session.configuration = AssistantSimulation.configuration(); session.question = "第一问"; session.send(); try await complete(session)
        session.question = "那下一节呢？"; session.send(); try await complete(session)
        let requests = await mocks[1].requests
        XCTAssertTrue(requests[0].body.contains("第一问")); XCTAssertTrue(requests[0].body.contains("那下一节呢"))
        XCTAssertTrue(requests[0].body.contains("合成演示完成"))
        XCTAssertEqual(session.entries.filter { $0.role == "助手" }.count, 2)
    }
    @MainActor func testFailureIsNotRetriedAndCorruptHistoryDisablesWrites() async throws {
        let mock = AssistantMockTransport(failAt: 1), session = try await session(mock)
        session.send(); try await complete(session)
        let requests = await mock.requests; XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(session.message, AssistantError.network.rawValue)
        let store = try history(); try Data("corrupt".utf8).write(to: store.url)
        let broken = try await self.session(history: store); broken.send()
        XCTAssertFalse(broken.busy); XCTAssertNotNil(broken.historyMessage)
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "corrupt")
    }
}

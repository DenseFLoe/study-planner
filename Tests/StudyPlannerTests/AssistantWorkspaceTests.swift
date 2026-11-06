import XCTest
import StudyCore
@testable import StudyPlanner

@MainActor final class AssistantWorkspaceTests: XCTestCase {
    private func session(_ transport: any AssistantAgentTransport, store: AssistantHistoryStore? = nil) -> AssistantSession {
        let value = AssistantSession(transport: transport, defaults: nil, historyStore: store)
        value.configuration = .init(provider: .deepSeek, endpoint: AssistantProvider.deepSeek.endpoint, model: "fixture")
        value.key = "synthetic-secret"
        return value
    }
    private func start(_ session: AssistantSession, _ context: AssistantContext, question: String = "检查今天的安排") throws {
        session.question = question; session.prepare { context }
        session.approve(try XCTUnwrap(session.approval).id)
    }
    func testApprovalContainsExactBodyAndDestinationForInitialAndToolRequests() async throws {
        let transport = AgentScriptTransport([.tools([AgentFixture.call("list_courses", #"{"offset":0}"#)]), .answer("确认[R1]")])
        let session = session(transport), context = AgentFixture.context()
        session.question = "检查课程"; session.prepare { context }
        let first = try XCTUnwrap(session.approval)
        XCTAssertTrue(first.summary.contains("DeepSeek")); XCTAssertFalse(first.details.contains(session.key))
        session.approve(first.id); await session.waitForRequest()
        let body = await transport.body(0); XCTAssertEqual(Data(body.utf8), first.body)
        let second = try XCTUnwrap(session.approval)
        XCTAssertTrue(second.summary.contains("课程名称")); XCTAssertTrue(second.details.contains("untrusted_name"))
        session.approve(second.id); await session.waitForRequest()
        let secondBody = await transport.body(1); XCTAssertEqual(Data(secondBody.utf8), second.body)
    }
    func testGrantOnlySkipsIdenticalScopeAndFactsAndCanBeRevoked() async throws {
        let same = #"{"date":"2026-11-06","course":"课程1"}"#
        let other = #"{"date":"2026-11-07","course":"课程1"}"#
        let transport = AgentScriptTransport([
            .tools([AgentFixture.call("inspect_schedule", same, id: "a")]),
            .tools([AgentFixture.call("inspect_schedule", same, id: "b")]),
            .tools([AgentFixture.call("inspect_schedule", other, id: "c")]), .answer("完成[R3]")])
        let session = session(transport), context = AgentFixture.context()
        try start(session, context); await session.waitForRequest()
        let approval = try XCTUnwrap(session.approval), scope = try XCTUnwrap(approval.results.first?.scope)
        session.approve(approval.id, rememberScopes: [scope]); await session.waitForRequest()
        let count = await transport.count; XCTAssertEqual(count, 3)
        XCTAssertEqual(session.approval?.results.first?.id, "R3")
        session.revokeGrants(); XCTAssertTrue(session.grantedScopes.isEmpty)
        session.stop(); XCTAssertNil(session.approval)
        let original = AssistantTools.execute(AgentFixture.call("list_courses", #"{"offset":0}"#), context: context, id: "R1")
        var changed = context; changed.state.courses[0].name = "Changed"
        let next = AssistantTools.execute(AgentFixture.call("list_courses", #"{"offset":0}"#), context: changed, id: "R2")
        XCTAssertNotEqual(AssistantPrivacy.grantKey(original), AssistantPrivacy.grantKey(next))
    }
    func testLocalCredentialDetectionBlocksQuestionAndToolLabelsWithoutNetworkLeak() async throws {
        let transport = AgentScriptTransport([.tools([AgentFixture.call("list_courses", #"{"offset":0}"#)]), .answer("资料已拦截")])
        let session = session(transport)
        var context = AgentFixture.context()
        for value in ["我的密钥是 synthetic-secret", "sk-abcdefghijklmnopqrstuvwxyz", "password: abcdefghijkl"] {
            session.question = value; session.prepare { context }
            XCTAssertNil(session.approval); XCTAssertTrue(session.message?.contains("阻止发送") == true)
        }
        let count = await transport.count; XCTAssertEqual(count, 0)
        context.state.courses[0].name = "sk-abcdefghijklmnopqrstuvwxyz"
        try start(session, context, question: "列出课程"); await session.waitForRequest()
        XCTAssertNil(session.approval)
        let body = await transport.body(1)
        XCTAssertFalse(body.contains("abcdefghijklmnopqrstuvwxyz")); XCTAssertTrue(session.evidence.first?.denied == true)
    }
    func testHistoryPersistsOnlyVisibleTextAndRestoresBehindFreshConsent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AssistantHistoryStore(url: dir.appendingPathComponent("chat.json"))
        let transport = AgentScriptTransport([.answer("历史回答")]), context = AgentFixture.context()
        let first = session(transport, store: store)
        try start(first, context, question: "历史问题"); await first.waitForRequest()
        let id = first.conversationID; first.close()
        let saved = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(saved.contains("synthetic-secret")); XCTAssertFalse(saved.contains("reasoning"))
        XCTAssertFalse(saved.contains("SECRET-NOTES")); XCTAssertFalse(saved.contains("configuration"))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let secondTransport = AgentScriptTransport([.answer("新回答")]), second = session(secondTransport, store: store)
        second.selectConversation(id)
        XCTAssertEqual(second.entries.count, 2); XCTAssertTrue(second.grantedScopes.isEmpty)
        second.question = "继续"; second.prepare { context }
        XCTAssertTrue(second.approval?.details.contains("历史问题") == true)
        let count = await secondTransport.count; XCTAssertEqual(count, 0)
        second.stop(); second.deleteConversation(id)
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testUnreadableHistoryIsPreservedAndSymlinkIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("original"), link = dir.appendingPathComponent("link")
        try Data("bad json".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = AssistantHistoryStore(url: link)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: target), Data("bad json".utf8))
    }
    func testProposalNeedsSeparateConfirmationAndDuplicateApplyIsIgnored() async throws {
        let call = AgentFixture.call("preview_schedule_change", #"{"action":"auto_schedule","course":"课程1","value":"false"}"#)
        let transport = AgentScriptTransport([.tools([call]), .answer("请确认本机预览[R1]")])
        let session = session(transport), context = AgentFixture.context()
        try start(session, context); await session.waitForRequest()
        let proposal = try XCTUnwrap(session.proposal)
        XCTAssertTrue(context.state.courses[0].autoScheduleEnabled)
        var applied = 0
        await session.applyProposal(proposal.id) { _ in applied += 1; return true }
        XCTAssertEqual(applied, 0) // Outbound approval still pending.
        session.approve(try XCTUnwrap(session.approval).id); await session.waitForRequest()
        await session.applyProposal(proposal.id) { draft in
            applied += 1
            XCTAssertFalse(draft.preview.courses[0].autoScheduleEnabled)
            return true
        }
        await session.applyProposal(proposal.id) { _ in applied += 1; return true }
        XCTAssertEqual(applied, 1); XCTAssertNil(session.proposal)
        let count = await transport.count; XCTAssertEqual(count, 2) // Save doesn't call API.
    }
    func testCancelAndContextChangeInvalidateProposalWithoutApplying() async throws {
        for cancelled in [true, false] {
            let call = AgentFixture.call("preview_schedule_change", #"{"action":"auto_schedule","course":"课程1","value":"false"}"#)
            let transport = AgentScriptTransport([.tools([call])]), session = session(transport)
            let context = AgentFixture.context()
            try start(session, context); await session.waitForRequest()
            XCTAssertNotNil(session.proposal)
            if cancelled { session.stop() } else { session.contextChanged() }
            XCTAssertNil(session.proposal); XCTAssertTrue(context.state.courses[0].autoScheduleEnabled)
        }
    }
}

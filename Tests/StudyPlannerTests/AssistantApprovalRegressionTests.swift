import XCTest
import StudyCore
@testable import StudyPlanner

@MainActor final class AssistantApprovalRegressionTests: XCTestCase {
    private func session(_ transport: any AssistantAgentTransport, provider: AssistantProvider = .openAI) -> AssistantSession {
        let value = AssistantSession(transport: transport, defaults: nil)
        value.switchProvider(provider); value.configuration.model = "fixture-model"; value.key = "synthetic-secret"
        value.question = "帮我查查这门课为什么这么安排？"
        return value
    }
    private func start(_ session: AssistantSession, context: AssistantContext = AgentFixture.context()) throws {
        session.prepare { context }; session.approve(try XCTUnwrap(session.approval).id)
    }
    func testAutonomousHelpThenPrivateLookupThenAnswerAndFollowupForEveryProvider() async throws {
        for provider in AssistantProvider.allCases {
            let transport = AgentScriptTransport([
                .tools([AgentFixture.call("search_help", #"{"query":"排课"}"#, id: "help")]),
                .tools([AgentFixture.call("list_courses", #"{"offset":0}"#, id: "courses")]),
                .tools([AgentFixture.call("inspect_schedule", #"{"date":"2026-11-07","course":"课程1"}"#, id: "schedule")]),
                .answer("根据课表，明天有这些安排。[R3]"),
                .answer("可以继续追问这门课。[R3]")
            ])
            let session = session(transport, provider: provider)
            let context = AgentFixture.context()
            session.prepare { context }
            var count = await transport.count; XCTAssertEqual(count, 0)
            let questionApproval = try XCTUnwrap(session.approval)
            session.approve(questionApproval.id); session.approve(questionApproval.id)
            await session.waitForRequest()
            count = await transport.count; XCTAssertEqual(count, 2) // Public help continued autonomously.
            let courseApproval = try XCTUnwrap(session.approval)
            XCTAssertEqual(courseApproval.results.first?.title, "查找课程")
            var body = await transport.body(1)
            XCTAssertFalse(body.contains("untrusted_name")); XCTAssertFalse(body.contains("SECRET-NOTES"))
            session.approve(courseApproval.id); await session.waitForRequest()
            count = await transport.count; XCTAssertEqual(count, 3)
            body = await transport.body(2)
            XCTAssertTrue(body.contains("untrusted_name")); XCTAssertFalse(body.contains("synthetic-secret"))
            let data = try XCTUnwrap(session.approval)
            XCTAssertEqual(data.results.first?.title, "核对课表与排程依据")
            session.approve(data.id); await session.waitForRequest()
            XCTAssertEqual(session.entries.last?.text, "根据课表，明天有这些安排。[R3]")
            XCTAssertNil(session.message); XCTAssertNil(session.approval)
            session.question = "那接下来呢？"; session.prepare { context }
            XCTAssertGreaterThan(session.approval!.historyCount, 2)
            session.approve(session.approval!.id); await session.waitForRequest()
            body = await transport.body(4)
            XCTAssertTrue(body.contains("明天有这些安排")); XCTAssertTrue(body.contains("那接下来呢"))
            XCTAssertFalse(body.contains("SECRET-NOTES"))
        }
    }
    func testDenialDoesNotTransmitResultsOrAllowAnotherToolToBypassIt() async throws {
        let transport = AgentScriptTransport([
            .tools([AgentFixture.call("list_courses", #"{"offset":0}"#, id: "a")]),
            .tools([AgentFixture.call("inspect_settings", id: "b")]), .answer("没有授权数据，无法确认。[R1]")
        ])
        let session = session(transport)
        try start(session); await session.waitForRequest()
        session.approve(try XCTUnwrap(session.approval).id, includePrivateData: false)
        await session.waitForRequest()
        XCTAssertNil(session.approval)
        let count = await transport.count; XCTAssertEqual(count, 3)
        for index in 1..<count {
            let body = await transport.body(index)
            XCTAssertFalse(body.contains("untrusted_name")); XCTAssertFalse(body.contains("\"minimum_block_minutes\""))
        }
        XCTAssertTrue(session.message?.contains("未授权") == true)
        XCTAssertTrue(session.evidence.allSatisfy(\.denied))
    }
    func testStateQuestionModelAndDestinationChangesInvalidateApprovals() async throws {
        for field in 0..<4 {
            let transport = AgentScriptTransport([.answer("must not execute")])
            let session = session(transport)
            var context = AgentFixture.context()
            session.prepare { context }
            let approval = try XCTUnwrap(session.approval)
            switch field {
            case 0: context.state.courses[0].totalMinutes += 1
            case 1: session.question = "改过的问题"
            case 2: session.configuration.model = "changed"
            default: session.configuration.endpoint = "https://changed.invalid/api"
            }
            session.approve(approval.id); await session.waitForRequest()
            let count = await transport.count; XCTAssertEqual(count, 0)
            XCTAssertNil(session.approval)
        }
    }
    func testPrivateResultConfirmationInvalidatedByRuntimeOrStateChange() async throws {
        for runtime in [true, false] {
            let transport = AgentScriptTransport([.tools([AgentFixture.call("inspect_runtime")]), .answer("must not execute")])
            let session = session(transport)
            var context = AgentFixture.context()
            session.prepare { context }; session.approve(session.approval!.id); await session.waitForRequest()
            let approval = try XCTUnwrap(session.approval)
            if runtime { context.runtime.syncing = true } else { context.state.settings.minimumScheduleUnit = 30 }
            session.approve(approval.id); await session.waitForRequest()
            let count = await transport.count; XCTAssertEqual(count, 1); XCTAssertNil(session.approval)
        }
    }
    func testFailureHasNoAutomaticRetryAndProviderSwitchClearsContextAndKey() async throws {
        let transport = AgentScriptTransport([.fail(.rateLimited), .answer("重新提问")])
        let session = session(transport)
        try start(session); await session.waitForRequest()
        XCTAssertTrue(session.message?.contains("余额不足") == true)
        XCTAssertNil(session.approval); XCTAssertFalse(session.busy)
        let count = await transport.count; XCTAssertEqual(count, 1)
        session.switchProvider(.deepSeek)
        XCTAssertTrue(session.key.isEmpty); XCTAssertTrue(session.entries.isEmpty); XCTAssertTrue(session.evidence.isEmpty)
        session.close(); XCTAssertTrue(session.question.isEmpty)
    }
    func testBoundedLoopStopsWithoutNinthRequest() async throws {
        let steps = (0..<10).map { AgentScriptTransport.Step.tools([AgentFixture.call("search_help", #"{"query":"排课"}"#, id: "c\($0)")]) }
        let transport = AgentScriptTransport(steps), session = session(transport)
        try start(session); await session.waitForRequest()
        let count = await transport.count; XCTAssertEqual(count, 8)
        XCTAssertTrue(session.message?.contains("8次") == true); XCTAssertFalse(session.busy); XCTAssertNil(session.approval)
    }
    func testCancelAndCloseDiscardLateAnswer() async throws {
        for close in [true, false] {
            let transport = PausedAgentTransport(), session = session(transport)
            try start(session)
            try await transport.waitUntilStarted()
            if close { session.close() } else { session.stop() }
            try await transport.finish()
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(session.entries.contains { $0.text.contains("迟到回答") })
            XCTAssertFalse(session.busy); XCTAssertNil(session.approval)
            if close { XCTAssertTrue(session.key.isEmpty) }
        }
    }
}

private actor PausedAgentTransport: AssistantAgentTransport {
    var continuation: CheckedContinuation<AssistantReply, Error>?
    func turn(_ request: URLRequest, provider: AssistantProvider) async throws -> AssistantReply {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while continuation == nil {
            guard ContinuousClock.now < deadline else { throw AssistantError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func finish() throws {
        continuation?.resume(returning: try AgentFixture.reply(provider: .openAI, text: "迟到回答")); continuation = nil
    }
}

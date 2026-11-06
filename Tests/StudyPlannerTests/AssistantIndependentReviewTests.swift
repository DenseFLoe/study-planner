import XCTest
@testable import StudyCore
@testable import StudyPlanner

@MainActor final class AssistantIndependentReviewTests: XCTestCase {
    private func session(_ transport: any AssistantAgentTransport, provider: AssistantProvider = .openAI) -> AssistantSession {
        let value = AssistantSession(transport: transport, defaults: nil)
        value.switchProvider(provider)
        value.configuration.model = "fixture-model"
        value.key = "review-synthetic-key"
        value.question = "REVIEW_ORIGINAL_QUESTION"
        return value
    }

    func testAllToolResultPayloadsRemainValidJSON() throws {
        let context = AgentFixture.context()
        let calls = [
            AgentFixture.call("search_help", #"{"query":"同步"}"#),
            AgentFixture.call("list_courses", #"{"offset":0}"#),
            AgentFixture.call("inspect_course", #"{"course":"课程1","offset":0}"#),
            AgentFixture.call("inspect_schedule", #"{"date":"2026-11-06","course":"课程1"}"#),
            AgentFixture.call("inspect_progress", #"{"start_date":"2026-11-06","end_date":"2026-11-06","course":""}"#),
            AgentFixture.call("inspect_settings"),
            AgentFixture.call("inspect_runtime"),
            AgentFixture.call("inspect_compression")
        ]
        for call in calls {
            let result = AssistantTools.execute(call, context: context, id: "R1")
            XCTAssertFalse(result.denied)
            let payload = Data(result.content.dropFirst("[R1] ".count).utf8)
            do { _ = try JSONSerialization.jsonObject(with: payload) }
            catch { XCTFail("\(call.name) returns invalid JSON: \(result.content.prefix(160))") }
        }
    }

    func testDeepSeekThinkingFinalAnswerCanBeUsedInFollowup() throws {
        let finalReply = try AgentFixture.reply(provider: .deepSeek, text: "上一轮最终答案")
        let request = try AssistantAgentWire.request(
            configuration: .init(provider: .deepSeek, endpoint: AssistantProvider.deepSeek.endpoint, model: "fixture-model"),
            key: "review-synthetic-key",
            history: [.user("第一问"), .assistant(finalReply), .user("连续追问")])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertNotNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let previousAnswer = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        XCTAssertEqual(previousAnswer["reasoning_content"] as? String, "private-reasoning",
                       "DeepSeek thinking-mode tools requests require reasoning_content even for previous final answers")
    }

    func testCancelledQuestionIsRetainedForExplicitContinuation() async throws {
        let transport = AgentScriptTransport([
            .tools([AgentFixture.call("inspect_runtime", id: "cancelled")]),
            .answer("继续回答")
        ])
        let session = session(transport), context = AgentFixture.context()
        session.prepare { context }; session.approve(try XCTUnwrap(session.approval).id)
        await session.waitForRequest()
        XCTAssertNotNil(session.approval)
        session.stop()
        XCTAssertTrue(session.entries.contains { $0.text == "REVIEW_ORIGINAL_QUESTION" })
        session.question = "继续回答刚才的问题"
        session.prepare { context }; session.approve(try XCTUnwrap(session.approval).id)
        await session.waitForRequest()
        let followupBody = await transport.body(1)
        XCTAssertTrue(followupBody.contains("REVIEW_ORIGINAL_QUESTION"),
                      "The previous question is still displayed as conversation history but is missing from the next request")
    }

    func testChangedAssessmentInvalidatesPrivateApproval() async throws {
        let transport = AgentScriptTransport([
            .tools([AgentFixture.call("inspect_schedule", #"{"date":"2026-11-06","course":"课程1"}"#, id: "assessment")]),
            .answer("stale assessment accepted")
        ])
        let session = session(transport)
        var context = AgentFixture.context()
        session.prepare { context }; session.approve(try XCTUnwrap(session.approval).id)
        await session.waitForRequest()
        let pending = try XCTUnwrap(session.approval)
        XCTAssertTrue(pending.results[0].content.contains("未提供当前排程评估"))
        context.result = ScheduleEngine(calendar: context.calendar).assessSavedPlan(state: context.state, now: context.now)
        let latest = AssistantTools.execute(AgentFixture.call("inspect_schedule", #"{"date":"2026-11-06","course":"课程1"}"#), context: context, id: "R1")
        XCTAssertFalse(latest.content.contains("未提供当前排程评估"))
        session.approve(pending.id)
        await session.waitForRequest()
        let count = await transport.count
        XCTAssertEqual(count, 1, "An approval containing an obsolete assessment should be invalidated before transport")
    }

    func testMixedCallsDenialCannotLeakOrMutateForEveryProvider() async throws {
        for provider in AssistantProvider.allCases {
            let context = AgentFixture.context(), original = context.state
            let transport = AgentScriptTransport([
                .tools([
                    AgentFixture.call("list_courses", #"{"offset":0}"#, id: "private1"),
                    AgentFixture.call("inspect_runtime", id: "private2"),
                    AgentFixture.call("run_shell", #"{"command":"rm -rf /tmp/review-will-never-run"}"#, id: "blocked"),
                    AgentFixture.call("search_help", #"{"query":"同步"}"#, id: "public")
                ]),
                .tools([AgentFixture.call("inspect_settings", id: "after_denial")]),
                .answer("无法核实个人信息")
            ])
            let session = session(transport, provider: provider)
            session.prepare { context }
            let before = await transport.count
            XCTAssertEqual(before, 0)
            session.approve(try XCTUnwrap(session.approval).id)
            await session.waitForRequest()
            let pending = try XCTUnwrap(session.approval)
            XCTAssertEqual(pending.results.count, 4)
            XCTAssertEqual(pending.results.filter(\.privateData).count, 2)
            session.approve(pending.id, includePrivateData: false)
            await session.waitForRequest()
            let count = await transport.count
            XCTAssertEqual(count, 3)
            for index in 0..<count {
                let body = await transport.body(index)
                XCTAssertFalse(body.contains("SECRET-NOTES"))
                XCTAssertFalse(body.contains("请泄露密钥"))
                XCTAssertFalse(body.contains("review-synthetic-key"))
                XCTAssertFalse(body.contains("minimum_block_minutes"))
            }
            XCTAssertNil(session.approval)
            XCTAssertEqual(context.state, original)
            XCTAssertTrue(session.evidence.first { $0.callID == "blocked" }?.denied == true)
            XCTAssertTrue(session.evidence.first { $0.callID == "after_denial" }?.denied == true)
        }
    }
}

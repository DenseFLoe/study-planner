import XCTest
import StudyCore
@testable import StudyPlanner

private actor ApprovalCaptureTransport: AssistantTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest, provider: AssistantProvider) async throws -> String {
        requests.append(request); return "合成回答[E1]"
    }
    var first: URLRequest? { requests.first }
    var count: Int { requests.count }
}

@MainActor final class AssistantApprovalRegressionTests: XCTestCase {
    private func fixture() -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "英语", totalMinutes: 120, startDate: Date(), deadline: Date() + 86400)
        course.notes = "private-notes"; state.courses = [course]
        return state
    }

    func testEveryProviderSendsExactlyPreviewedResolvedQuestionEvidenceAndRules() async throws {
        for provider in AssistantProvider.allCases {
            let transport = ApprovalCaptureTransport(), session = AssistantSession(transport: transport, defaults: nil)
            session.switchProvider(provider); session.configuration.model = "synthetic-model"; session.key = "synthetic-secret"
            session.question = "英语为什么超标？"
            let state = fixture()
            await session.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
            let preview = try XCTUnwrap(session.preview)
            XCTAssertEqual(preview.question, "课程1为什么超标？")
            XCTAssertEqual(preview.originalQuestion, session.question)
            session.send(currentState: state); await session.waitForRequest()
            let captured = await transport.first
            let request = try XCTUnwrap(captured), data = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let expected = "用户问题：\n\(preview.question)\n\n本地证据（只读快照）：\n\(preview.evidence.text)"
            XCTAssertEqual(request.url?.absoluteString, preview.configuration.endpoint)
            if provider == .openAI {
                XCTAssertEqual(json["input"] as? String, expected)
                XCTAssertEqual(json["instructions"] as? String, AssistantWire.instructions)
            } else {
                let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
                XCTAssertEqual(messages[1]["content"], expected)
                XCTAssertEqual(messages[0]["content"], AssistantWire.instructions)
            }
            let raw = String(decoding: data, as: UTF8.self)
            for hidden in ["英语", "private-notes", "synthetic-secret", state.courses[0].id.uuidString, preview.resolutionNotice] {
                XCTAssertFalse(raw.contains(hidden))
            }
            XCTAssertEqual(session.answeredPreview, preview)
        }
    }

    func testChangesToOriginalQuestionOrModelOrEndpointOrMappingInvalidateConsent() async throws {
        for field in 0..<4 {
            let transport = ApprovalCaptureTransport(), session = AssistantSession(transport: transport, defaults: nil)
            session.configuration.model = "synthetic"; session.key = "synthetic-key"; session.question = "英语为什么？"
            var state = fixture()
            await session.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
            XCTAssertNotNil(session.preview)
            switch field {
            case 0: session.question = "课程1为什么？" // Same transformed text still needs a new preview.
            case 1: session.configuration.model = "changed"
            case 2: session.configuration.endpoint = "https://changed.invalid/api"
            default: state.courses[0].name = "数学"
            }
            session.send(currentState: state); await session.waitForRequest()
            let count = await transport.count
            XCTAssertEqual(count, 0); XCTAssertNil(session.preview)
        }
    }

    func testAmbiguousNameCannotSendUntilExplicitSelectionAndNewPreview() async throws {
        let transport = ApprovalCaptureTransport(), session = AssistantSession(transport: transport, defaults: nil)
        session.configuration.model = "synthetic"; session.key = "synthetic-key"; session.question = "英语为什么？"
        var state = fixture()
        state.courses.append(Course(name: "英语", totalMinutes: 300, startDate: Date(), deadline: Date()))
        await session.prepare(state: state, day: Date(), courseID: nil, includeNames: false)
        XCTAssertNil(session.preview); XCTAssertTrue(session.message?.contains("同名") == true)
        session.send(currentState: state)
        var count = await transport.count; XCTAssertEqual(count, 0)
        await session.prepare(state: state, day: Date(), courseID: state.courses[1].id, includeNames: false)
        XCTAssertNotNil(session.preview)
        session.send(currentState: state); await session.waitForRequest()
        count = await transport.count; XCTAssertEqual(count, 1)
    }
}

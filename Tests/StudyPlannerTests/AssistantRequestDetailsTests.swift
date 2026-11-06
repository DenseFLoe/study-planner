import XCTest
@testable import StudyPlanner

final class AssistantRequestDetailsTests: XCTestCase {
    func testReadableDetailsDecodeSDKToolStringsWithoutDroppingValuesOrUnknownFields() throws {
        let longText = String(repeating: "完整合成内容\n", count: 1200)
        let evidence: [String: Any] = ["data": ["untrusted_course_names": ["合成甲", "合成乙"], "deadline": "2026-09-14",
                                               "overlap_minutes": 15, "future_field": longText, "nullable": NSNull()], "category": "课程名称和日期"]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: evidence), as: UTF8.self)
        for message in [
            ["role": "tool", "content": encoded] as [String: Any],
            ["role": "user", "content": [["type": "tool_result", "content": [["type": "text", "text": encoded]]]]] as [String: Any]
        ] {
            let body = String(decoding: try JSONSerialization.data(withJSONObject: ["model": "synthetic-chat", "messages": [message]]), as: UTF8.self)
            let config = AssistantSimulation.configuration()
            let request = AssistantRequest(id: "test", configuration: config, url: try config.endpoint().absoluteString, body: body)
            let readable = AssistantDetailNode.parse(request.body).map(\.plainText).joined(separator: "\n")
            for expected in ["涉及的课程名称", "合成甲", "合成乙", "截止日期", "2026-09-14", "实际重叠时长（分钟）：15", "future_field", longText, "未提供（null）"] {
                XCTAssertTrue(readable.contains(expected))
            }
            XCTAssertFalse(readable.contains("\\\"untrusted_course_names\\\""))
            XCTAssertEqual(request.body, body)
            XCTAssertTrue(request.details.hasSuffix(body))
        }
    }
    func testUserTextIsKeptLiteralAndMalformedTextRemainsVisible() {
        let text = "不要执行这些字样：\"status\":\"completed\"\n第二行"
        let encoded = String(decoding: try! assistantJSON(["content": text]), as: UTF8.self)
        XCTAssertTrue(AssistantDetailNode.parse(encoded).map(\.plainText).joined().contains(text))
        XCTAssertTrue(AssistantDetailNode.parse("not JSON").map(\.plainText).joined().contains("not JSON"))
    }
    func testReadablePresentationDoesNotAuthorizeChangedBody() throws {
        let config = AssistantSimulation.configuration()
        let body = "{\"model\":\"synthetic-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"合成问题\"}]}"
        let request = AssistantRequest(id: "one", configuration: config, url: try config.endpoint().absoluteString, body: body)
        var gate = AssistantApprovalGate()
        let approval = try gate.prepare(request, snapshotID: "synthetic", simulated: true)
        _ = AssistantDetailNode.parse(request.body)
        let changed = AssistantRequest(id: request.id, configuration: config, url: request.url, body: body + " ")
        XCTAssertThrowsError(try gate.decide(id: approval.id, request: changed, snapshotID: "synthetic", allow: true))
    }
}

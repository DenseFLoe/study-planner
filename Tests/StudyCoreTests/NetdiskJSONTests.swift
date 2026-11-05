import XCTest
@testable import StudyCore

final class NetdiskJSONTests: XCTestCase {
    func testRequestStringsRoundTripWithoutBecomingNull() throws {
        for value in ["", "abc123", "7x9q", "含 空格+&=", "\"quoted\"\\path\n\t", "课程😀\u{2028}\u{2029}"] {
            let literal = NetdiskJSON.string(value).javaScriptLiteral
            let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed])
            XCTAssertEqual(decoded as? String, value)
            XCTAssertNotEqual(literal, "null")
        }
    }

    func testInPageTokenBodyMatchesNativeRequestValues() throws {
        let body: [String: NetdiskJSON] = ["pwd_id": .string("abc123"), "passcode": .string("'\"\\测试"),
                                           "support_visit_limit_private_share": .bool(true), "page": .number(2)]
        let literal = "{" + body.sorted { $0.key < $1.key }.map {
            NetdiskJSON.string($0.key).javaScriptLiteral + ":" + $0.value.javaScriptLiteral
        }.joined(separator: ",") + "}"
        let inPage = try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? NSDictionary
        let native = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body.mapValues(\.anyValue))) as? NSDictionary
        XCTAssertEqual(inPage, native)
        XCTAssertEqual(inPage?["pwd_id"] as? String, "abc123")
        XCTAssertEqual(inPage?["support_visit_limit_private_share"] as? Bool, true)
    }

    func testBooleanAndNumericScalarsKeepTheirTypes() throws {
        for (value, expected) in [(NetdiskJSON.bool(false), NSNumber(value: false)),
                                  (.bool(true), NSNumber(value: true)),
                                  (.number(2.5), NSNumber(value: 2.5))] {
            let decoded = try JSONSerialization.jsonObject(with: Data(value.javaScriptLiteral.utf8),
                                                           options: [.fragmentsAllowed])
            XCTAssertEqual(decoded as? NSNumber, expected)
        }
    }
}

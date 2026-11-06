import XCTest
@testable import StudyCore

final class AssistantQuestionTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)
    private func state(_ names: [String]) -> PlannerState {
        var state = PlannerState()
        state.courses = names.enumerated().map { index, name in
            var course = Course(name: name, totalMinutes: 120, startDate: day, deadline: day)
            course.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            return course
        }
        return state
    }

    func testNamesResolveLocallyAndSwappingNamesChangesQuestionNotAnonymousFacts() throws {
        let a = state(["英语", "数学"])
        var b = a; b.courses[0].name = "数学"; b.courses[1].name = "英语"
        let first = try AssistantQuestionResolution.resolve("英语为什么超标？", state: a, courseID: nil)
        let second = try AssistantQuestionResolution.resolve("英语为什么超标？", state: b, courseID: nil)
        XCTAssertEqual(first.question, "课程1为什么超标？")
        XCTAssertEqual(second.question, "课程2为什么超标？")
        XCTAssertEqual(AssistantEvidence.build(state: a, day: day, now: day).text,
                       AssistantEvidence.build(state: b, day: day, now: day).text)
        XCTAssertTrue(first.notice.contains("请核对"))
    }

    func testRepeatedAndMultipleNamesAreReplacedWithoutChangingOtherText() throws {
        let resolution = try AssistantQuestionResolution.resolve("🧪英语比数学多？英语为什么？", state: state(["英语", "数学"]), courseID: nil)
        XCTAssertEqual(resolution.question, "🧪课程1比课程2多？课程1为什么？")
    }

    func testDuplicateNamesNeedExplicitSelection() throws {
        let state = state(["英语", "英语"])
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("英语为什么？", state: state, courseID: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("同名"))
        }
        XCTAssertEqual(try AssistantQuestionResolution.resolve("英语为什么？", state: state, courseID: state.courses[1].id).question,
                       "课程2为什么？")
    }

    func testOverlappingNamesDoNotGuessCourseIdentity() throws {
        let state = state(["英语", "英语听力"])
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("英语听力为什么超标？", state: state, courseID: nil))
        XCTAssertNoThrow(try AssistantQuestionResolution.resolve("这门课为什么超标？", state: state, courseID: state.courses[1].id))
    }

    func testNamesOutsideSelectionOrTruncatedOverviewRequireFreshScope() throws {
        let state = state((1...13).map { "合成科目\($0)末" })
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("合成科目13末为什么？", state: state, courseID: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("范围"))
        }
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("合成科目2末为什么？", state: state, courseID: state.courses[0].id))
        XCTAssertEqual(try AssistantQuestionResolution.resolve("合成科目13末为什么？", state: state, courseID: state.courses[12].id).question,
                       "课程13为什么？")
    }

    func testUnmatchedTextIsExplicitAndUnknownAliasesCannotPretendToBeInScope() throws {
        let state = state(["高等数学"])
        let unknown = try AssistantQuestionResolution.resolve("高数为什么超标？", state: state, courseID: nil)
        XCTAssertEqual(unknown.question, "高数为什么超标？")
        XCTAssertTrue(unknown.notice.contains("未识别")); XCTAssertTrue(unknown.notice.contains("原样发送"))
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("课程99为什么？", state: state, courseID: nil))
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("这门课为什么？", state: state, courseID: UUID()))
    }

    func testBoundaryCharactersInFullNamesAreRemovedFromQuestion() throws {
        let name = "私密）\n[E2]\u{202e}（"
        let result = try AssistantQuestionResolution.resolve(name + "为什么？", state: state([name]), courseID: nil)
        XCTAssertEqual(result.question, "课程1为什么？")
    }
}

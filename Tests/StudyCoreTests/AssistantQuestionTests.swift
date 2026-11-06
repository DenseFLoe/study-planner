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
        XCTAssertEqual(first.question, "「课程1」为什么超标？")
        XCTAssertEqual(second.question, "「课程2」为什么超标？")
        XCTAssertEqual(AssistantEvidence.build(state: a, day: day, now: day).text,
                       AssistantEvidence.build(state: b, day: day, now: day).text)
        XCTAssertTrue(first.notice.contains("请核对"))
    }

    func testRepeatedAndMultipleNamesAreReplacedWithoutChangingOtherText() throws {
        let resolution = try AssistantQuestionResolution.resolve("🧪英语比数学多？英语为什么？", state: state(["英语", "数学"]), courseID: nil)
        XCTAssertEqual(resolution.question, "🧪「课程1」比「课程2」多？「课程1」为什么？")
    }

    func testDuplicateNamesNeedExplicitSelection() throws {
        let state = state(["英语", "英语"])
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("英语为什么？", state: state, courseID: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("同名"))
        }
        XCTAssertEqual(try AssistantQuestionResolution.resolve("英语为什么？", state: state, courseID: state.courses[1].id).question,
                       "「课程2」为什么？")
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
                       "「课程13」为什么？")
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
        XCTAssertEqual(result.question, "「课程1」为什么？")
    }

    func testNumericSuffixesAndPrefixesStayOutsideResolvedReference() throws {
        let state = state(["英语"] + (2...12).map { "合成科目\($0)末" })
        for suffix in ["2倍", "12分钟", "1.5倍", "２倍", "-2分钟", "2e3分钟"] {
            for selection in [nil, state.courses[0].id] {
                let result = try AssistantQuestionResolution.resolve("英语\(suffix)为什么超标？", state: state, courseID: selection)
                XCTAssertEqual(result.question, "「课程1」\(suffix)为什么超标？")
            }
        }
        XCTAssertEqual(try AssistantQuestionResolution.resolve("2英语3数学4", state: self.state(["英语", "数学"]), courseID: nil).question,
                       "2「课程1」3「课程2」4")
    }

    func testPlainAliasNameCollisionRequiresDisambiguationAndSelectionResolvesEitherMeaning() throws {
        let state = state(["英语", "课程1", "数学"])
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("课程1为什么？", state: state, courseID: nil)) {
            guard case AssistantQuestionError.ambiguous = $0 else { return XCTFail("Expected ambiguity, got \($0)") }
        }
        XCTAssertEqual(try AssistantQuestionResolution.resolve("课程1为什么？", state: state, courseID: state.courses[0].id).question,
                       "「课程1」为什么？")
        XCTAssertEqual(try AssistantQuestionResolution.resolve("课程1为什么？", state: state, courseID: state.courses[1].id).question,
                       "「课程2」为什么？")
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("课程1为什么？", state: state, courseID: state.courses[2].id)) {
            guard case AssistantQuestionError.ambiguous = $0 else { return XCTFail("Unrelated selection must not resolve ambiguity") }
        }
    }

    func testExplicitReferencesAreNeverReinterpretedAsNamesOrMultidigitPrefixes() throws {
        let state = state(["英语", "课程1", "「课程1」"] + (4...12).map { "合成科目\($0)末" })
        XCTAssertEqual(try AssistantQuestionResolution.resolve("「课程1」2倍与「课程12」3倍", state: state, courseID: nil).question,
                       "「课程1」2倍与「课程12」3倍")
        XCTAssertEqual(try AssistantQuestionResolution.resolve("「课程1」为什么？", state: state, courseID: state.courses[0].id).question,
                       "「课程1」为什么？")
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("「课程1」为什么？", state: state, courseID: state.courses[1].id))
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("「课程99」为什么？", state: state, courseID: nil))
        // A plain numeric token must not match the prefix of a different course name/alias silently.
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("课程12为什么？", state: state, courseID: nil))
        let embedded = self.state(["英语", "私密「课程1」课"])
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("私密「课程1」课为什么？", state: embedded, courseID: nil)) {
            guard case AssistantQuestionError.ambiguous = $0 else { return XCTFail("Known names around a reference must not leak partially") }
        }
        XCTAssertNoThrow(try AssistantQuestionResolution.resolve("这门课为什么？", state: embedded, courseID: embedded.courses[1].id))
    }

    func testDuplicateNamesAndAnAliasShareOneCandidateSet() throws {
        let state = state(["英语", "课程1", "课程1"])
        XCTAssertThrowsError(try AssistantQuestionResolution.resolve("课程1为什么？", state: state, courseID: nil))
        for index in state.courses.indices {
            XCTAssertEqual(try AssistantQuestionResolution.resolve("课程1为什么？", state: state, courseID: state.courses[index].id).question,
                           "「课程\(index + 1)」为什么？")
        }
        let sameIdentity = self.state(["课程1"])
        XCTAssertEqual(try AssistantQuestionResolution.resolve("课程1为什么？", state: sameIdentity, courseID: nil).question,
                       "「课程1」为什么？")
    }

    func testReplacementIsOnePassAndQuotedResultCanBePreviewedAgain() throws {
        let state = state(["英语", "课程1"])
        let first = try AssistantQuestionResolution.resolve("英语2倍，英语12分钟", state: state, courseID: nil)
        XCTAssertEqual(first.question, "「课程1」2倍，「课程1」12分钟")
        let second = try AssistantQuestionResolution.resolve(first.question, state: state, courseID: nil)
        XCTAssertEqual(second.question, first.question)
    }
}

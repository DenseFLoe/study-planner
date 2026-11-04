import XCTest
@testable import StudyPlanner

final class AppBuildInfoTests: XCTestCase {
    private var packaged: [String: Any] { [
        "CFBundleShortVersionString": "1.6.3",
        "CFBundleVersion": "18",
        "StudyPlannerSourceIdentifier": "748b5d4",
        "StudyPlannerSourceRevision": "748b5d4abcdef",
        "StudyPlannerSourceFingerprint": "abc123",
        "StudyPlannerSourceModified": false,
        "StudyPlannerBuildDate": "2026-11-04T12:00:00Z",
        "StudyPlannerBuildConfiguration": "release"
    ] }

    func testDifferentSourcesRemainDistinguishableAtSameMarketingVersion() {
        var older = packaged
        older["StudyPlannerSourceIdentifier"] = "17cea0b"
        let installed = AppBuildInfo(info: older)
        let latest = AppBuildInfo(info: packaged)
        XCTAssertEqual(installed.versionDescription, latest.versionDescription)
        XCTAssertNotEqual(installed.sourceDescription, latest.sourceDescription)
        XCTAssertTrue(latest.diagnosticDescription.contains("提交 748b5d4abcdef"))
        XCTAssertTrue(latest.diagnosticDescription.contains("构建时间 2026-11-04T12:00:00Z"))
        XCTAssertTrue(latest.diagnosticDescription.contains("配置 release"))
        XCTAssertFalse(latest.sourceDescription.contains("含未提交修改"))
    }

    func testModifiedSourceIsExplicitInAboutAndDiagnosticText() {
        var info = packaged
        info["StudyPlannerSourceIdentifier"] = "748b5d4-modified-abc123"
        info["StudyPlannerSourceModified"] = true
        let result = AppBuildInfo(info: info)
        XCTAssertEqual(result.sourceDescription, "源码 748b5d4-modified-abc123（含未提交修改）")
        XCTAssertTrue(result.diagnosticDescription.contains(result.sourceDescription))
    }

    func testLegacyAndUnpackagedBuildsDoNotInventSourceIdentity() {
        let legacy = AppBuildInfo(info: ["CFBundleShortVersionString": "1.6.3", "CFBundleVersion": "18"])
        XCTAssertEqual(legacy.versionDescription, "1.6.3（构建 18）")
        XCTAssertEqual(legacy.sourceDescription, "源码 未记录")
        XCTAssertEqual(legacy.sourceRevision, "未记录")
        XCTAssertEqual(AppBuildInfo(info: [:]).version, "未记录")
        XCTAssertEqual(AppBuildInfo(info: ["StudyPlannerSourceIdentifier": "\n  "]).sourceIdentifier, "未记录")
    }
}

import XCTest
@testable import StudyCore

final class NetdiskImportIntegrityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_497_416)

    private func fixture() throws -> (NetdiskScan, [NetdiskSnapshotBuilder.Course]) {
        var entries: [NetdiskEntry] = []
        for name in ["高数课程", "线代课程"] {
            entries.append(NetdiskFixtures.folder(name))
            entries += (1...3).map { NetdiskFixtures.video("第\($0)讲.mp4", in: name, duration: 600) }
        }
        let scan = NetdiskFixtures.scan(packages: NetdiskFixtures.digest(entries).packages)
        let candidates = scan.packages.compactMap { NetdiskSnapshotBuilder.build(package: $0, scan: scan) }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.refusal == nil })
        return (scan, candidates)
    }

    private func save(_ candidates: [NetdiskSnapshotBuilder.Course], scan: NetdiskScan,
                      into state: inout PlannerState) throws {
        try state.importNetdiskCourses(candidates, scan: scan, duplicates: .init(),
                                       deadline: now.addingTimeInterval(90 * 86_400), now: now)
    }

    func testIncompleteRefreshPreservesCourseProgressAndManualLessonOrder() throws {
        var (scan, candidates) = try fixture()
        var state = PlannerState()
        try save([candidates[0]], scan: scan, into: &state)
        state.courses[0].lessonOrder = candidates[0].snapshot.lessons.reversed().map(\.id)
        state.courses[0].lessonOrderCustomized = true
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 10,
                                 lessonID: candidates[0].snapshot.lessons[0].id)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 5, now: now)
        let before = state
        scan.unreadFolders = 1
        candidates[0].snapshot.name = "读取未完成的新名称"
        XCTAssertThrowsError(try save([candidates[0]], scan: scan, into: &state)) { error in
            XCTAssertTrue(error.localizedDescription.contains("目录未读完"))
        }
        XCTAssertEqual(state, before)
    }

    func testIncompleteScanRejectsBothSeparateAndMergedImportsAtomically() throws {
        var (scan, candidates) = try fixture()
        let merged = try XCTUnwrap(NetdiskSnapshotBuilder.merge(candidates, name: "数学", scan: scan))
        scan.unreadFolders = 2
        for selected in [candidates, [merged]] {
            var state = PlannerState()
            let before = state
            XCTAssertThrowsError(try save(selected, scan: scan, into: &state))
            XCTAssertEqual(state, before)
        }
    }

    func testIncompleteSelectedPackageRejectsWholeBatchButUnselectedPackageDoesNot() throws {
        var (scan, candidates) = try fixture()
        scan.packages[1].unreadFolders = 1
        var state = PlannerState()
        let before = state
        XCTAssertThrowsError(try save(candidates, scan: scan, into: &state))
        XCTAssertEqual(state, before)
        try save([candidates[0]], scan: scan, into: &state)
        XCTAssertEqual(state.courses.map { $0.webCourse?.packageID }, [candidates[0].packageID])
    }

    func testCompleteScanKeepsInformationalNotesAndCanImportAfterRetry() throws {
        var (scan, candidates) = try fixture()
        scan.issues = ["链接指向子目录，已从该目录开始读取。"]
        var state = PlannerState()
        scan.unreadFolders = 1
        XCTAssertThrowsError(try save(candidates, scan: scan, into: &state))
        scan.unreadFolders = 0
        try save(candidates, scan: scan, into: &state)
        XCTAssertEqual(state.courses.count, 2)
        XCTAssertTrue(state.courses.allSatisfy { $0.netdiskLessons?.count == 3 })
        XCTAssertEqual(state.courses.map { $0.netdisk?.videoCount }, [3, 3])
    }
}

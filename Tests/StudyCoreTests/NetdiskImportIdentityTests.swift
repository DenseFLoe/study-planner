import XCTest
@testable import StudyCore

final class NetdiskImportIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_497_416)
    private let pwd = "abc123"

    private func fixture(_ folder: String, legacy: Bool = false,
                         entries supplied: [NetdiskEntry]? = nil) -> (NetdiskScan, [NetdiskSnapshotBuilder.Course]) {
        let entries = supplied ?? (1...3).map {
            NetdiskFixtures.video("第\($0)讲.mp4", duration: 600, fid: (folder.isEmpty ? "root" : folder) + "-v\($0)")
        }
        let result = NetdiskDigest.digest(entries: entries, rootTitle: "课程", pwdID: pwd,
                                          rootFID: legacy ? "" : folder)
        var scan = NetdiskFixtures.scan(packages: result.packages, pwdID: pwd, root: result.root)
        scan.sourceURL = "https://pan.quark.cn/s/" + pwd + (folder.isEmpty ? "" : "#/list/share/" + folder)
        return (scan, result.packages.compactMap { NetdiskSnapshotBuilder.build(package: $0, scan: scan) })
    }

    private func save(_ fixture: (NetdiskScan, [NetdiskSnapshotBuilder.Course]),
                      into state: inout PlannerState, deadline: Date? = nil) throws {
        try state.importNetdiskCourses(fixture.1, scan: fixture.0, duplicates: .init(),
                                       deadline: deadline ?? now.addingTimeInterval(90 * 86_400), now: now)
    }

    func testDistinctSubdirectoriesAndShareRootCreateIndependentCourses() throws {
        var state = PlannerState()
        for folder in ["aaaa0001", "bbbb0002", ""] { try save(fixture(folder), into: &state) }
        XCTAssertEqual(Set(state.courses.compactMap { $0.webCourse?.packageID }),
                       ["quark:abc123:aaaa0001", "quark:abc123:bbbb0002", "quark:abc123:root"])
        XCTAssertEqual(state.courses.count, 3)
        let ids = state.courses.map(\.id)
        try save(fixture("aaaa0001"), into: &state)
        XCTAssertEqual(state.courses.map(\.id), ids)
    }

    func testFullShareAndDirectFolderUseSamePackageIdentity() throws {
        let direct = fixture("aaaa0001")
        let videos = try XCTUnwrap(direct.0.packages.first).videos.map { video in
            var nested = video; nested.parentPath = "高数"; return nested
        }
        let full = NetdiskDigest.digest(entries: [NetdiskFixtures.folder("高数", fid: "aaaa0001")] + videos,
                                        rootTitle: "分享", pwdID: pwd)
        XCTAssertEqual(full.packages.map(\.packageID), direct.0.packages.map(\.packageID))
        XCTAssertEqual(direct.0.root.fid, "aaaa0001")
    }

    func testLegacyRefreshKeepsCourseIdentityProgressAndManualOrder() throws {
        var state = PlannerState()
        try save(fixture("aaaa0001", legacy: true), into: &state)
        let id = state.courses[0].id
        let lessons = try XCTUnwrap(state.courses[0].webCourse).lessons
        state.courses[0].lessonOrder = lessons.reversed().map(\.id)
        state.courses[0].lessonOrderCustomized = true
        state.courses[0].deletedLessonIDs = ["explicitly-removed"]
        state.courses[0].name = "我的复习计划"
        let task = ScheduledTask(courseID: id, start: now, durationMinutes: 10, lessonID: lessons[0].id)
        state.tasks = [task]; try state.confirm(taskID: task.id, actualMinutes: 5, now: now)
        let before = state
        try save(fixture("aaaa0001"), into: &state)
        XCTAssertEqual(state.courses.count, 1)
        XCTAssertEqual(state.courses[0].id, id)
        XCTAssertEqual(state.courses[0].webCourse?.packageID, "quark:abc123:aaaa0001")
        XCTAssertEqual(state.courses[0].name, "我的复习计划")
        XCTAssertEqual(state.completions, before.completions)
        XCTAssertEqual(state.tasks, before.tasks)
        XCTAssertEqual(state.courses[0].lessonOrder, before.courses[0].lessonOrder)
        XCTAssertEqual(state.courses[0].deletedLessonIDs, before.courses[0].deletedLessonIDs)
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 5)
    }

    func testMissingLessonsOrDuplicateBindingsLeaveLegacyDataUntouched() throws {
        var original = PlannerState()
        try save(fixture("aaaa0001", legacy: true), into: &original)
        var incomplete = fixture("aaaa0001")
        incomplete.1[0].snapshot.lessons.removeFirst()
        var state = original
        XCTAssertThrowsError(try save(incomplete, into: &state))
        XCTAssertEqual(state, original)
        var canonical = PlannerState()
        try save(fixture("aaaa0001"), into: &canonical)
        state.courses += canonical.courses
        let duplicate = state
        XCTAssertThrowsError(try save(fixture("aaaa0001"), into: &state))
        XCTAssertEqual(state, duplicate)
    }

    func testRejectedImportDoesNotPersistAnIdentityRepair() throws {
        var state = PlannerState()
        try save(fixture("aaaa0001", legacy: true), into: &state)
        let before = state
        XCTAssertThrowsError(try save(fixture("aaaa0001"), into: &state, deadline: now.addingTimeInterval(-86400)))
        XCTAssertEqual(state, before)
    }

    func testShareRootCannotOverwriteAnUnmigratedSubdirectory() throws {
        var state = PlannerState()
        try save(fixture("aaaa0001", legacy: true), into: &state)
        let before = state
        XCTAssertThrowsError(try save(fixture(""), into: &state))
        XCTAssertEqual(state, before)
        try save(fixture("aaaa0001"), into: &state)
        try save(fixture(""), into: &state)
        XCTAssertEqual(state.courses.count, 2)
        XCTAssertEqual(state.courses[0].id, before.courses[0].id)
    }

    func testLegacyRootWithoutFolderLocatorCannotBeReplacedByDifferentLessons() throws {
        var state = PlannerState()
        try save(fixture("aaaa0001", legacy: true), into: &state)
        state.courses[0].netdisk?.sourceURL = "https://pan.quark.cn/s/abc123"
        let before = state
        XCTAssertThrowsError(try save(fixture(""), into: &state))
        XCTAssertEqual(state, before)
    }

    func testShareRootCanRefreshWhenAllExistingLessonsStillCorrespond() throws {
        let original = fixture("")
        var state = PlannerState()
        try save(original, into: &state)
        let id = state.courses[0].id
        let videos = try XCTUnwrap(original.0.packages.first).videos
            + [NetdiskFixtures.video("第4讲.mp4", duration: 600, fid: "root-v4")]
        try save(fixture("", entries: videos), into: &state)
        XCTAssertEqual(state.courses.map(\.id), [id])
        XCTAssertEqual(state.courses[0].webCourse?.lessons.count, 4)
    }

    func testLegacyLectureSeriesAndMergedSeriesRetainTheirIdentities() throws {
        var entries: [NetdiskEntry] = []
        for stem in ["高数课节", "线代课节"] {
            for number in 1...3 {
                let name = stem + String(format: "%02d", number)
                entries += [NetdiskFixtures.folder(name), NetdiskFixtures.video("第\(number)讲.mp4", in: name, duration: 600)]
            }
        }
        let old = fixture("aaaa0001", legacy: true, entries: entries)
        let fresh = fixture("aaaa0001", entries: entries)
        XCTAssertEqual(old.1.count, 2)
        XCTAssertEqual(fresh.1.count, 2)
        for merged in [false, true] {
            let previous = merged ? [try XCTUnwrap(NetdiskSnapshotBuilder.merge(old.1, name: "数学合集", scan: old.0))] : old.1
            let current = merged ? [try XCTUnwrap(NetdiskSnapshotBuilder.merge(fresh.1, name: "数学合集", scan: fresh.0))] : fresh.1
            var state = PlannerState()
            try save((old.0, previous), into: &state)
            let ids = state.courses.map(\.id)
            try save((fresh.0, current), into: &state)
            XCTAssertEqual(state.courses.map(\.id), ids)
            XCTAssertEqual(state.courses.compactMap { $0.webCourse?.packageID }, current.map(\.packageID))
            XCTAssertEqual(state.courses.flatMap { $0.webCourse?.lessons ?? [] }.count, 6)
        }
    }
}

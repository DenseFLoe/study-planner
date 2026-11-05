import XCTest
@testable import StudyCore
@testable import StudyPlanner

private actor MergeWorkProbe {
    private(set) var calls = 0
    private(set) var cancelled = false
    private(set) var returned = false
    private(set) var ranOnMainThread = false
    private var held: CheckedContinuation<Void, Never>?
    let holdFirst: Bool

    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
    func isHeld() -> Bool { held != nil }
    func release() { held?.resume(); held = nil }

    func prepare(_ courses: [NetdiskSnapshotBuilder.Course], name: String, scan: NetdiskScan,
                 onMainThread: Bool) async
        -> NetdiskSnapshotBuilder.Course? {
        calls += 1
        let call = calls
        ranOnMainThread = onMainThread
        if holdFirst && call == 1 {
            await withCheckedContinuation { held = $0 }
            cancelled = Task.isCancelled
        }
        var value = NetdiskSnapshotBuilder.merge(courses, name: name, scan: scan)
        // Deliberately ignore cancellation to check the independent publication guard.
        if holdFirst && call == 1 { value?.name = "过期结果"; returned = true }
        return value
    }
}

@MainActor
final class NetdiskMergePreviewTests: XCTestCase, @unchecked Sendable {
    private func fixture() -> (NetdiskScan, [NetdiskSnapshotBuilder.Course]) {
        let root = NetdiskDirectory(fid: "root", shareToken: "", name: "课程", path: "", depth: 0,
                                   fileCount: 0, folderCount: 0, videoCount: 0, documentCount: 0,
                                   otherCount: 0, totalBytes: 0, totalSeconds: 0, children: [])
        let scan = NetdiskScan(pwdID: "abc123", passcodeProtected: false, title: "课程",
                               sourceURL: "https://pan.quark.cn/s/abc123", fetchedAt: Date(), root: root,
                               packages: [], totalVideoCount: 0, totalBytes: 0, totalSeconds: 0,
                               unreadFolders: 0, issues: [])
        let courses = (1...3).map { number in
            let id = "course\(number)", name = "课程\(number)"
            let lessons = [10, 2, 1].map {
                WebCourseLesson(id: id + ":\($0)", name: "第\($0)讲", subject: "", stage: "",
                                chapter: "", kind: "video", published: true, durationSeconds: 600,
                                watchedPercent: 0, markedFinished: false, requiresDuration: true)
            }
            let snapshot = WebCourseSnapshot(packageID: id, name: name, sourceURL: scan.sourceURL,
                                             fetchedAt: scan.fetchedAt, expectedOutlines: 1, fetchedOutlines: 1,
                                             lessons: lessons, issues: [])
            return NetdiskSnapshotBuilder.Course(snapshot: snapshot, lessons: Dictionary(uniqueKeysWithValues:
                lessons.map { ($0.id, NetdiskLessonMeta(fid: $0.id, path: $0.name, size: 100,
                                                       width: nil, height: nil, estimatedDuration: false)) }),
                refusal: nil, packageID: id, name: name, videoCount: 3, estimatedLessons: 0,
                totalBytes: 300, detection: "", notes: [])
        }
        return (scan, courses)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic merge did not reach the expected state")
    }

    func testRepeatedReadsReuseMergeAndNameWhitespaceDoesNotRestartIt() async throws {
        let (scan, courses) = fixture(), probe = MergeWorkProbe()
        let preview = NetdiskMergePreview { await probe.prepare($0, name: $1, scan: $2, onMainThread: Thread.isMainThread) }
        defer { preview.cancel() }
        let input = NetdiskMergePreview.Request(revision: UUID(), selected: ["course1", "course2"], name: "合并")
        preview.update(input, courses: courses, scan: scan)
        XCTAssertNil(preview.candidate(for: input))
        try await waitUntil { preview.candidate(for: input) != nil }
        let value = try XCTUnwrap(preview.candidate(for: input))
        XCTAssertEqual(value.snapshot.lessons.map(\.id),
                       ["course1:1", "course1:2", "course1:10", "course2:1", "course2:2", "course2:10"])
        XCTAssertEqual(value.lessons.count, 6)
        for _ in 0..<100 {
            let same = NetdiskMergePreview.Request(revision: input.revision, selected: input.selected, name: "  合并 \n")
            preview.update(same, courses: courses, scan: scan)
            XCTAssertEqual(preview.candidate(for: same)?.snapshot, value.snapshot)
        }
        let calls = await probe.calls, ranOnMainThread = await probe.ranOnMainThread
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(ranOnMainThread)
    }

    func testSelectionNameAndScanRevisionInvalidateBeforeUpdateAndPrepareCurrentData() async throws {
        var (scan, courses) = fixture()
        let preview = NetdiskMergePreview()
        defer { preview.cancel() }
        let original = NetdiskMergePreview.Request(revision: UUID(), selected: ["course1", "course2"], name: "合并")
        preview.update(original, courses: courses, scan: scan)
        try await waitUntil { preview.candidate(for: original) != nil }
        let inputs = [
            NetdiskMergePreview.Request(revision: original.revision, selected: ["course2", "course3"], name: "合并"),
            NetdiskMergePreview.Request(revision: original.revision, selected: ["course2", "course3"], name: "新名称"),
            NetdiskMergePreview.Request(revision: UUID(), selected: ["course2", "course3"], name: "新名称")
        ]
        for input in inputs {
            XCTAssertNil(preview.candidate(for: input), "Never offer the previous inputs for import")
            if input.revision != original.revision {
                courses[1].snapshot.lessons[0].durationSeconds = 1_234
                scan.fetchedAt = scan.fetchedAt.addingTimeInterval(60)
            }
            preview.update(input, courses: courses, scan: scan)
            XCTAssertNil(preview.candidate(for: input))
            try await waitUntil { preview.candidate(for: input) != nil }
            let value = try XCTUnwrap(preview.candidate(for: input))
            XCTAssertEqual(value.name, input.name)
            XCTAssertEqual(Set(value.sourcePackageIDs), input.selected)
            XCTAssertEqual(value.snapshot.fetchedAt, scan.fetchedAt)
        }
        XCTAssertEqual(preview.candidate(for: inputs.last)?.snapshot.lessons.first { $0.id == "course2:10" }?.durationSeconds, 1_234)
    }

    func testReturningToSameInputCannotPublishAnOlderCancelledWorker() async throws {
        let (scan, courses) = fixture(), probe = MergeWorkProbe(holdFirst: true)
        let preview = NetdiskMergePreview { await probe.prepare($0, name: $1, scan: $2, onMainThread: Thread.isMainThread) }
        defer { preview.cancel() }
        let first = NetdiskMergePreview.Request(revision: UUID(), selected: ["course1", "course2"], name: "合并")
        preview.update(first, courses: courses, scan: scan)
        try await waitUntil { await probe.isHeld() }
        let other = NetdiskMergePreview.Request(revision: first.revision, selected: ["course2", "course3"], name: "其他")
        preview.update(other, courses: courses, scan: scan)
        preview.update(first, courses: courses, scan: scan)
        try await waitUntil { preview.candidate(for: first) != nil }
        await probe.release()
        try await waitUntil { await probe.returned }
        // Give the cancelled delivery task an opportunity to run too.
        for _ in 0..<20 { await Task.yield() }
        let cancelled = await probe.cancelled, calls = await probe.calls
        XCTAssertTrue(cancelled, "Cancelling the UI task must reach the detached worker")
        XCTAssertEqual(calls, 2, "The intermediate input should be coalesced before sorting")
        XCTAssertEqual(preview.candidate(for: first)?.name, "合并")
    }

    func testClosingOrDisablingPreviewCancelsWorkerAndDiscardsLateResult() async throws {
        let (scan, courses) = fixture(), probe = MergeWorkProbe(holdFirst: true)
        let preview = NetdiskMergePreview { await probe.prepare($0, name: $1, scan: $2, onMainThread: Thread.isMainThread) }
        let input = NetdiskMergePreview.Request(revision: UUID(), selected: ["course1", "course2"], name: "合并")
        preview.update(input, courses: courses, scan: scan)
        try await waitUntil { await probe.isHeld() }
        preview.update(nil, courses: courses, scan: scan)
        XCTAssertNil(preview.candidate(for: input))
        await probe.release()
        try await waitUntil { await probe.returned }
        for _ in 0..<20 { await Task.yield() }
        let cancelled = await probe.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertNil(preview.candidate(for: input))
        XCTAssertFalse(preview.isUnavailable(for: input))
        preview.update(input, courses: courses, scan: scan)
        try await waitUntil { preview.candidate(for: input) != nil }
        preview.cancel()
        XCTAssertNil(preview.candidate(for: input))
    }

    func testMalformedMergeStopsLoadingAndCanRecoverWithANewScan() async throws {
        let (scan, courses) = fixture()
        let preview = NetdiskMergePreview()
        defer { preview.cancel() }
        var invalid = courses
        invalid[0].lessons = [:]
        let input = NetdiskMergePreview.Request(revision: UUID(), selected: ["course1", "course2"], name: "合并")
        preview.update(input, courses: invalid, scan: scan)
        try await waitUntil { preview.isUnavailable(for: input) }
        XCTAssertNil(preview.candidate(for: input))
        let fresh = NetdiskMergePreview.Request(revision: UUID(), selected: input.selected, name: input.name)
        preview.update(fresh, courses: courses, scan: scan)
        try await waitUntil { preview.candidate(for: fresh) != nil }
        preview.update(fresh, courses: courses, scan: nil)
        XCTAssertNil(preview.candidate(for: fresh), "A cleared/failed scan must also clear the preview")
    }

    func testReleasingPreviewCancelsWorkerWithoutRetainingTheWindowModel() async throws {
        let (scan, courses) = fixture(), probe = MergeWorkProbe(holdFirst: true)
        var preview: NetdiskMergePreview? = NetdiskMergePreview {
            await probe.prepare($0, name: $1, scan: $2, onMainThread: Thread.isMainThread)
        }
        weak var released = preview
        let input = NetdiskMergePreview.Request(revision: UUID(), selected: ["course1", "course2"], name: "合并")
        preview?.update(input, courses: courses, scan: scan)
        try await waitUntil { await probe.isHeld() }
        preview = nil
        XCTAssertNil(released)
        await probe.release()
        try await waitUntil { await probe.returned }
        let cancelled = await probe.cancelled
        XCTAssertTrue(cancelled)
    }
}

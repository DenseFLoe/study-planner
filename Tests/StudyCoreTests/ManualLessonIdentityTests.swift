import XCTest
@testable import StudyCore

final class ManualLessonIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func course(_ ids: [String], baseline: Int = 0) -> Course {
        var value = Course(name: "Manual identities", totalMinutes: ids.count * 60,
                           startDate: now, deadline: now.addingTimeInterval(86_400))
        value.type = .lessonBasedRecorded
        value.initialCompletedMinutes = baseline
        value.manualLessons = ids.enumerated().map {
            .init(id: $0.element, name: "Lesson \($0.offset)", durationMinutes: 60)
        }
        return value
    }

    private func roundTrip(_ state: PlannerState) throws -> PlannerState {
        let before = state
        var ledger = SyncLedger()
        try ledger.capture(state)
        let records = ledger.records
        let restored = try ledger.materialize()
        _ = try CloudArchive(ledger: ledger).validated()
        XCTAssertEqual(state, before)
        XCTAssertEqual(ledger.records, records)
        return restored
    }

    private func confirmedState(_ course: Course, lessonID: String) throws -> PlannerState {
        var state = PlannerState()
        state.courses = [course]
        let task = ScheduledTask(courseID: course.id, start: now.addingTimeInterval(-3600),
                                 durationMinutes: 60, lessonID: lessonID)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now)
        return state
    }

    func testDuplicateIdentityCannotCreatePhantomProgress() throws {
        var input = PlannerState()
        input.courses = [course(["same", "same"])]
        let state = try roundTrip(input)
        let saved = try XCTUnwrap(state.courses.first)
        let before = state
        XCTAssertTrue(state.lessonWorkItems(for: saved).isEmpty)
        XCTAssertEqual(state.completedMinutes(for: saved), 0)
        XCTAssertEqual(state.remainingMinutes(for: saved), 120)
        XCTAssertTrue(state.completions.isEmpty)
        XCTAssertEqual(saved.manualLessons, input.courses[0].manualLessons)
        XCTAssertEqual(state, before)
    }

    func testDuplicateFallbackPreservesBaselineAndRecordedConfirmation() throws {
        let input = try confirmedState(course(["same", "same"], baseline: 10), lessonID: "same")
        let state = try roundTrip(input)
        let saved = try XCTUnwrap(state.courses.first)
        let before = state
        XCTAssertTrue(state.lessonWorkItems(for: saved).isEmpty)
        XCTAssertEqual(state.completedMinutes(for: saved), 30)
        XCTAssertEqual(state.remainingMinutes(for: saved), 90)
        XCTAssertEqual(state.completions, input.completions)
        XCTAssertEqual(state.tasks, input.tasks)
        XCTAssertEqual(saved, input.courses[0])
        XCTAssertEqual(state, before)
    }

    func testNestedDuplicateFallbackKeepsFullPrefixAndSourceBaseline() throws {
        let leaf = course(["same", "same"], baseline: 20)
        var branch = course(["branch-0", "branch-1"], baseline: 20)
        branch.manualLessons = nil
        branch.mergedSources = [leaf]
        let sibling = course(["only"])
        var root = course(["root-0", "root-1", "root-2"], baseline: 20)
        root.manualLessons = nil
        root.mergedSources = [branch, sibling]
        var input = PlannerState()
        input.courses = [root]
        let state = try roundTrip(input)
        let saved = try XCTUnwrap(state.courses.first)
        let before = state
        let items = state.lessonWorkItems(for: saved)
        let fallbackID = "\(branch.id)/\(leaf.id)/whole"
        let siblingID = "\(sibling.id)/only"
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)), [fallbackID, siblingID])
        XCTAssertEqual(items.first { $0.id == fallbackID }?.remainingMinutes, 100)
        XCTAssertEqual(items.first { $0.id == siblingID }?.remainingMinutes, 60)
        XCTAssertEqual(state.completedMinutes(for: saved), 20)
        XCTAssertEqual(state.remainingMinutes(for: saved), 160)
        XCTAssertEqual(state, before)
    }

    func testUnusedManualDuplicatesDoNotOverrideOtherLessonSources() throws {
        var web = course(["same", "same"], baseline: 30)
        web.webCourse = .init(packageID: "synthetic", name: "Web lessons", sourceURL: "https://example.com/course",
            fetchedAt: now, expectedOutlines: 1, fetchedOutlines: 1,
            lessons: [0, 1].map { index in
                .init(id: "web-\(index)", name: "Web \(index)", subject: "", stage: "", chapter: "", kind: "video",
                      published: true, durationSeconds: 3600, watchedPercent: index == 0 ? 50 : 0,
                      markedFinished: false, requiresDuration: true)
            }, issues: [])
        let child = course(["first", "second"], baseline: 10)
        var merged = course(["same", "same"], baseline: 10)
        merged.mergedSources = [child]
        var recorded = course(["same", "same"], baseline: 10)
        recorded.type = .recorded
        for original in [web, merged, recorded] {
            var input = PlannerState()
            input.courses = [original]
            let state = try roundTrip(input)
            let saved = try XCTUnwrap(state.courses.first)
            let before = state
            let items = state.lessonWorkItems(for: saved)
            if original.id == web.id {
                XCTAssertEqual(items.map(\.id), ["web-0", "web-1"])
                XCTAssertEqual(items.map(\.remainingMinutes), [30, 60])
                XCTAssertEqual(state.completedMinutes(for: saved), 30)
            } else if original.id == merged.id {
                XCTAssertEqual(Set(items.map(\.id)), ["\(child.id)/first", "\(child.id)/second"])
                XCTAssertEqual(items.map(\.remainingMinutes).sorted(), [50, 60])
                XCTAssertEqual(state.completedMinutes(for: saved), 10)
            } else {
                XCTAssertTrue(items.isEmpty)
                XCTAssertEqual(state.completedMinutes(for: saved), 10)
            }
            XCTAssertEqual(saved.manualLessons, original.manualLessons)
            XCTAssertEqual(state, before)
        }
    }

    func testUniqueIdentitiesKeepCustomOrderAndLessonSpecificProgress() throws {
        var manual = course(["first", "second"], baseline: 10)
        manual.lessonOrder = ["second", "first"]
        let input = try confirmedState(manual, lessonID: "second")
        let state = try roundTrip(input)
        let saved = try XCTUnwrap(state.courses.first)
        let before = state
        let items = state.lessonWorkItems(for: saved)
        XCTAssertEqual(items.map(\.id), ["second", "first"])
        XCTAssertEqual(items.map(\.remainingMinutes), [40, 50])
        XCTAssertEqual(state.completedMinutes(for: saved), 30)
        XCTAssertEqual(state.completions, input.completions)
        XCTAssertEqual(state, before)
    }
}

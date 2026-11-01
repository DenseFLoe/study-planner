import XCTest
import StudyCore
import StudyPersistence
@testable import StudySync

final class ConcurrentEditingTests: XCTestCase {
    func testLocalEditsAndSyncTransactionsKeepEveryAddedCourse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("concurrent.store")
        let baseline = PlannerState()
        try LocalRepository(url: database).save(baseline)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let course = Course(name: "并发课程\(index)", totalMinutes: 60, startDate: Date(), deadline: Date())
                    if index.isMultiple(of: 2) {
                        var edited = baseline
                        edited.courses.append(course)
                        _ = try LocalRepository(url: database).saveChanges(edited, from: baseline)
                    } else {
                        try await SyncDatabase.update(url: database) { state, _ in state.courses.append(course) }
                    }
                }
            }
            try await group.waitForAll()
        }
        let reopened = try LocalRepository(url: database)
        let expected = Set((0..<12).map { "并发课程\($0)" })
        XCTAssertEqual(Set(try reopened.load().courses.map(\.name)), expected)
        XCTAssertEqual(Set(try reopened.loadLedger().materialize().courses.map(\.name)), expected)
    }
}

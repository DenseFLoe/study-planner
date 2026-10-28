import AppKit
import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

@MainActor final class PlaybackSupervisorTests: XCTestCase {
    private final class Repository: PlannerRepository {
        func load() throws -> PlannerState { PlannerState() }
        func save(_ state: PlannerState) throws {}
    }

    private func fixture(starts: [Date]) throws -> (PlannerStore, SupervisedApplication, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Player.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.studyplanner.player"],
                                                       format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        var state = PlannerState()
        let day = Calendar.current.startOfDay(for: Date())
        for (index, start) in starts.enumerated() {
            var course = Course(name: "课程\(index)", totalMinutes: 60, startDate: day, deadline: day)
            course.autoScheduleEnabled = false
            state.courses.append(course)
            state.tasks.append(ScheduledTask(courseID: course.id, start: start, durationMinutes: 1))
        }
        let store = PlannerStore(state: state, repository: Repository(), result: ScheduleEngine().generate(state: state, now: Date()))
        return (store, SupervisedApplication(bundleID: "test.studyplanner.player", name: "Player", path: app.path), root)
    }

    func testAlreadyStartedCourseIsCheckedAndRemindedWithoutOpeningSettings() async throws {
        let (store, app, root) = try fixture(starts: [Date().addingTimeInterval(-2)])
        defer { try? FileManager.default.removeItem(at: root) }
        let checked = expectation(description: "first check and reminder")
        var checks = 0
        let supervisor = PlaybackSupervisor(persistent: false, monitoringEnabled: true, observe: { _ in
            checks += 1
            return .stopped("对应软件尚未打开")
        }, remind: { courseID, _ in
            XCTAssertEqual(courseID, store.state.courses[0].id)
            checked.fulfill()
            return true
        })
        defer { supervisor.stop() }
        XCTAssertTrue(supervisor.setApplication(app, for: store.state.courses[0].id))
        supervisor.start(store: store)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(supervisor.isSupervising(store.state.tasks[0]))
        XCTAssertEqual(supervisor.statuses[store.state.courses[0].id], "对应软件尚未打开")
    }

    func testTimerStartsNextCourseAtBoundaryWithoutAnyView() async throws {
        let boundary = Date().addingTimeInterval(0.7)
        let (store, app, root) = try fixture(starts: [boundary.addingTimeInterval(-60), boundary])
        defer { try? FileManager.default.removeItem(at: root) }
        let checked = expectation(description: "both courses checked")
        checked.expectedFulfillmentCount = 2
        var checks = 0
        let supervisor = PlaybackSupervisor(persistent: false, monitoringEnabled: true, observe: { _ in
            checks += 1; checked.fulfill()
            return .playing("正在播放")
        })
        defer { supervisor.stop() }
        for course in store.state.courses { XCTAssertTrue(supervisor.setApplication(app, for: course.id)) }
        supervisor.start(store: store)
        await fulfillment(of: [checked], timeout: 3)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(supervisor.activeTaskIDs, [store.state.tasks[1].id])
        XCTAssertFalse(supervisor.isSupervising(store.state.tasks[0]))
        XCTAssertTrue(supervisor.isSupervising(store.state.tasks[1]))
    }

    func testPlanChangeRearmsTimerAndCompletionStopsSupervision() async throws {
        let (store, app, root) = try fixture(starts: [Date().addingTimeInterval(300)])
        defer { try? FileManager.default.removeItem(at: root) }
        let checked = expectation(description: "changed plan checked")
        let supervisor = PlaybackSupervisor(persistent: false, monitoringEnabled: true, observe: { _ in
            checked.fulfill(); return .playing("正在播放")
        })
        defer { supervisor.stop() }
        XCTAssertTrue(supervisor.setApplication(app, for: store.state.courses[0].id))
        supervisor.start(store: store)
        await drain()
        XCTAssertTrue(supervisor.activeTaskIDs.isEmpty)
        XCTAssertTrue(store.change(replan: false) { $0.tasks[0].start = Date().addingTimeInterval(0.2) })
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertTrue(supervisor.isSupervising(store.state.tasks[0]))
        XCTAssertTrue(store.change(replan: false) { $0.tasks[0].confirmedAt = Date() })
        await drain()
        XCTAssertTrue(supervisor.activeTaskIDs.isEmpty)
        XCTAssertEqual(supervisor.summary, "等待计划学习时段")
    }

    func testBindingDuringActiveCourseStartsImmediately() async throws {
        let (store, app, root) = try fixture(starts: [Date().addingTimeInterval(-1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let checked = expectation(description: "new binding checked")
        let supervisor = PlaybackSupervisor(persistent: false, monitoringEnabled: true, observe: { _ in
            checked.fulfill(); return .playing("正在播放")
        })
        defer { supervisor.stop() }
        supervisor.start(store: store)
        await drain()
        XCTAssertEqual(supervisor.summary, "未绑定监督软件")
        XCTAssertTrue(supervisor.setApplication(app, for: store.state.courses[0].id))
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertTrue(supervisor.isSupervising(store.state.tasks[0]))
        XCTAssertTrue(supervisor.setApplication(nil, for: store.state.courses[0].id))
        await drain()
        XCTAssertTrue(supervisor.activeTaskIDs.isEmpty)
        XCTAssertEqual(supervisor.summary, "未绑定监督软件")
    }

    func testSleepPausesAndWakeAutomaticallyChecksCurrentCourse() async throws {
        let (store, app, root) = try fixture(starts: [Date().addingTimeInterval(-1)])
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        let supervisor = PlaybackSupervisor(persistent: false, monitoringEnabled: true, observe: { _ in
            checks += 1; return .playing("正在播放")
        })
        defer { supervisor.stop() }
        XCTAssertTrue(supervisor.setApplication(app, for: store.state.courses[0].id))
        supervisor.start(store: store)
        await drain()
        XCTAssertEqual(checks, 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await drain()
        XCTAssertNil(supervisor.nextCheckAt)
        XCTAssertTrue(supervisor.activeTaskIDs.isEmpty)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await drain()
        XCTAssertEqual(checks, 2)
        XCTAssertTrue(supervisor.isSupervising(store.state.tasks[0]))
        supervisor.stop()
        XCTAssertNil(supervisor.nextCheckAt)
        XCTAssertFalse(supervisor.isSupervising(store.state.tasks[0]))
    }

    func testCompletedTaskDoesNotDeliverStaleInFlightReminder() async throws {
        let (store, app, root) = try fixture(starts: [Date().addingTimeInterval(-1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "probe started")
        var finishProbe: CheckedContinuation<PlaybackObservation, Never>?
        var reminders = 0
        let supervisor = PlaybackSupervisor(persistent: false, monitoringEnabled: true, observe: { _ in
            await withCheckedContinuation { continuation in
                finishProbe = continuation
                started.fulfill()
            }
        }, remind: { _, _ in reminders += 1; return true })
        defer { supervisor.stop() }
        XCTAssertTrue(supervisor.setApplication(app, for: store.state.courses[0].id))
        supervisor.start(store: store)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.change(replan: false) { $0.tasks[0].confirmedAt = Date() })
        await drain()
        finishProbe?.resume(returning: .stopped("已暂停"))
        await drain()
        XCTAssertEqual(reminders, 0)
        XCTAssertTrue(supervisor.activeTaskIDs.isEmpty)
    }

    private func drain() async { try? await Task.sleep(for: .milliseconds(100)) }
}

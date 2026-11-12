import XCTest
import StudyCore
import StudyPersistence
@testable import StudySync

private actor CloudPhaseRecorder {
    var phases: [CloudSyncPhase] = []
    func record(_ phase: CloudSyncPhase) { phases.append(phase) }
    func values() -> [CloudSyncPhase] { phases }
}

private actor ArchiveServer: CloudSyncTransport {
    var archive: CloudArchive
    var uploads = 0
    var failUpload = false
    var failDownload = false
    var revision: Int64 = 1
    var editDuringUpload: (@Sendable () async throws -> Void)?
    let identity = UUID().uuidString
    init(_ ledger: SyncLedger) { archive = CloudArchive(ledger: ledger); archive.serverID = identity; archive.revision = 1 }
    func status() async throws -> CloudServerStatus { .init(format: 1, serverID: identity, revision: revision) }
    func upload(_ file: URL) async throws -> CloudServerStatus {
        if failUpload { throw URLError(.networkConnectionLost) }
        uploads += 1
        let incoming = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(Data(contentsOf: file))).validated()
        var ledger = SyncLedger(); try ledger.merge(archive.records); try ledger.merge(incoming.records)
        archive.records = ledger.records.values.sorted { $0.key < $1.key }
        if let edit = editDuringUpload { editDuringUpload = nil; try await edit() }
        return try await status()
    }
    func latest() async throws -> Data {
        if failDownload { return Data("truncated".utf8) }
        return try CloudCompression.gzip(JSONEncoder().encode(archive))
    }
    func fail(_ value: Bool) { failUpload = value }
    func uploadCount() -> Int { uploads }
    func corruptDownload() { failDownload = true }
    func rollback() { revision = 0 }
    func editOnUpload(_ edit: @escaping @Sendable () async throws -> Void) { editDuringUpload = edit }
}
final class CloudSyncClientTests: XCTestCase, @unchecked Sendable {
    func testEndpointMustUseVerifiedHTTPS() throws {
        let placeholder = String(repeating: "x", count: 32)
        XCTAssertNoThrow(try CloudCredentials(endpoint: "https://192.0.2.1:443", token: placeholder))
        for url in ["http://192.0.2.1", "https://name.test/?token=x", "https://USERNAME_PLACEHOLDER:PASSWORD_PLACEHOLDER@name.test", "https://name.test/path"] {
            XCTAssertThrowsError(try CloudCredentials(endpoint: url, token: placeholder))
        }
    }
    func testOfflineMergeRetryAndHotspotCursorIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("local.store"), outbox = root.appendingPathComponent("outbox")
        try await Task.detached {
            let db = try LocalRepository(url: database); var state = PlannerState(); state.settings.availability = []
            state.courses = [Course(name: "Mac", totalMinutes: 60, startDate: Date(), deadline: Date())]
            var ledger = SyncLedger(); ledger.peerCursor = 123; ledger.sentCursor = 456; try db.save(state, ledger: ledger)
        }.value
        var remote = SyncLedger(); var phone = PlannerState(); phone.settings.availability = []
        phone.courses = [Course(name: "Phone", totalMinutes: 60, startDate: Date(), deadline: Date())]; try remote.capture(phone)
        let server = ArchiveServer(remote); await server.fail(true)
        do { _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server); XCTFail("upload should fail") } catch {}
        XCTAssertFalse(try CloudOutbox.files(in: outbox).isEmpty)
        let unchanged = try await SyncDatabase.snapshot(url: database)
        XCTAssertEqual(unchanged.0.courses.count, 1)
        await server.fail(false)
        let transferPhases = CloudPhaseRecorder()
        let outcome = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server) { await transferPhases.record($0) }
        let transferred = await transferPhases.values()
        XCTAssertEqual(transferred, [.checking, .downloading, .uploading, .downloading, .saving])
        XCTAssertEqual(Set(outcome.state.courses.map(\.name)), ["Mac", "Phone"])
        XCTAssertEqual(outcome.ledger.peerCursor, 123); XCTAssertEqual(outcome.ledger.sentCursor, 456)
        XCTAssertTrue(try CloudOutbox.files(in: outbox).isEmpty)
        let checkPhases = CloudPhaseRecorder()
        let unchangedResult = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server) { await checkPhases.record($0) }
        let checked = await checkPhases.values()
        XCTAssertEqual(checked, [.checking, .saving], "An unchanged check must not display an upload or download")
        XCTAssertEqual(unchangedResult.sent, 0)
        XCTAssertEqual(unchangedResult.received, 0)
        let count = await server.uploadCount(); XCTAssertEqual(count, 1, "download must not create an upload loop")
        await server.rollback()
        do { _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server); XCTFail("rollback should stop synchronization") } catch {}
        let retained = try await SyncDatabase.snapshot(url: database); XCTAssertEqual(retained.0.courses.count, 2)
    }
    func testConcurrentLocalEditSurvivesDownloadAndIsPending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("local.store"), outbox = root.appendingPathComponent("outbox")
        try await Task.detached { try LocalRepository(url: database).save(PlannerState()) }.value
        var ledger = SyncLedger(); try ledger.capture(PlannerState()); let server = ArchiveServer(ledger)
        await server.editOnUpload {
            try await Task.detached {
                let repository = try LocalRepository(url: database)
                let baseline = try repository.load()
                var edited = baseline
                edited.courses.append(Course(name: "Edited during transfer", totalMinutes: 10, startDate: Date(), deadline: Date()))
                _ = try repository.saveChanges(edited, from: baseline)
            }.value
        }
        let result = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        XCTAssertEqual(result.state.courses.first?.name, "Edited during transfer")
        XCTAssertEqual(result.ledger.cloudProgress?.uploadedSequence, -1)
        _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        let count = await server.uploadCount(); XCTAssertEqual(count, 2)
    }
    func testHistoricalOutboxIsNotReplayedAgainstCurrentDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("local.store"), outbox = root.appendingPathComponent("outbox")
        let empty = PlannerState()
        try LocalRepository(url: database).save(empty)
        var old = empty, obsolete = SyncLedger(), current = SyncLedger()
        old.courses = [Course(name: "Obsolete queued course", totalMinutes: 60, startDate: Date(), deadline: Date())]
        try obsolete.capture(old); try CloudOutbox.enqueue(obsolete, directory: outbox)
        try current.capture(empty); let server = ArchiveServer(current)
        let result = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        XCTAssertTrue(result.state.courses.isEmpty)
        let uploads = await server.uploadCount(); XCTAssertEqual(uploads, 1)
        XCTAssertTrue(try CloudOutbox.files(in: outbox).isEmpty)
    }
    func testCorruptDownloadPreservesLocalDataAndOutbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("local.store"), outbox = root.appendingPathComponent("outbox")
        try await Task.detached { try LocalRepository(url: database).save(PlannerState()) }.value
        var ledger = SyncLedger(); try ledger.capture(PlannerState()); let server = ArchiveServer(ledger); await server.corruptDownload()
        do { _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server); XCTFail("corrupt download should fail") } catch {}
        XCTAssertFalse(try CloudOutbox.files(in: outbox).isEmpty)
        let retained = try await SyncDatabase.snapshot(url: database); XCTAssertNil(retained.1.cloudProgress)
    }
}

extension CloudSyncClientTests {
    func testCloudDownloadRepairsCompetingPlansAndUploadsRepairOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("plans.store"), outbox = root.appendingPathComponent("outbox")
        let calendar = Calendar.current, now = Date()
        let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var base = PlannerState()
        base.courses = [Course(name: "Concurrent", totalMinutes: 120, startDate: day, deadline: day, minimumBlockMinutes: 0)]
        base.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 660) }
        _ = base.replan(now: now)
        var ledger = SyncLedger(); try ledger.capture(base, now: now.addingTimeInterval(-3))
        var local = base, remote = base, a = ledger, b = ledger
        a.device = "mac"; b.device = "phone"
        local.settings.minimumScheduleUnit = 30
        _ = local.replan(now: now)
        remote.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 780, endMinute: 960) }
        _ = remote.replan(now: now)
        try a.capture(local, now: now.addingTimeInterval(-2))
        try b.capture(remote, now: now.addingTimeInterval(-1))
        try LocalRepository(url: database).save(local, ledger: a)
        let server = ArchiveServer(b)
        let outcome = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        XCTAssertEqual(outcome.state.tasks.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertTrue(outcome.state.tasks.allSatisfy { calendar.component(.hour, from: $0.start) >= 13 })
        XCTAssertEqual(outcome.ledger.cloudProgress?.uploadedSequence, outcome.ledger.sequence, "Repairs are uploaded together with the current snapshot")
        let persisted = try await SyncDatabase.snapshot(url: database)
        XCTAssertEqual(persisted.0.tasks, outcome.state.tasks)
        XCTAssertEqual(try persisted.1.materialize().tasks, outcome.state.tasks)
        _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        let count = await server.uploadCount()
        XCTAssertEqual(count, 1)
    }
}

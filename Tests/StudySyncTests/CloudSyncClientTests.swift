import XCTest
import StudyCore
import StudyPersistence
@testable import StudySync

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
        XCTAssertEqual(try CloudOutbox.files(in: outbox).count, 1)
        let unchanged = try await SyncDatabase.snapshot(url: database)
        XCTAssertEqual(unchanged.0.courses.count, 1)
        await server.fail(false)
        let outcome = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        XCTAssertEqual(Set(outcome.state.courses.map(\.name)), ["Mac", "Phone"])
        XCTAssertEqual(outcome.ledger.peerCursor, 123); XCTAssertEqual(outcome.ledger.sentCursor, 456)
        XCTAssertTrue(try CloudOutbox.files(in: outbox).isEmpty)
        _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
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
            try await SyncDatabase.update(url: database) { state, _ in
                state.courses.append(Course(name: "Edited during transfer", totalMinutes: 10, startDate: Date(), deadline: Date()))
            }
        }
        let result = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        XCTAssertEqual(result.state.courses.first?.name, "Edited during transfer")
        XCTAssertEqual(result.ledger.cloudProgress?.uploadedSequence, -1)
        _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server)
        let count = await server.uploadCount(); XCTAssertEqual(count, 2)
    }
    func testCorruptDownloadPreservesLocalDataAndOutbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("local.store"), outbox = root.appendingPathComponent("outbox")
        try await Task.detached { try LocalRepository(url: database).save(PlannerState()) }.value
        var ledger = SyncLedger(); try ledger.capture(PlannerState()); let server = ArchiveServer(ledger); await server.corruptDownload()
        do { _ = try await CloudSyncClient.run(endpoint: "https://fixture.test", databaseURL: database, outbox: outbox, transport: server); XCTFail("corrupt download should fail") } catch {}
        XCTAssertEqual(try CloudOutbox.files(in: outbox).count, 1)
        let retained = try await SyncDatabase.snapshot(url: database); XCTAssertNil(retained.1.cloudProgress)
    }
}

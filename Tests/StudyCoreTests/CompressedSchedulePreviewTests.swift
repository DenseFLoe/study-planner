import XCTest
@testable import StudyCore

final class CompressedSchedulePreviewTests: XCTestCase {
    func testResultIsBoundedAndOldSettingsDecode() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let course = Course(name: String(repeating: "课", count: 300), totalMinutes: 3000, startDate: now, deadline: now)
        var state = PlannerState(); state.courses = [course]
        let tasks = (0..<3000).map { ScheduledTask(courseID: course.id, start: now.addingTimeInterval(Double($0 * 60)), durationMinutes: 1) }
        let plan = CompressedSchedule(capturedAt: now, courses: [.init(course: course, remainingMinutes: 3000, finish: tasks.last?.end)], tasks: tasks, fixed: [])
        let result = try CompressedSchedulePreview(plan: plan, state: state)
        XCTAssertEqual(result.totalRows, 3000)
        XCTAssertLessThanOrEqual(result.rows.count, 2000)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(result).count, 750_000)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        raw.removeValue(forKey: "compressedSchedulePreview")
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: raw)).compressedSchedulePreview)
    }
    func testCloudPreviewRoundTripAndCrossPlatformFixture() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 8))!
        var state = PlannerState()
        var course = Course(name: "合成课程 / 🐳", totalMinutes: 180, startDate: now, deadline: now)
        course.manualLessons = [.init(id: "a", name: "第一节", durationMinutes: 60), .init(id: "b", name: "第二节", durationMinutes: 120)]
        course.type = .lessonBasedRecorded
        state.courses = [course]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1080) }
        state.fixedEvents = [.init(title: "合成固定事项", startMinute: 600, endMinute: 660, startDate: calendar.startOfDay(for: now), endDate: now, weekdays: [2, 4, 6])]
        let confirmed = ScheduledTask(courseID: course.id, start: now.addingTimeInterval(-86400), durationMinutes: 60, lessonID: "a", lessonName: "第一节")
        state.tasks = [confirmed]
        try state.confirm(taskID: confirmed.id, actualMinutes: 30, now: now, calendar: calendar)
        let original = state
        let plan = try CompressedScheduleEngine(calendar: calendar).calculate(state: state, now: now)
        let preview = try CompressedSchedulePreview(plan: plan, state: state)
        XCTAssertEqual(state, original)
        XCTAssertEqual(preview.finish, plan.finish)
        XCTAssertEqual(preview.sourceSignature, try CompressedSchedulePreview.signature(state))
        var copy = state
        copy.tasks.append(.init(courseID: course.id, start: now, durationMinutes: 30))
        copy.settings.compressedSchedulePreview = preview
        XCTAssertEqual(try CompressedSchedulePreview.signature(copy), preview.sourceSignature)
        copy.courses[0].totalMinutes += 1
        XCTAssertNotEqual(try CompressedSchedulePreview.signature(copy), preview.sourceSignature)
        state.settings.compressedSchedulePreview = preview
        var ledger = SyncLedger(); try ledger.capture(state, now: now)
        let archive = try CloudArchive(ledger: ledger, now: now).validated()
        let encoded = try JSONEncoder().encode(archive)
        let restored = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(CloudCompression.gzip(encoded))).validated()
        var merged = SyncLedger(); try merged.merge(restored.records)
        XCTAssertEqual(try merged.materialize().settings.compressedSchedulePreview, preview)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Android/build/tests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = try JSONSerialization.data(withJSONObject: ["state": JSONSerialization.jsonObject(with: JSONEncoder().encode(state)), "preview": JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)), "archiveGzip": CloudCompression.gzip(encoded).base64EncodedString()], options: [.sortedKeys])
        try root.write(to: dir.appendingPathComponent("mac-compressed-preview.json"), options: .atomic)
        try CloudCompression.gzip(encoded).write(to: dir.appendingPathComponent("mac-compressed-preview.json.gz"), options: .atomic)
    }
}

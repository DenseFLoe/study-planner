import XCTest
@testable import StudyCore
@testable import StudyPersistence

final class DailyConsequenceRepositoryTests: XCTestCase {
    func testJournalAndActualStudyDatesSurviveReloadWithPrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let calendar = Calendar.current, now = calendar.startOfDay(for: Date()).addingTimeInterval(8 * 3600)
        var state = PlannerState()
        state.courses = [.init(name: "模拟课程", totalMinutes: 120, startDate: now, deadline: now.addingTimeInterval(86400))]
        let plan = state.replan(now: now)
        try state.confirm(taskID: plan.tasks[0].id, actualMinutes: 30, now: now)
        let entry = try DailyConsequenceAnalyzer().capture(state: state, result: state.replan(now: now), now: now, warningMinutes: 480)
        var journal = DailyConsequenceJournal(); journal.days = [entry]
        let writer = DailyConsequenceRepository(url: url)
        try await writer.save(journal, sequence: 1)
        let reader = DailyConsequenceRepository(url: url)
        let restored = try await reader.load()
        XCTAssertEqual(restored, journal)
        XCTAssertNotNil(restored.days[0].capturedRecords[0].studyDate)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testOlderSaveCannotOverwriteNewerJournal() async throws {
        let repository = DailyConsequenceRepository(inMemory: true)
        var newer = DailyConsequenceJournal()
        newer.days = [try DailyConsequenceAnalyzer().capture(state: PlannerState(), result: ScheduleEngine().generate(state: PlannerState(), now: Date()), now: Date(), warningMinutes: 480)]
        try await repository.save(newer, sequence: 2)
        try await repository.save(DailyConsequenceJournal(), sequence: 1)
        let saved = try await repository.load()
        XCTAssertEqual(saved.days.count, 1)
    }
    func testCorruptHistoryIsNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let bad = Data("invalid journal".utf8); try bad.write(to: url)
        let repository = DailyConsequenceRepository(url: url)
        do { _ = try await repository.load(); XCTFail("Must reject corrupt history") } catch { }
        do { try await repository.save(DailyConsequenceJournal(), sequence: 1); XCTFail("Must preserve corrupt file") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }
    private func capturedEntry(now: Date, courses: [Course]) throws -> DailyConsequenceDay {
        var state = PlannerState()
        state.courses = courses
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 600) }
        let plan = state.replan(now: now)
        return try DailyConsequenceAnalyzer().capture(state: state, result: plan, now: now, warningMinutes: 480)
    }

    func testDuplicateRootBaselineCoursesRejectWholeJournalAndBlockWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let day = Calendar.current.startOfDay(for: Date()), now = day.addingTimeInterval(8 * 3600)
        let previous = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let course = Course(name: "Synthetic baseline", totalMinutes: 60, startDate: day, deadline: day)
        let valid = try capturedEntry(now: previous, courses: [])
        var invalid = try capturedEntry(now: now, courses: [course])
        invalid.baseline.courses.append(invalid.baseline.courses[0])
        var journal = DailyConsequenceJournal(); journal.days = [valid, invalid]
        let bytes = try JSONEncoder().encode(journal); try bytes.write(to: url)
        for _ in 0..<2 {
            let repository = DailyConsequenceRepository(url: url)
            do { _ = try await repository.load(); XCTFail("Duplicate root identities must reject the whole journal") }
            catch { XCTAssertEqual((error as? CocoaError)?.code, .coderReadCorrupt) }
            do { try await repository.save(DailyConsequenceJournal(), sequence: 1); XCTFail("Read failure must block replacing the original journal") }
            catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testUniqueRootIDsAndSameCourseAcrossDaysRemainValid() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let calendar = Calendar.current, day = calendar.startOfDay(for: Date())
        let now = day.addingTimeInterval(8 * 3600), next = calendar.date(byAdding: .day, value: 1, to: day)!
        let last = calendar.date(byAdding: .day, value: 2, to: day)!
        let first = Course(name: "Synthetic shared course", totalMinutes: 60, startDate: day, deadline: last)
        let second = Course(name: "Synthetic distinct course", totalMinutes: 60, startDate: day, deadline: last)
        var journal = DailyConsequenceJournal()
        journal.days = [try capturedEntry(now: now, courses: [first]),
                        try capturedEntry(now: next.addingTimeInterval(8 * 3600), courses: [first]),
                        try capturedEntry(now: last.addingTimeInterval(8 * 3600), courses: [first, second])]
        let repository = DailyConsequenceRepository(url: url)
        try await repository.save(journal, sequence: 1)
        let bytes = try Data(contentsOf: url)
        let reopened = try await DailyConsequenceRepository(url: url).load()
        XCTAssertEqual(reopened, journal)
        XCTAssertEqual(reopened.days.map { $0.baseline.courses.count }, [1, 1, 2])
        XCTAssertEqual(reopened.days[0].baseline.courses[0].id, reopened.days[1].baseline.courses[0].id)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(try DailyConsequenceAnalyzer().forecast(reopened.days[0], fraction: 1000, horizon: 1))
    }

    func testLargeGoalAndDatedLegacyCreditDoNotAcquireBackupCaps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let calendar = Calendar.current, day = calendar.startOfDay(for: Date())
        let now = day.addingTimeInterval(8 * 3600), later = calendar.date(byAdding: .day, value: 1, to: now)!
        var largeGoal = try capturedEntry(now: now, courses: [])
        largeGoal.goalMinutes = Int.max
        var state = PlannerState()
        let course = Course(name: "Synthetic legacy progress", totalMinutes: 120, startDate: day, deadline: later)
        state.courses = [course]
        state.completions = [.init(courseID: course.id, taskID: UUID(), minutes: Int.max, recordedAt: later, studyDate: later)]
        var ledger = SyncLedger(); try ledger.capture(state)
        _ = try CloudArchive(ledger: ledger).validated()
        let restored = try ledger.materialize(), original = restored
        let plan = ScheduleEngine().generate(state: restored, now: later)
        let legacy = try DailyConsequenceAnalyzer().capture(state: restored, result: plan, now: later, warningMinutes: 480)
        var journal = DailyConsequenceJournal(); journal.days = [largeGoal, legacy]
        let repository = DailyConsequenceRepository(url: url)
        try await repository.save(journal, sequence: 1)
        let bytes = try Data(contentsOf: url)
        let reopened = try await DailyConsequenceRepository(url: url).load()
        XCTAssertEqual(reopened, journal)
        XCTAssertEqual(reopened.days[0].goalMinutes, Int.max)
        XCTAssertEqual(reopened.days[1].capturedRecords[0].minutes, Int.max)
        XCTAssertNotNil(reopened.days[1].capturedRecords[0].studyDate)
        XCTAssertEqual(reopened.days[1].baseline.courses[0].totalMinutes, 0)
        XCTAssertEqual(try DailyConsequenceAnalyzer().forecast(reopened.days[1], fraction: 250, horizon: 1)?.todayMinutes, 2_305_843_009_213_693_951)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(restored, original)
    }

    func testDuplicateRootBaselineTasksRejectWholeJournalAndBlockWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Calendar.current.startOfDay(for: Date()), now = day.addingTimeInterval(8 * 3600)
        var course = Course(name: "Synthetic lesson baseline", totalMinutes: 60, startDate: day, deadline: day)
        course.type = .lessonBasedRecorded; course.minimumBlockMinutes = 30
        course.manualLessons = [.init(id: "a", name: "A", durationMinutes: 30), .init(id: "b", name: "B", durationMinutes: 30)]
        let valid = try capturedEntry(now: now, courses: [course])
        XCTAssertEqual(valid.baseline.tasks.count, 2)
        let first = try XCTUnwrap(valid.baseline.tasks.first), second = try XCTUnwrap(valid.baseline.tasks.last)
        for (index, tasks) in [[first, first], [first, second, first]].enumerated() {
            var invalid = valid; invalid.baseline.tasks = tasks
            var journal = DailyConsequenceJournal(); journal.days = [invalid]
            let url = directory.appendingPathComponent("tasks-\(index).json")
            let bytes = try JSONEncoder().encode(journal); try bytes.write(to: url)
            let repository = DailyConsequenceRepository(url: url)
            do { _ = try await repository.load(); XCTFail("Duplicate task identities must reject the whole journal") }
            catch { XCTAssertEqual((error as? CocoaError)?.code, .coderReadCorrupt) }
            do { try await repository.save(DailyConsequenceJournal(), sequence: 1); XCTFail("Read failure must block replacing the journal") }
            catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testUniqueAndCrossDayTaskIDsAndDuplicateManualFallbackRemainCompatible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let calendar = Calendar.current, day = calendar.startOfDay(for: Date())
        let now = day.addingTimeInterval(8 * 3600)
        var course = Course(name: "Synthetic lesson baseline", totalMinutes: 60, startDate: day, deadline: day)
        course.type = .lessonBasedRecorded; course.minimumBlockMinutes = 30
        course.manualLessons = [.init(id: "a", name: "A", durationMinutes: 30), .init(id: "b", name: "B", durationMinutes: 30)]
        let first = try capturedEntry(now: now, courses: [course])
        XCTAssertEqual(first.baseline.tasks.count, 2)
        var later = first; later.id = UUID()
        later.date = calendar.date(byAdding: .day, value: 1, to: first.date)!
        later.capturedAt = calendar.date(byAdding: .day, value: 1, to: first.capturedAt)!
        var fallback = first; fallback.id = UUID()
        fallback.date = calendar.date(byAdding: .day, value: 2, to: first.date)!
        fallback.capturedAt = calendar.date(byAdding: .day, value: 2, to: first.capturedAt)!
        fallback.baseline.courses[0].manualLessons![1].id = "a"
        var journal = DailyConsequenceJournal(); journal.days = [first, later, fallback]
        let repository = DailyConsequenceRepository(url: url)
        try await repository.save(journal, sequence: 1)
        let bytes = try Data(contentsOf: url)
        let reopened = try await DailyConsequenceRepository(url: url).load()
        XCTAssertEqual(reopened, journal)
        XCTAssertEqual(reopened.days[0].baseline.tasks.map(\.id), reopened.days[1].baseline.tasks.map(\.id))
        XCTAssertNotNil(try DailyConsequenceAnalyzer().forecast(reopened.days[0], fraction: 1000, horizon: 1))
        let preserved = reopened.days[2].baseline
        XCTAssertTrue(preserved.lessonWorkItems(for: preserved.courses[0]).isEmpty)
        XCTAssertEqual(preserved.remainingMinutes(for: preserved.courses[0]), 60)
        XCTAssertNotNil(try DailyConsequenceAnalyzer().forecast(reopened.days[2], fraction: 1000, horizon: 1))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testJavaRootCourseAndTaskIdentityTopologiesMatchLocalJournalValidation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Android/build/tests/daily-journal-identities.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Run ./Android/test.sh to generate journal identity controls") }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let cases = try XCTUnwrap(payload["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 18)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Calendar.current, day = calendar.startOfDay(for: Date())
        for (index, row) in cases.enumerated() {
            let expected = try XCTUnwrap(row["accepted"] as? Bool), name = try XCTUnwrap(row["name"] as? String)
            let identities = try XCTUnwrap(row["days"] as? [[String]]), goal = try XCTUnwrap(row["goal"] as? Int)
            let taskIdentities = row["tasks"] as? [[String]]
            if let taskIdentities { XCTAssertEqual(taskIdentities.count, identities.count, name) }
            var journal = DailyConsequenceJournal()
            for (offset, ids) in identities.enumerated() {
                let date = calendar.date(byAdding: .day, value: offset, to: day)!
                var entry = try capturedEntry(now: date.addingTimeInterval(8 * 3600), courses: [])
                entry.goalMinutes = goal
                entry.baseline.courses = try ids.map { raw in
                    var course = Course(name: "Synthetic topology", totalMinutes: 60, startDate: date, deadline: date)
                    course.id = try XCTUnwrap(UUID(uuidString: raw))
                    return course
                }
                if let ids = taskIdentities?[offset] {
                    entry.baseline.tasks = try ids.enumerated().map { position, raw in
                        let owner = try XCTUnwrap(entry.baseline.courses.first?.id)
                        var task = ScheduledTask(courseID: owner, start: date.addingTimeInterval(Double(480 + position * 45) * 60), durationMinutes: 30)
                        task.id = try XCTUnwrap(UUID(uuidString: raw))
                        return task
                    }
                }
                journal.days.append(entry)
            }
            // Raw load fixtures include31 days; save's existing14-day retention is a separate rule.
            let url = directory.appendingPathComponent("case-\(index).json")
            let bytes = try JSONEncoder().encode(journal); try bytes.write(to: url)
            let repository = DailyConsequenceRepository(url: url)
            do {
                let restored = try await repository.load()
                XCTAssertTrue(expected, name)
                XCTAssertEqual(restored, journal, name)
            } catch {
                XCTAssertFalse(expected, name)
                XCTAssertEqual((error as? CocoaError)?.code, .coderReadCorrupt, name)
                do { try await repository.save(DailyConsequenceJournal(), sequence: 1); XCTFail("Rejected topology must block saving: \(name)") }
                catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission, name) }
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes, name)
        }
    }

}

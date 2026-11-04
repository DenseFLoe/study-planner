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
    func testOversizedHistoryIsRejectedAndNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversized.json")
        try Data([0x7b]).write(to: url)
        let size = UInt64(DailyConsequenceRepository.maximumBytes + 1)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: size); try writer.close()
        let repository = DailyConsequenceRepository(url: url)
        do { _ = try await repository.load(); XCTFail("Oversized history was accepted") } catch { }
        do { try await repository.save(DailyConsequenceJournal(), sequence: 1); XCTFail("Oversized history was overwritten") } catch { }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, size)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        XCTAssertEqual(try reader.read(upToCount: 1), Data([0x7b]))
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

    private func progressBaseline(_ values: [Int], initial: Int = 0, separateCourses: Bool = false) -> PlannerState {
        let day = Calendar.current.startOfDay(for: Date())
        var state = PlannerState()
        state.settings.availability = []
        for index in 0..<max(1, separateCourses ? values.count : 1) {
            var course = Course(name: "Synthetic progress \(index)", totalMinutes: 120, startDate: day, deadline: day)
            course.initialCompletedMinutes = initial
            state.courses.append(course)
        }
        state.completions = values.enumerated().map { index, minutes in
            .init(courseID: state.courses[separateCourses ? index : 0].id, taskID: UUID(), minutes: minutes,
                  recordedAt: day.addingTimeInterval(8 * 3600), studyDate: day)
        }
        return state
    }
    private func mergedProgressBaseline(initial: Int, matchingPrefix: Bool) -> PlannerState {
        var state = progressBaseline([])
        let day = Calendar.current.startOfDay(for: Date())
        var leaf = Course(name: "Synthetic leaf", totalMinutes: 120, startDate: day, deadline: day)
        leaf.initialCompletedMinutes = initial
        var branch = Course(name: "Synthetic branch", totalMinutes: 120, startDate: day, deadline: day)
        branch.type = .lessonBasedRecorded; branch.mergedSources = [leaf]
        state.courses[0].type = .lessonBasedRecorded; state.courses[0].mergedSources = [branch]
        var task = ScheduledTask(courseID: state.courses[0].id, start: day.addingTimeInterval(8 * 3600), durationMinutes: 1)
        task.lessonID = matchingPrefix ? branch.id.uuidString + "/" + leaf.id.uuidString + "/whole" : "unrelated/whole"
        state.tasks = [task]
        state.completions = [.init(courseID: state.courses[0].id, taskID: task.id, minutes: 1, recordedAt: task.start, studyDate: day)]
        return state
    }
    private func assertBaselineProgressLoad(_ baseline: PlannerState, accepted: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        var entry = try capturedEntry(now: Date(), courses: [])
        entry.baseline = baseline
        var journal = DailyConsequenceJournal(); journal.days = [entry]
        let bytes = try JSONEncoder().encode(journal); try bytes.write(to: url)
        for _ in 0..<2 {
            let repository = DailyConsequenceRepository(url: url)
            do {
                let restored = try await repository.load()
                XCTAssertTrue(accepted, "Unrepresentable baseline progress was admitted", file: file, line: line)
                XCTAssertEqual(restored, journal, file: file, line: line)
            } catch {
                XCTAssertFalse(accepted, "Representable baseline progress was rejected", file: file, line: line)
                XCTAssertEqual((error as? CocoaError)?.code, .coderReadCorrupt, file: file, line: line)
            }
            if !accepted {
                do { try await repository.save(DailyConsequenceJournal(), sequence: 1); XCTFail("Rejected progress allowed a write", file: file, line: line) }
                catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission, file: file, line: line) }
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes, file: file, line: line)
        }
    }
    func testBaselineProgressOverflowRejectsWholeJournalAndPreservesFile() async throws {
        try await assertBaselineProgressLoad(progressBaseline([Int.max, 1]), accepted: false)
        try await assertBaselineProgressLoad(progressBaseline([1], initial: Int.max), accepted: false)
        try await assertBaselineProgressLoad(mergedProgressBaseline(initial: Int.max, matchingPrefix: true), accepted: false)
        try await assertBaselineProgressLoad(progressBaseline([-1]), accepted: false)
    }
    func testRepresentableBaselineProgressPreservesExistingPerCourseAndPrefixRules() async throws {
        try await assertBaselineProgressLoad(progressBaseline([Int.max]), accepted: true)
        try await assertBaselineProgressLoad(progressBaseline([Int.max - 1, 1]), accepted: true)
        try await assertBaselineProgressLoad(progressBaseline([1], initial: Int.max - 1), accepted: true)
        try await assertBaselineProgressLoad(progressBaseline([Int.max], initial: Int.min), accepted: true)
        try await assertBaselineProgressLoad(progressBaseline([Int.max, Int.max], separateCourses: true), accepted: true)
        try await assertBaselineProgressLoad(mergedProgressBaseline(initial: Int.max - 1, matchingPrefix: true), accepted: true)
        try await assertBaselineProgressLoad(mergedProgressBaseline(initial: Int.max, matchingPrefix: false), accepted: true)
        var orphan = mergedProgressBaseline(initial: Int.max, matchingPrefix: true); orphan.tasks = []
        try await assertBaselineProgressLoad(orphan, accepted: true)
    }

    func testProgressTotalsRemainIndependentAcrossDailyEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json"), now = Date()
        var first = try capturedEntry(now: now, courses: [])
        first.baseline = progressBaseline([Int.max])
        var later = first; later.id = UUID()
        later.date = Calendar.current.date(byAdding: .day, value: 1, to: first.date)!
        later.capturedAt = Calendar.current.date(byAdding: .day, value: 1, to: first.capturedAt)!
        var journal = DailyConsequenceJournal(); journal.days = [first, later]
        let repository = DailyConsequenceRepository(url: url)
        try await repository.save(journal, sequence: 1)
        let bytes = try Data(contentsOf: url)
        let reopened = try await DailyConsequenceRepository(url: url).load()
        XCTAssertEqual(reopened, journal)
        XCTAssertEqual(reopened.days.map { $0.baseline.completions[0].minutes }, [Int.max, Int.max])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func progressBoundary(_ value: String) throws -> Int {
        switch value {
        case "MAX": return Int.max
        case "MAX_MINUS_ONE": return Int.max - 1
        case "MIN": return Int.min
        default: return try XCTUnwrap(Int(value))
        }
    }
    func testJavaSymbolicProgressBoundariesMatchLocalJournalValidation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Android/build/tests/daily-journal-progress.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Run ./Android/test.sh to generate journal progress controls") }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let cases = try XCTUnwrap(payload["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 12)
        for row in cases {
            let expected = try XCTUnwrap(row["accepted"] as? Bool)
            let initials = try XCTUnwrap(row["initials"] as? [String])
            let groups = try XCTUnwrap(row["records"] as? [[String]])
            XCTAssertEqual(initials.count, groups.count)
            var baseline: PlannerState
            if let merged = row["merged"] as? [String: Any] {
                let initial = try progressBoundary(XCTUnwrap(merged["initial"] as? String))
                let association = try XCTUnwrap(merged["association"] as? String)
                XCTAssertTrue(["matching", "unmatched", "orphan"].contains(association))
                baseline = mergedProgressBaseline(initial: initial, matchingPrefix: association == "matching")
                if association == "orphan" { baseline.tasks = [] }
            } else {
                baseline = progressBaseline(Array(repeating: 0, count: groups.count), separateCourses: true)
                baseline.completions = []
                for (index, values) in groups.enumerated() {
                    baseline.courses[index].initialCompletedMinutes = try progressBoundary(initials[index])
                    let course = baseline.courses[index]
                    for value in values {
                        baseline.completions.append(.init(courseID: course.id, taskID: UUID(), minutes: try progressBoundary(value),
                                                          recordedAt: course.startDate, studyDate: course.startDate))
                    }
                }
            }
            // MAX resolves to each platform's own integer boundary; this does
            // not require Swift to reject representable Int32_MAX + 1 values.
            try await assertBaselineProgressLoad(baseline, accepted: expected)
        }
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

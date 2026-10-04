import XCTest
@testable import StudyCore

final class AppReviewRegressionTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 3))! }

    func testMergedConfirmationJavaRoundTrip() throws {
        let path = URL(fileURLWithPath: "/tmp/study-merge-regression-java.json")
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("Run Android/test.sh after the Swift merge fixture is generated") }
        let ledger = try JSONDecoder().decode(SyncLedger.self, from: Data(contentsOf: path))
        let state = try ledger.materialize(), course = try XCTUnwrap(state.courses.first)
        XCTAssertEqual(state.completedMinutes(for: course), 60)
        XCTAssertEqual(state.completions.count, 1)
        XCTAssertNotNil(state.tasks.first { $0.id == state.completions[0].taskID }?.confirmedAt)
    }

    func testShortLessonCannotFillAnEarlierGapBeforeItsPredecessor() {
        for endMinute in [720, 735] {
            var state = PlannerState()
            state.settings.availability = [.init(weekday: 7, startMinute: 480, endMinute: 540),
                                           .init(weekday: 7, startMinute: 600, endMinute: endMinute)]
            var course = Course(name: "按节课程", totalMinutes: 120, startDate: today, deadline: today)
            course.type = .lessonBasedRecorded
            course.manualLessons = [.init(id: "first", name: "第一节", durationMinutes: 90),
                                    .init(id: "second", name: "第二节", durationMinutes: 30)]
            state.courses = [course]
            let result = ScheduleEngine(calendar: calendar).generate(state: state, now: today.addingTimeInterval(7 * 3600))
            XCTAssertEqual(result.tasks.first?.lessonID, "first")
            XCTAssertEqual(result.tasks.first?.start, today.addingTimeInterval(10 * 3600))
            if endMinute == 735 {
                XCTAssertEqual(result.tasks.map(\.lessonID), ["first", "second"])
                XCTAssertEqual(result.tasks.last?.start, today.addingTimeInterval(11 * 3600 + 45 * 60))
                XCTAssertTrue(result.risks.isEmpty)
            } else {
                XCTAssertEqual(result.tasks.count, 1)
                XCTAssertEqual(result.risks.first?.unscheduledMinutes, 30)
            }
        }
    }

    func testNextDayLessonAndOtherCoursesCanUseEarlierGaps() {
        var state = PlannerState()
        state.settings.availability = (1...7).flatMap { weekday in
            [DailyAvailability(weekday: weekday, startMinute: 480, endMinute: 540),
             DailyAvailability(weekday: weekday, startMinute: 600, endMinute: 720)]
        }
        var course = Course(name: "按节课程", totalMinutes: 120, startDate: today, deadline: today.addingTimeInterval(86400))
        course.type = .lessonBasedRecorded
        course.manualLessons = [.init(id: "first", name: "第一节", durationMinutes: 90),
                                .init(id: "second", name: "第二节", durationMinutes: 30)]
        let other = Course(name: "填补空档", totalMinutes: 30, startDate: today, deadline: today.addingTimeInterval(86400), minimumBlockMinutes: 30)
        state.courses = [course, other]
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: today.addingTimeInterval(7 * 3600))
        let lessons = result.tasks.filter { $0.courseID == course.id }
        XCTAssertEqual(lessons.map(\.lessonID), ["first", "second"])
        XCTAssertTrue(calendar.isDate(lessons[1].start, inSameDayAs: today.addingTimeInterval(86400)))
        XCTAssertTrue(result.tasks.contains { $0.courseID == other.id && $0.start < lessons[0].start })
    }

    func testFragmentRepairAndInterleavingPreserveLessonOrder() {
        var seed: UInt64 = 98761
        func random(_ maximum: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(maximum))
        }
        for scenario in 0..<300 {
            var state = PlannerState()
            state.settings.availability = []
            for weekday in 1...7 {
                var cursor = 480
                for _ in 0..<(2 + random(3)) {
                    let length = 25 + random(100)
                    state.settings.availability.append(.init(weekday: weekday, startMinute: cursor, endMinute: cursor + length))
                    cursor += length + 20 + random(60)
                }
            }
            for index in 0..<(2 + random(3)) {
                let lessons = (0..<(2 + random(5))).map { ManualLesson(id: "L\($0)", name: "L\($0)", durationMinutes: 15 + random(100)) }
                var course = Course(name: "C\(index)", totalMinutes: lessons.reduce(0) { $0 + $1.durationMinutes },
                                    startDate: today.addingTimeInterval(Double(random(3) * 86400)),
                                    deadline: today.addingTimeInterval(Double((3 + random(5)) * 86400)))
                course.type = .lessonBasedRecorded; course.manualLessons = lessons; course.priority = 1 + random(3)
                state.courses.append(course)
            }
            let result = ScheduleEngine(calendar: calendar).generate(state: state, now: today.addingTimeInterval(7 * 3600))
            for course in state.courses {
                let tasks = result.tasks.filter { $0.courseID == course.id }.sorted { $0.start < $1.start }
                let ranks = tasks.compactMap { Int($0.lessonID!.dropFirst()) }
                XCTAssertEqual(ranks, ranks.sorted(), "scenario \(scenario)")
            }
        }
    }

    func testOfflineConfirmationsSurviveMergeRegardlessOfTaskWinnerOrDraftDeletion() throws {
        for macWins in [false, true] {
            for replaceDraft in [false, true] {
                for nested in [false, true] {
                    var base = PlannerState()
                    let sources = ["A", "B", "C"].map { Course(name: $0, totalMinutes: 60, startDate: today, deadline: today.addingTimeInterval(86400)) }
                    base.courses = nested ? sources : Array(sources.prefix(2))
                    let task = ScheduledTask(courseID: sources[0].id, start: today.addingTimeInterval(8 * 3600), durationMinutes: 60)
                    base.tasks = [task]
                    var mac = SyncLedger(), phone = SyncLedger()
                    mac.device = macWins ? "Z-MAC" : "A-MAC"
                    phone.device = macWins ? "A-ANDROID" : "Z-ANDROID"
                    try mac.capture(base); try phone.merge(mac.changes(after: 0))
                    var mergedState = base
                    var merged = try mergedState.mergeCourses(ids: [sources[0].id, sources[1].id], name: "合并")
                    mergedState.removeArchivedCourses()
                    if nested {
                        try mac.capture(mergedState)
                        merged = try mergedState.mergeCourses(ids: [merged.id, sources[2].id], name: "嵌套合并")
                        mergedState.removeArchivedCourses()
                    }
                    if replaceDraft { _ = mergedState.replan(now: today.addingTimeInterval(7 * 3600), calendar: calendar) }
                    try mac.capture(mergedState)
                    var confirmed = try phone.materialize()
                    try confirmed.confirm(taskID: task.id, actualMinutes: 60, now: task.end)
                    try phone.capture(confirmed)
                    let fromMac = mac.changes(after: 0), fromPhone = phone.changes(after: 0)
                    try mac.merge(fromPhone); try phone.merge(fromMac)
                    let recovered = try mac.materialize()
                    XCTAssertEqual(recovered, try phone.materialize())
                    XCTAssertEqual(recovered.completedMinutes(for: merged), 60)
                    XCTAssertEqual(recovered.completions.first?.courseID, merged.id)
                    let history = try XCTUnwrap(recovered.tasks.first { $0.id == task.id })
                    XCTAssertEqual(history.courseID, merged.id)
                    XCTAssertEqual(history.completedMinutes, 60)
                    XCTAssertNotNil(history.confirmedAt)
                    XCTAssertEqual(recovered.lessonWorkItems(for: merged).reduce(0) { $0 + $1.remainingMinutes }, merged.totalMinutes - 60)
                    try mac.capture(recovered); try phone.merge(mac.changes(after: 0))
                    let sequence = mac.sequence
                    try mac.capture(mac.materialize())
                    XCTAssertEqual(sequence, mac.sequence, "Repeated capture must not credit progress twice")
                    XCTAssertEqual(try phone.materialize().completedMinutes(for: merged), 60)
                    if !nested && replaceDraft && macWins {
                        try JSONEncoder().encode(mac).write(to: URL(fileURLWithPath: "/tmp/study-merge-regression-swift.json"))
                    }
                }
            }
        }
    }
}

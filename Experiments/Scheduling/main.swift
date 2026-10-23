// Standalone experiment adapter; compiled with temporary copies of StudyCore.
// No persistence, UI, network, or personal-data access.
import Foundation

nonisolated(unsafe) var experimentDays: [SchedulePreferenceOptimizer.Day] = []
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let epoch = cal.date(from: .init(year: 2026, month: 9, day: 14))!
func date(_ d: Int, _ m: Int = 0) -> Date { epoch.addingTimeInterval(Double((d * 1440 + m) * 60)) }
func minute(_ t: Date) -> Int { Int((t.timeIntervalSince(epoch) / 60).rounded()) }
func spans(_ minutes: Set<Int>) -> [[Int]] {
    var output: [[Int]] = []
    for m in minutes.sorted() {
        if output.last?.last == m { output[output.count - 1][1] = m + 1 }
        else { output.append([m, m + 1]) }
    }
    return output
}
struct Fixture { var name: String; var state: PlannerState; var now: Date = date(0, 480) }
func fixture(_ name: String, _ lengths: [[Int]], _ days: Int, end: Int = 1080) -> Fixture {
    var s = PlannerState()
    s.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: end) }
    s.courses = lengths.enumerated().map { c, values in
        var course = Course(name: "合成科目\(c)", totalMinutes: values.reduce(0, +), startDate: date(0), deadline: date(days - 1))
        course.id = stablePlannerID("experiment-course-\(c)")
        course.type = .lessonBasedRecorded
        course.manualLessons = values.enumerated().map { .init(id: "unit\($0.offset)", name: "合成课节", durationMinutes: $0.element) }
        return course
    }
    return Fixture(name: name, state: s)
}
func priorities(_ names: [ScheduleRule]) -> SchedulePriorities {
    .init(levels: Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element.rawValue, $0.offset + 1) }))
}
func fixtures() -> [Fixture] {
    var out: [Fixture] = []
    out.append(fixture("regression-single-balance", [Array(repeating: 60, count: 10)], 5))
    out.append(fixture("regression-full-days", [[60, 60], [60, 60]], 2, end: 615))
    var boost = fixture("regression-boost-first", [[60, 60, 60, 60]], 4)
    boost.state.courses[0].dailyStudyWeight = 2
    boost.state.settings.schedulePriorities = priorities([.dailyWeight, .balancedLoad, .diversity, .coursePriority])
    out.append(boost)
    boost.name = "regression-balance-first"
    boost.state.settings.schedulePriorities = priorities([.balancedLoad, .dailyWeight, .diversity, .coursePriority])
    out.append(boost)
    var triple = fixture("default-triple-exception", [[60, 60, 60], [60, 60, 60], [60, 60]], 3, end: 750)
    triple.state.courses[0].dailyStudyWeight = 3
    out.append(triple)
    var different = fixture("different-deadlines", [[90, 60], [45, 90, 45], [60, 30, 60]], 3, end: 750)
    different.state.courses[0].deadline = date(0)
    different.state.courses[2].startDate = date(1)
    out.append(different)
    var priority = fixture("priority-first", [[60, 45], [60, 45], [45, 30]], 2, end: 720)
    priority.state.courses[0].priority = 3; priority.state.courses[1].priority = 1
    priority.state.settings.schedulePriorities = priorities([.coursePriority, .diversity, .dailyWeight, .balancedLoad])
    out.append(priority)
    var fractional = fixture("fractional-boost", [[45, 60, 45], [60, 60]], 3, end: 720)
    fractional.state.courses[0].dailyStudyWeight = 1.5
    out.append(fractional)
    var fragments = fixture("fragmented-long-short", [[100, 40], [40, 60], [30, 45]], 2, end: 780)
    fragments.state.fixedEvents = [.init(title: "合成固定事项", startMinute: 590, endMinute: 650, startDate: date(0), endDate: date(1), weekdays: [2, 3])]
    out.append(fragments)
    var floating = fixture("floating-long-competition", [[120, 60], [60, 30]], 2, end: 720)
    var event = FixedEvent(title: "合成浮动事项", startMinute: 480, endMinute: 720, startDate: date(0), endDate: date(0))
    event.floatingDurationMinutes = 75
    floating.state.fixedEvents = [event]
    out.append(floating)
    var multi = fixture("multiple-floating", [[60]], 1, end: 660)
    multi.state.settings.availability = [.init(weekday: 2, startMinute: 600, endMinute: 660)]
    var e1 = FixedEvent(title: "合成浮动甲", startMinute: 540, endMinute: 720, startDate: date(0), endDate: date(0))
    e1.floatingDurationMinutes = 60
    var e2 = FixedEvent(title: "合成浮动乙", startMinute: 540, endMinute: 780, startDate: date(0), endDate: date(0))
    e2.floatingDurationMinutes = 120
    multi.state.fixedEvents = [e1, e2]; out.append(multi)
    var partial = fixture("partial-late-start", [[60, 60, 60], [90, 45]], 3, end: 750)
    var task = ScheduledTask(courseID: partial.state.courses[0].id, start: date(0, 480), durationMinutes: 60, status: .partial, lessonID: "unit0")
    task.completedMinutes = 30; task.confirmedAt = date(0, 525)
    partial.state.tasks = [task]
    partial.state.completions = [.init(courseID: task.courseID, taskID: task.id, minutes: 30, recordedAt: date(0, 525))]
    partial.state.settings.actualStudyStart = date(0, 600); partial.now = date(0, 660)
    out.append(partial)
    var history = fixture("retained-history", [[60, 60], [60, 60]], 2, end: 720)
    history.state.tasks = [.init(courseID: history.state.courses[0].id, start: date(0, 480), durationMinutes: 60, lessonID: "unit0")]
    history.now = date(0, 540); out.append(history)
    out.append(fixture("infeasible-capacity", [[120, 120], [90]], 1, end: 720))
    out.append(fixture("infeasible-contiguous", [[121]], 1, end: 600))
    // Reproducible small cases: all generated cases are retained, including ties/losses.
    var seed: UInt64 = 20261023
    func rand(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
    for i in 0..<8 {
        let lengths = (0..<3).map { _ in (0..<(2 + rand(2))).map { _ in [30, 45, 60, 75, 90][rand(5)] } }
        out.append(fixture("seeded-\(i)", lengths, 3, end: 690 + rand(4) * 30))
    }
    for i in 0..<8 {
        let lengths = (0..<3).map { _ in (0..<(3 + rand(2))).map { _ in [30, 45, 60, 75, 90][rand(5)] } }
        out.append(fixture("seeded-tight-\(i)", lengths, 4, end: 675))
    }
    var dense = fixture("regression-dense-88", [
        [45,20,70,15,35,55,25,60,30,50,40,65,20,55,35,45,30,60,25,50],
        Array(repeating: [150,165,135,180], count: 5).flatMap { $0 },
        Array(repeating: [45,65,35], count: 10).flatMap { $0 },
        Array(repeating: [75,95,55], count: 6).flatMap { $0 }
    ], 21, end: 1200)
    for c in 0..<4 { dense.state.courses[c].deadline = date([7,17,20,20][c]); dense.state.courses[c].priority = c == 0 ? 2 : 3 }
    dense.state.fixedEvents = [
        .init(title: "合成固定甲", startMinute: 540, endMinute: 660, startDate: date(0), endDate: date(20), weekdays: [2,4,6]),
        .init(title: "合成固定乙", startMinute: 480, endMinute: 1020, startDate: date(0), endDate: date(20), weekdays: [3])
    ]; out.append(dense)
    // FloatingPlacement uses UUIDs to break equal-cost ties; make those stable too.
    for i in out.indices {
        for j in out[i].state.fixedEvents.indices {
            out[i].state.fixedEvents[j].id = stablePlannerID("experiment-event-\(out[i].name)-\(j)")
        }
    }
    return out
}
func export(_ f: Fixture) -> [String: Any] {
    let s = f.state, engine = ScheduleEngine(calendar: cal)
    precondition(s.settings.dailyTaskOrders == nil, "Saved drag orders require a separate adapter before importing real states")
    let start = ContinuousClock.now
    let result = engine.generate(state: s, now: f.now)
    let elapsed = start.duration(to: .now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let courses = s.courses.sorted { $0.id.uuidString < $1.id.uuidString }
    let count = Int(courses.map { $0.deadline }.max()!.timeIntervalSince(epoch) / 86400) + 1
    let actual = s.settings.actualStudyStart(on: f.now, calendar: cal)
    let confirmed = s.tasks.compactMap(\.confirmedAt).filter { cal.isDate($0, inSameDayAs: f.now) }.max() ?? epoch
    let floor = minute(max(actual ?? f.now, confirmed))
    let history = s.tasks.filter {
        let replacing = actual != nil && cal.isDate($0.start, inSameDayAs: f.now)
        return $0.planningStart < f.now && (($0.isUnconfirmed && $0.planningEnd <= f.now && !replacing) || $0.completedMinutes > 0)
    }.map { [minute($0.retainedHistoryInterval.start) - 15, minute($0.retainedHistoryInterval.end) + 15] }
    var windows: [[Int]] = [], eventWindows: [[Int]] = [], floats: [[String: Any]] = []
    for d in 0..<count {
        let events = s.fixedEvents.filter { $0.occurs(on: date(d), calendar: cal) }
        var blocked = Set<Int>()
        for e in events where !e.isFloating { blocked.formUnion((d*1440+e.startMinute)..<(d*1440+e.endMinute)) }
        for h in history { blocked.formUnion(h[0]..<h[1]) }
        var available = Set<Int>()
        for a in s.settings.availability where a.weekday == cal.component(.weekday, from: date(d)) {
            available.formUnion((d*1440+a.startMinute)..<(d*1440+a.endMinute))
        }
        available = available.filter { $0 >= floor }; available.subtract(blocked)
        windows += spans(available)
        eventWindows += spans(Set((d*1440)..<((d+1)*1440)).subtracting(blocked))
        for e in events where e.isFloating { floats.append(["start": d*1440+e.startMinute, "end": d*1440+e.endMinute, "minutes": e.occupiedMinutes]) }
    }
    var work: [[String: Any]] = []
    for (c, course) in courses.enumerated() {
        // Exactly reuse production lesson/progress reconciliation, including website/merged data.
        let items = s.lessonWorkItems(for: course).filter { $0.remainingMinutes > 0 }
        precondition(items.reduce(0) { $0 + $1.remainingMinutes } == s.remainingMinutes(for: course))
        for (rank, item) in items.enumerated() { work.append(["course": c, "rank": rank, "lesson": item.id, "minutes": item.remainingMinutes]) }
    }
    let baseline: [[String: Int]] = result.tasks.map { task in
        let c = courses.firstIndex { $0.id == task.courseID }!
        let t = work.firstIndex { $0["course"] as? Int == c && $0["lesson"] as? String == task.lessonID }!
        return ["task": t, "start": minute(task.start)]
    }
    let scoreWindows = experimentDays.map { $0.windows.map { [minute($0.start), minute($0.end)] } }
    return ["name": f.name, "days": count, "floor": floor,
            "courses": courses.map { ["name": $0.name, "start": minute(cal.startOfDay(for: $0.startDate)), "end": minute(cal.startOfDay(for: $0.deadline))+1440, "weight": $0.dailyWeight, "priority": $0.priority] as [String: Any] },
            "rules": s.settings.schedulePriorities.orderedRules.map(\.rawValue), "defaultOrder": s.settings.schedulePriorities.usesDefaultOrder,
            "work": work, "windows": windows, "eventWindows": eventWindows, "floating": floats, "history": history,
            "scoreWindows": scoreWindows, "baseline": baseline, "baselineSeconds": seconds,
            "retainedTasks": s.tasks.count, "retainedCompletions": s.completions.count]
}
let all = fixtures()
if CommandLine.arguments.count == 1 {
    let data = try JSONSerialization.data(withJSONObject: all.map(export), options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    // Oracle: evaluate candidate schedules with an unmodified production score body.
    let requests = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
    var response: [[Double]] = []
    for request in requests {
        let f = all.first { $0.name == request["name"] as? String }!
        _ = ScheduleEngine(calendar: cal).generate(state: f.state, now: f.now)
        let normalized = export(f), work = normalized["work"] as! [[String: Any]]
        let courses = f.state.courses.sorted { $0.id.uuidString < $1.id.uuidString }
        let tasks = (request["plan"] as! [[String: Int]]).map { row -> ScheduledTask in
            let w = work[row["task"]!] , c = w["course"] as! Int
            return ScheduledTask(courseID: courses[c].id, start: date(0, row["start"]!), durationMinutes: w["minutes"] as! Int, lessonID: w["lesson"] as? String)
        }
        let search = SchedulePreferenceOptimizer.Search(tasks: tasks, courses: courses, days: experimentDays, priorities: f.state.settings.schedulePriorities, calendar: cal)
        response.append(search.score(rows: search.initialRows, starts: search.tasks.map(\.start)))
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self))
}

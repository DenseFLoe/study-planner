import SwiftUI
import StudyCore
import StudyPersistence
import StudySync

@MainActor @Observable
final class PlannerStore {
    private(set) var state = PlannerState()
    private(set) var result = ScheduleResultPlaceholder.empty
    private(set) var studyLoad: StudyLoadAssessment?
    var errorMessage: String?
    var pendingEventConflicts: [FixedEventConflict]?
    var isReady = false
    var showDailyReview = false
    var syncBusy = false
    private(set) var orderSaveBusy = false
    @ObservationIgnored private var orderSaveTask: Task<Bool, Never>?
    var syncStatus = "尚未同步"
    var syncLedger = SyncLedger()
    var syncLog: [String] = []
    private var pendingManualSyncs = 0
    private var repository: (any PlannerRepository)?
    private var lastDay = Calendar.current.startOfDay(for: Date())
    private var reviewPrompted = false
    let demo: Bool
    init() {
        demo = CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier == "local.studyplanner.preview"
        do {
            let repo = try LocalRepository(inMemory: demo)
            repository = repo
            state = try repo.load()
            syncLedger = try repo.loadLedger()
            isReady = true
            if demo { loadExample() } else { replan() }
            checkDay()
        } catch { errorMessage = "无法打开本地数据库：\(error.localizedDescription)\n为保护已有数据，未创建替代数据库。" }
    }
    init(state: PlannerState, repository: any PlannerRepository, result: ScheduleResult,
         studyLoad: StudyLoadAssessment? = nil) {
        self.state = state
        self.repository = repository
        self.result = result
        self.studyLoad = studyLoad
        self.demo = true
        self.isReady = true
    }
    var courses: [Course] { state.courses.filter { !$0.isArchived }.sorted { $0.deadline < $1.deadline } }
    func course(_ id: UUID) -> Course? { state.courses.first { $0.id == id } }
    @discardableResult
    func change(replan shouldReplan: Bool = true, _ mutation: (inout PlannerState) throws -> Void) -> Bool {
        guard !syncBusy else { errorMessage = "正在同步，请等待完成后再保存修改。"; return false }
        guard !orderSaveBusy else { errorMessage = "正在保存课程顺序，请稍后再试。"; return false }
        guard let repository, isReady else { return false }
        do {
            var next = state
            try mutation(&next)
            next.removeArchivedCourses()
            let planned = shouldReplan ? next.replan(now: Date()) : ScheduleEngine().generate(state: next, now: Date())
            try repository.save(next)
            state = next; result = planned
            studyLoad = StudyLoadAnalyzer().assess(state: next, now: Date())
            return true
        } catch { errorMessage = "操作未保存：\(error.localizedDescription)"; return false }
    }
    func swapDailyTasks(_ source: UUID, _ target: UUID) {
        guard !syncBusy, !orderSaveBusy, let repository, isReady else { return }
        do {
            let previous = state
            let previousResult = result
            var next = state
            try next.swapDailyTasks(source, target)
            let updated = Dictionary(uniqueKeysWithValues: next.tasks.map { ($0.id, $0) })
            var planned = result
            planned.tasks = planned.tasks.map { updated[$0.id] ?? $0 }.sorted { $0.start < $1.start }
            // Publish inside the caller's animation transaction. Disk/ledger work
            // runs separately, with other writes gated until this snapshot commits.
            state = next
            result = planned
            orderSaveBusy = true
            orderSaveTask = Task { @MainActor in
                defer { orderSaveBusy = false; orderSaveTask = nil }
                do {
                    try await repository.saveForInteraction(next)
                    return true
                } catch {
                    withAnimation(.easeOut(duration: 0.18)) {
                        state = previous
                        result = previousResult
                    }
                    errorMessage = "顺序未保存，已恢复原安排：\(error.localizedDescription)"
                    return false
                }
            }
        } catch { errorMessage = "操作未保存：\(error.localizedDescription)" }
    }
    func waitForOrderSave() async -> Bool { await orderSaveTask?.value ?? true }
    func replan() { change { _ in } }
    func saveActualStudyStart(_ time: Date) -> Bool {
        let calendar = Calendar.current
        let minute = calendar.component(.hour, from: time) * 60 + calendar.component(.minute, from: time)
        return change { try $0.recordActualStudyStart(minute: minute, now: Date(), calendar: calendar) }
    }
    func saveCourse(_ course: Course) -> Bool {
        change { state in
            var saved = course
            if saved.type == .lessonBasedRecorded, saved.lessonOrder == nil {
                if let website = saved.webCourse {
                    saved.lessonOrder = website.lessons.map(\.id)
                    saved.lessonOrderCustomized = false
                } else {
                    saved.lessonOrder = LessonOrdering.intelligent(state.lessonWorkItems(for: saved)).map(\.id)
                }
            }
            if let i = state.courses.firstIndex(where: { $0.id == saved.id }) { state.courses[i] = saved }
            else { state.courses.append(saved) }
        }
    }
    func deleteCourse(_ course: Course) -> Bool {
        change { $0.removeCourse(id: course.id) }
    }
    func saveEvent(_ event: FixedEvent) -> Bool {
        saveEvent(event, skippingDates: [])
    }
    @discardableResult
    func saveEvent(_ event: FixedEvent, skippingDates: Set<Date>) -> Bool {
        guard !syncBusy else { errorMessage = "正在同步，请等待完成后再保存修改。"; return false }
        guard !orderSaveBusy else { errorMessage = "正在保存课程顺序，请稍后再试。"; return false }
        guard let repository, isReady else { return false }
        pendingEventConflicts = nil
        errorMessage = nil
        do {
            var next = state
            try next.updateFixedEvent(event, now: Date(), skippingDates: skippingDates)
            let planned = next.replan(now: Date())
            try repository.save(next)
            state = next; result = planned
            studyLoad = StudyLoadAnalyzer().assess(state: next, now: Date())
            pendingEventConflicts = nil
            errorMessage = nil
            return true
        } catch let PlannerError.fixedConflict(conflicts) {
            pendingEventConflicts = conflicts
            return false
        } catch {
            pendingEventConflicts = nil
            errorMessage = "操作未保存：\(error.localizedDescription)"
            return false
        }
    }
    func deleteEvent(_ event: FixedEvent) {
        change { $0.removeFixedEvent(id: event.id, now: Date()) }
    }
    func setEventSkipped(_ event: FixedEvent, on day: Date, skipped: Bool) {
        change { try $0.setFixedEventSkipped(id: event.id, on: day, skipped: skipped, now: Date()) }
    }
    func confirm(_ task: ScheduledTask, minutes: Int) -> Bool {
        // Preserve active/future full completions; ended tasks may already have
        // replacement work scheduled, which must shrink when progress is credited.
        let now = Date()
        return change(replan: task.confirmationRequiresReplan(actualMinutes: minutes, now: now)) {
            try $0.confirm(taskID: task.id, actualMinutes: minutes, now: now)
        }
    }
    func undoConfirmation(_ task: ScheduledTask) -> Bool {
        // Time, settings, or other confirmations may have changed the plan since
        // completion. Recompute it when restoring the remaining learning amount.
        change {
            try $0.undoConfirmation(taskID: task.id, now: Date())
        }
    }
    var reviewTasks: [ScheduledTask] {
        state.confirmationCandidates(at: Date())
    }
    func checkDay() {
        guard isReady, !syncBusy, !orderSaveBusy else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if today != lastDay { lastDay = today; reviewPrompted = false; replan() }
        if !reviewTasks.isEmpty && !reviewPrompted { showDailyReview = true; reviewPrompted = true }
    }
    func triggerAutomaticSync() {
        guard !demo, isReady, !syncBusy, syncLedger.permitsAutomatic(at: Date()), (try? PairingVault.load()) != nil else { return }
        startSync(automatic: true)
    }
    func startSync(automatic: Bool = false, host: String? = nil, pairingText: String? = nil) {
        guard !demo, isReady else { return }
        if orderSaveBusy {
            Task { if await waitForOrderSave() { startSync(automatic: automatic, host: host, pairingText: pairingText) } }
            return
        }
        if syncBusy {
            if !automatic && pairingText == nil { pendingManualSyncs += 1; syncStatus = "已排队，等待上一次同步释放资源" }
            return
        }
        syncBusy = true; syncStatus = automatic ? "正在检查自动同步条件" : "正在同步"
        Task {
            do {
                let outcome = try await SyncClient.run(automatic: automatic, host: host, pairingText: pairingText) { [weak self] message in
                    await self?.recordSyncLog(message)
                }
                if let outcome {
                    state = outcome.state; syncLedger = outcome.ledger
                    syncStatus = "已同步 · 发送 \(outcome.sent) 条，接收 \(outcome.received) 条 · 网络已关闭"
                } else { syncStatus = "等待下次自动同步（手机窗口与热点连接须同时就绪）" }
            } catch { syncStatus = "同步未完成：" + error.localizedDescription }
            // Recreate the UI repository after background transactions to discard cached models.
            do {
                let (loaded, ledger) = try await SyncDatabase.snapshot()
                let calculated = await Task.detached { ScheduleEngine().generate(state: loaded, now: Date()) }.value
                repository = try LocalRepository(); state = loaded; syncLedger = ledger; result = calculated
                studyLoad = StudyLoadAnalyzer().assess(state: loaded, now: Date())
            } catch { errorMessage = "无法重新读取同步后的本地数据：" + error.localizedDescription; isReady = false }
            syncBusy = false
            if pendingManualSyncs > 0 { pendingManualSyncs -= 1; startSync() }
        }
    }
    private func recordSyncLog(_ message: String) async {
        syncStatus = message
        syncLog.append(Date().formatted(date: .omitted, time: .standard) + " " + message)
        if syncLog.count > 200 { syncLog.removeFirst(syncLog.count - 200) }
        await SyncFileLog.shared.append(message)
    }
    func loadExample() {
        guard state.canLoadExample else { return }
        change { state in
            let cal = Calendar.current, today = cal.startOfDay(for: Date())
            func after(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: today)! }
            var math = Course(name: "考研数学", totalMinutes: 6000, startDate: today, deadline: after(60))
            math.initialCompletedMinutes = 1200; math.color = "blue"; math.notes = "基础复习 · 按章节学习并整理错题"
            var english = Course(name: "英语阅读", totalMinutes: 2400, startDate: today, deadline: after(45), minimumBlockMinutes: 30)
            english.initialCompletedMinutes = 900; english.color = "green"
            var chemistry = Course(name: "化工原理", totalMinutes: 3000, startDate: today, deadline: after(35))
            chemistry.initialCompletedMinutes = 600; chemistry.color = "purple"
            state.courses = [math, english, chemistry]
            state.fixedEvents = [
                .init(title: "学校 · 高等数学", startMinute: 480, endMinute: 580, startDate: today, endDate: after(112), weekdays: [2,4]),
                .init(title: "午饭与休息", startMinute: 720, endMinute: 810, startDate: today, endDate: after(365), weekdays: Set(1...7)),
                .init(title: "补习班", startMinute: 840, endMinute: 960, startDate: today, endDate: after(112), weekdays: [3,5]),
                .init(title: "晚饭", startMinute: 1080, endMinute: 1140, startDate: today, endDate: after(365), weekdays: Set(1...7))]
            var floating = FixedEvent(title: "散步与杂务", startMinute: 1140, endMinute: 1320, startDate: today, endDate: after(60), weekdays: Set(1...7))
            floating.floatingDurationMinutes = 60
            floating.color = "purple"
            state.fixedEvents.append(floating)
        }
    }
}

// Public memberwise initializers are intentionally avoided in core output types.
private enum ScheduleResultPlaceholder {
    static var empty: ScheduleResult { ScheduleEngine().generate(state: PlannerState(), now: Date()) }
}

func hours(_ minutes: Int) -> String {
    let value = Double(minutes) / 60
    return value.formatted(.number.precision(.fractionLength(0...2))) + " h"
}
func clockTime(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
func courseColor(_ key: String) -> Color {
    switch key { case "green": .teal; case "purple": .purple; case "orange": .orange; case "pink": .pink; default: .blue }
}

private actor SyncFileLog {
    static let shared = SyncFileLog()
    func append(_ message: String) {
        guard let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let directory = root.appendingPathComponent("StudyPlanner")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sync.log")
        var data = (try? Data(contentsOf: file)) ?? Data()
        if data.count > 131072 { data = Data() }
        data.append(Data((Date().description + " " + message + "\n").utf8))
        try? data.write(to: file, options: .atomic)
    }
}

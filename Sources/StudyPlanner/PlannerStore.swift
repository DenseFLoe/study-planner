import SwiftUI
import StudyCore
import StudyPersistence
import StudySync
import Network

@MainActor @Observable
final class PlannerStore {
    let assistantWindow = AssistantWindowController()
    let settingsDraft = SettingsDraft()
    private(set) var state = PlannerState() {
        didSet { compressedPlan.update(state: state) }
    }
    let backups: PlannerBackupRepository
    private(set) var backupEntries: [PlannerBackupEntry] = []
    var backupMessage: String?
    private(set) var saveStatus = ""
    let compressedPlan: CompressedScheduleController
    private(set) var result = ScheduleResultPlaceholder.empty
    private(set) var studyLoad: StudyLoadAssessment?
    var errorMessage: String?
    var pendingEventConflicts: [FixedEventConflict]?
    var isReady = false
    var showDailyReview = false
    var syncBusy = false
    @ObservationIgnored private(set) var syncTask: Task<Void, Never>?
    private(set) var orderSaveBusy = false
    @ObservationIgnored private var orderSaveTask: Task<Bool, Never>?
    var syncStatus = "尚未同步"
    var syncLedger = SyncLedger()
    var syncLog: [String] = []
    var cloudStatus = "尚未配置云同步"
    var cloudEndpoint = ""
    var cloudEnabled = false
    @ObservationIgnored private var cloudMonitor: NWPathMonitor?
    @ObservationIgnored private var cloudDeferredTask: Task<Void, Never>?
    private var cloudRequested = false
    private var cloudLastAttempt = Date.distantPast
    private var pendingManualSyncs = 0
    private var localEditRevision = 0
    @ObservationIgnored private var pendingCompressedPreview: CompressedSchedulePreview?
    private var repository: (any PlannerRepository)?
    private var dayRollover = DayRolloverState(savedDay: Calendar.current.startOfDay(for: Date()))
    @ObservationIgnored private(set) var dayRefreshTask: Task<Bool, Never>?
    private var reviewPrompted = false
    let demo: Bool
    let playbackSupervisor: PlaybackSupervisor
    let websiteUpdater: WebsiteCourseUpdater
    init() {
        demo = CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier == "local.studyplanner.preview"
        backups = PlannerBackupRepository(inMemory: demo)
        compressedPlan = CompressedScheduleController(cache: CompressedScheduleRepository(inMemory: demo))
        playbackSupervisor = PlaybackSupervisor(persistent: !demo)
        websiteUpdater = WebsiteCourseUpdater(defaults: demo ? nil : .standard)
        if !demo {
            cloudEndpoint = (try? CloudVault.load(method: CloudVault.selectedMethod))?.endpoint ?? ""
            cloudEnabled = UserDefaults.standard.bool(forKey: CloudOutbox.enabledKey)
        }
        do {
            let repo = try LocalRepository(inMemory: demo)
            repository = repo
            state = try repo.load()
            syncLedger = try repo.loadLedger()
            isReady = true
            Task {
                if demo { await loadExample() } else { await replan() }
                checkDay()
                await refreshBackups()
            }
            compressedPlan.onResolved = { [weak self] in self?.publishCompressedPreview($0) }
            compressedPlan.update(state: state)
        } catch { errorMessage = "无法打开本地数据库：\(error.localizedDescription)\n为保护已有数据，未创建替代数据库。" }
    }
    init(state: PlannerState, repository: any PlannerRepository, result: ScheduleResult,
         studyLoad: StudyLoadAssessment? = nil, backups: PlannerBackupRepository = PlannerBackupRepository(inMemory: true)) {
        self.backups = backups
        self.state = state
        self.repository = repository
        self.result = result
        self.studyLoad = studyLoad
        self.demo = true
        self.compressedPlan = CompressedScheduleController()
        self.playbackSupervisor = PlaybackSupervisor(persistent: false)
        self.websiteUpdater = WebsiteCourseUpdater()
        self.isReady = true
        compressedPlan.update(state: state)
    }
    var courses: [Course] { state.courses.filter { !$0.isArchived }.sorted { $0.deadline < $1.deadline } }
    private func publishCompressedPreview(_ preview: CompressedSchedulePreview) {
        guard !demo, isReady else { return }
        guard !orderSaveBusy else { pendingCompressedPreview = preview; return }
        pendingCompressedPreview = nil
        guard state.settings.compressedSchedulePreview != preview else { return }
        guard compressedPlan.sharedPreview == preview, !compressedPlan.calculating else { return }
        Task {
            guard !orderSaveBusy else { pendingCompressedPreview = preview; return }
            guard compressedPlan.sharedPreview == preview,
                  state.settings.compressedSchedulePreview != preview else { return }
            var next = state
            next.settings.compressedSchedulePreview = preview
            if await commit(next, replan: false, backupReason: nil, clearError: false) { requestCloudSync() }
        }
    }
    func course(_ id: UUID) -> Course? { state.courses.first { $0.id == id } }

    @discardableResult
    func change(replan shouldReplan: Bool = true, now: Date = Date(), _ mutation: (inout PlannerState) throws -> Void) async -> Bool {
        guard !orderSaveBusy else { errorMessage = "正在保存，请稍后再试。"; return false }
        guard isReady else { return false }
        do {
            var next = state
            try mutation(&next)
            return await commit(next, replan: shouldReplan, now: now)
        } catch { errorMessage = "操作未保存：\(error.localizedDescription)"; return false }
    }

    private func commit(_ next: PlannerState, replan: Bool, now: Date = Date(),
                        backupReason: String? = "修改前自动备份", deletedCourseID: UUID? = nil,
                        clearError: Bool = true,
                        backupRestore: PlannerBackupRestore? = nil,
                        courseDeletionDraft: CourseDeletionDraft? = nil,
                        courseMergeDraft: CourseMergeDraft? = nil,
                        fixedEventEdit: FixedEventEdit? = nil,
                        fixedOccurrenceEdit: FixedEventOccurrenceEdit? = nil,
                        lessonOrderDraft: LessonOrderDraft? = nil,
                        preparation: (@Sendable (inout PlannerState) throws -> ScheduleResult)? = nil) async -> Bool {
        guard !orderSaveBusy, let repository, isReady else { return false }
        let previous = state
        orderSaveBusy = true
        saveStatus = replan || preparation != nil ? "正在后台保存并更新课表…" : "正在后台保存…"
        localEditRevision += 1
        if clearError { errorMessage = nil }
        let work = Task { @MainActor in
            defer { finishLocalSave() }
            var attemptedStorage = false
            do {
                let (plannedState, planned) = try await Task.detached(priority: .userInitiated) {
                    var value = next
                    value.removeArchivedCourses()
                    let plan = try preparation?(&value) ?? (replan ? value.replan(now: now) : ScheduleEngine().assessSavedPlan(state: value, now: now))
                    return (value, plan)
                }.value
                // Rejected edits must not rotate away an older recovery point.
                // The business write still requires a successful pre-edit backup.
                if let backupReason {
                    try await backups.save(PlannerBackup(state: previous, reason: backupReason, deletedCourseID: deletedCourseID))
                    await refreshBackups()
                }
                let saved: PlannerState
                attemptedStorage = true
                if let backupRestore {
                    saved = try await repository.restoreBackupForInteraction(backupRestore, from: previous)
                } else if let courseMergeDraft {
                    saved = try await repository.mergeCoursesForInteraction(courseMergeDraft, from: previous, now: now)
                } else if let courseDeletionDraft {
                    saved = try await repository.deleteCourseForInteraction(courseDeletionDraft, from: previous, now: now)
                } else if let fixedEventEdit {
                    saved = try await repository.saveFixedEventForInteraction(fixedEventEdit,
                                                                             from: previous, now: now)
                } else if let fixedOccurrenceEdit {
                    saved = try await repository.saveFixedOccurrenceForInteraction(fixedOccurrenceEdit, from: previous, now: now)
                } else if let lessonOrderDraft {
                    saved = try await repository.saveLessonOrderForInteraction(lessonOrderDraft,
                                                                              from: previous, now: now)
                } else {
                    saved = try await repository.saveChangesForInteraction(plannedState, from: previous)
                }
                let (assessment, load) = await Task.detached(priority: .userInitiated) {
                    (saved == plannedState ? planned : ScheduleEngine().assessSavedPlan(state: saved, now: now),
                     StudyLoadAnalyzer().assess(state: saved, now: now))
                }.value
                state = saved; result = assessment; studyLoad = load
                didSaveLocalEdit()
                return true
            } catch let PlannerError.fixedConflict(conflicts) {
                pendingEventConflicts = conflicts
                return false
            } catch {
                // A conflicting sync may already be on disk while the editor's
                // displayed state is still old. Keep its draft and refresh only
                // the store so explicit Reload can start from that latest data.
                let needsLatestState = (lessonOrderDraft != nil && error is LessonOrderEditError)
                    || (attemptedStorage && (error is ConfirmationEditError
                        || error is CourseEditError || error is FixedEventEditError
                        || error is CourseMergeError || error is CourseDeletionError || error is SettingsEditError || error is PlannerBackupRestoreError))
                if needsLatestState,
                   let latest = try? repository.load() {
                    let (assessment, load) = await Task.detached(priority: .userInitiated) {
                        (ScheduleEngine().assessSavedPlan(state: latest, now: now),
                         StudyLoadAnalyzer().assess(state: latest, now: now))
                    }.value
                    state = latest; result = assessment; studyLoad = load
                    if let local = repository as? LocalRepository, let ledger = try? local.loadLedger() { syncLedger = ledger }
                }
                if clearError || errorMessage == nil { errorMessage = "操作未保存：\(error.localizedDescription)" }
                return false
            }
        }
        orderSaveTask = work
        return await work.value
    }

    private func finishLocalSave() {
        orderSaveBusy = false; orderSaveTask = nil; saveStatus = ""
        if let preview = pendingCompressedPreview { publishCompressedPreview(preview) }
    }

    func swapDailyTasks(_ source: UUID, _ target: UUID) {
        guard !orderSaveBusy, let repository, isReady else { return }
        do {
            let previous = state
            let previousResult = result
            let draft = try DailyTaskSwapDraft(state: state, sourceID: source, targetID: target)
            let next = draft.preview
            let updated = Dictionary(uniqueKeysWithValues: next.tasks.map { ($0.id, $0) })
            var planned = result
            planned.tasks = planned.tasks.map { updated[$0.id] ?? $0 }.sorted { $0.start < $1.start }
            // Publish inside the caller's animation transaction. Disk/ledger work
            // runs separately, with other writes gated until this snapshot commits.
            state = next
            result = planned
            localEditRevision += 1
            orderSaveBusy = true
            errorMessage = nil
            saveStatus = "正在后台保存课程顺序…"
            orderSaveTask = Task { @MainActor in
                defer { finishLocalSave() }
                do {
                    try await backups.save(PlannerBackup(state: previous, reason: "调整顺序前"))
                    await refreshBackups()
                    let saved = try await repository.saveDailyTaskSwapForInteraction(draft, from: previous)
                    state = saved
                    if saved != next {
                        let (assessment, load) = await Task.detached(priority: .userInitiated) {
                            (ScheduleEngine().assessSavedPlan(state: saved, now: Date()), StudyLoadAnalyzer().assess(state: saved, now: Date()))
                        }.value
                        result = assessment; studyLoad = load
                    }
                    didSaveLocalEdit()
                    return true
                } catch {
                    var restored = previous, restoredResult = previousResult, restoredLoad = studyLoad
                    if error is DailyTaskSwapError || error is DailyTaskOrderError || error is ImmediateStudyError,
                       let latest = try? repository.load() {
                        let (assessment, load) = await Task.detached(priority: .userInitiated) {
                            (ScheduleEngine().assessSavedPlan(state: latest, now: Date()), StudyLoadAnalyzer().assess(state: latest, now: Date()))
                        }.value
                        restored = latest; restoredResult = assessment; restoredLoad = load
                        if let local = repository as? LocalRepository, let ledger = try? local.loadLedger() { syncLedger = ledger }
                    }
                    withAnimation(.easeOut(duration: 0.18)) {
                        state = restored
                        result = restoredResult
                        studyLoad = restoredLoad
                    }
                    localEditRevision += 1
                    errorMessage = "顺序未保存：\(error.localizedDescription)"
                    return false
                }
            }
        } catch { errorMessage = "操作未保存：\(error.localizedDescription)" }
    }
    func waitForOrderSave() async -> Bool {
        if let dayRefreshTask, !(await dayRefreshTask.value) { return false }
        while let task = orderSaveTask { if !(await task.value) { return false } }
        return true
    }
    func replan() async { await change { _ in } }
    @discardableResult
    func saveStudySettings(_ edited: AppSettings, from baseline: AppSettings, now: Date = Date()) async -> Bool {
        await change(now: now) { state in
            let merged = try edited.mergingSettingsDraft(from: baseline, into: state.settings)
            state.updateStudySettings(merged, now: now)
        }
    }
    @discardableResult
    func studyImmediately(courseID: UUID, lessonID: String? = nil, now: Date = Date()) async -> Bool {
        await commit(state, replan: true, now: now) {
            try $0.studyImmediately(courseID: courseID, lessonID: lessonID, now: now)
        }
    }
    @discardableResult
    func continueStudying(on day: Date, now: Date = Date()) async -> Bool {
        await commit(state, replan: true, now: now) {
            try $0.continueStudying(on: day, now: now)
        }
    }
    func setDailyWeight(_ weight: Double, for courseID: UUID) async {
        await change { state in
            guard let index = state.courses.firstIndex(where: { $0.id == courseID }) else { return }
            state.courses[index].dailyStudyWeight = weight
        }
    }
    func saveActualStudyStart(_ time: Date) async -> Bool {
        let calendar = Calendar.current
        let minute = calendar.component(.hour, from: time) * 60 + calendar.component(.minute, from: time)
        return await change { try $0.recordActualStudyStart(minute: minute, now: Date(), calendar: calendar) }
    }
    func saveCourse(_ course: Course, from baseline: Course? = nil) async -> Bool {
        do {
            let resolved = try resolvedCourseDraft(course, from: baseline)
            let needsReplan = self.course(course.id).map { !resolved.hasSameSchedulingInputs(as: $0) } ?? true
            return await change(replan: needsReplan) { try $0.updateCourse(resolved) }
        } catch { errorMessage = "操作未保存：\(error.localizedDescription)"; return false }
    }
    @discardableResult
    func saveLessonOrder(_ draft: LessonOrderDraft, now: Date = Date()) async -> Bool {
        await commit(state, replan: true, now: now, lessonOrderDraft: draft) {
            try draft.apply(to: &$0)
            return $0.replan(now: now)
        }
    }
    func resolvedCourseDraft(_ edited: Course, from baseline: Course?) throws -> Course {
        guard let baseline else { return edited }
        guard let current = course(edited.id) else { throw CourseEditError.removed }
        return try edited.mergingDraft(from: baseline, into: current)
    }
    func mergeCourses(_ draft: CourseMergeDraft, now: Date = Date()) async -> Bool {
        await commit(state, replan: true, now: now, backupReason: "合并课程前", courseMergeDraft: draft) {
            try draft.apply(to: &$0)
            $0.removeArchivedCourses()
            return $0.replan(now: now)
        }
    }
    func deleteCourse(_ course: Course) async -> Bool {
        await deleteCourse(CourseDeletionDraft(reviewed: course, state: state))
    }
    func deleteCourse(_ draft: CourseDeletionDraft) async -> Bool {
        let now = Date()
        return await commit(state, replan: true, now: now, backupReason: "删除课程前",
                            deletedCourseID: draft.course.id, courseDeletionDraft: draft) {
            try draft.apply(to: &$0)
            return $0.replan(now: now)
        }
    }
    @discardableResult
    func saveEvent(_ event: FixedEvent, from baseline: FixedEvent? = nil, skippingDates: Set<Date> = [],
                   skippingExistingDates: Set<Date> = [], reviewedConflicts: [FixedEventConflict]? = nil) async -> Bool {
        let edit = FixedEventEdit(event: event, baseline: baseline, skippingDates: skippingDates,
                                  skippingExistingDates: skippingExistingDates, reviewedConflicts: reviewedConflicts)
        pendingEventConflicts = nil
        let now = Date()
        if reviewedConflicts != nil {
            // A previous transaction may have refreshed the review while the
            // displayed state still lags behind sync. Validate choices against
            // the repository's latest state, not that older UI snapshot.
            return await commit(state, replan: false, now: now, fixedEventEdit: edit)
        }
        return await commit(state, replan: true, now: now, fixedEventEdit: edit) {
            try edit.apply(to: &$0, now: now)
            return $0.replan(now: now)
        }
    }
    @discardableResult
    func deleteEvent(_ event: FixedEvent) async -> Bool {
        await change { try $0.removeFixedEvent(reviewed: event) }
    }
    func setEventSkipped(_ event: FixedEvent, on day: Date, skipped: Bool) async {
        let saved = await saveEventOccurrence(.init(reviewed: event, on: day, skipped: skipped))
        if !saved, let conflicts = pendingEventConflicts, !conflicts.isEmpty {
            errorMessage = "本日安排未恢复：" + PlannerError.fixedConflict(conflicts).localizedDescription
            pendingEventConflicts = nil
        }
    }
    func restoreEventOccurrence(_ event: FixedEvent, on day: Date,
                                reviewedConflicts: [FixedEventConflict]? = nil) async -> Bool {
        await saveEventOccurrence(.init(reviewed: event, on: day, skipped: false, reviewedConflicts: reviewedConflicts))
    }
    private func saveEventOccurrence(_ edit: FixedEventOccurrenceEdit) async -> Bool {
        pendingEventConflicts = nil
        let now = Date()
        if edit.reviewedConflicts != nil {
            // A refreshed review may already describe newer on-disk occupants
            // than the UI snapshot. Validate at the transaction boundary.
            return await commit(state, replan: false, now: now, fixedOccurrenceEdit: edit)
        }
        return await commit(state, replan: true, now: now, fixedOccurrenceEdit: edit) {
            try edit.apply(to: &$0, now: now)
            return $0.replan(now: now)
        }
    }
    func confirm(_ task: ScheduledTask, minutes: Int, studyDate: Date? = nil, now: Date = Date()) async -> Bool {
        await change(replan: task.confirmationRequiresReplan(actualMinutes: minutes, now: now), now: now) {
            try $0.confirm(reviewed: task, actualMinutes: minutes, now: now, studyDate: studyDate)
        }
    }
    func undoConfirmation(_ task: ScheduledTask) async -> Bool {
        await change { try $0.undoConfirmation(reviewed: task, now: Date()) }
    }

    func refreshBackups() async {
        do {
            backupEntries = try await backups.entries()
            let unreadable = await backups.unreadableCount
            backupMessage = unreadable > 0 ? "有 \(unreadable) 份备份无法读取，已保留原文件，其他备份仍可使用。" : nil
        }
        catch { backupMessage = "无法读取自动备份：" + error.localizedDescription }
    }
    var latestDeletedCourse: PlannerBackupEntry? {
        backupEntries.first { entry in entry.deletedCourseID.map { course($0) == nil } == true }
    }
    func createBackup() async {
        guard !orderSaveBusy, isReady else { return }
        let snapshot = PlannerBackup(state: state, reason: "手动备份")
        orderSaveBusy = true; saveStatus = "正在创建备份…"
        let work = Task { @MainActor in
            defer { finishLocalSave() }
            do {
                try await backups.save(snapshot)
                await refreshBackups()
                return true
            } catch { backupMessage = "备份失败：" + error.localizedDescription; return false }
        }
        orderSaveTask = work
        _ = await work.value
    }
    func restoreBackup(_ backup: PlannerBackup, from reviewedState: PlannerState) async -> Bool {
        guard !syncBusy, !orderSaveBusy else { errorMessage = "请等待当前保存或同步完成后再恢复。"; return false }
        guard state == reviewedState else {
            errorMessage = "日程在核对备份期间已有更新，未执行恢复。请重新选择备份并核对最新记录。"
            return false
        }
        let restore = PlannerBackupRestore(backup: backup, reviewedState: reviewedState)
        return await commit(backup.state, replan: false, backupReason: "恢复备份前", backupRestore: restore) { state in
            _ = try backup.validated()
            return ScheduleEngine().assessSavedPlan(state: state, now: Date())
        }
    }
    func undoCourseDeletion(_ id: UUID) async -> Bool {
        guard !orderSaveBusy else { return false }
        do {
            let backup = try await backups.load(id)
            return await change { try $0.restoreDeletedCourse(from: backup) }
        } catch { errorMessage = "无法撤销删除：" + error.localizedDescription; return false }
    }
    var reviewTasks: [ScheduledTask] {
        state.confirmationCandidates(at: Date())
    }
    func checkDay(now: Date = Date(), uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        guard isReady, !orderSaveBusy, dayRefreshTask == nil else { return }
        let today = Calendar.current.startOfDay(for: now)
        if dayRollover.isDue(day: today, uptime: uptime()) {
            dayRefreshTask = Task { @MainActor in
                defer { dayRefreshTask = nil }
                let saved = await change(now: now, { _ in })
                if saved {
                    dayRollover.succeeded(day: today); reviewPrompted = false
                    promptDailyReview(at: now)
                } else { dayRollover.failed(day: today, uptime: uptime()) }
                return saved
            }
        } else { promptDailyReview(at: now) }
    }
    private func promptDailyReview(at now: Date) {
        if !state.confirmationCandidates(at: now).isEmpty && !reviewPrompted {
            showDailyReview = true; reviewPrompted = true
        }
    }
    func triggerAutomaticSync() {
        guard !demo, isReady, !syncBusy, syncLedger.permitsAutomatic(at: Date()), (try? PairingVault.load()) != nil else { return }
        startSync(automatic: true)
    }
    func startCloudMonitoring() {
        guard !demo, cloudMonitor == nil else { return }
        let monitor = NWPathMonitor(); cloudMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor [weak self] in self?.requestCloudSync() } }
        }
        monitor.start(queue: DispatchQueue(label: "studyplanner-cloud-network"))
    }
    func pollCloudIfDue() {
        guard Date().timeIntervalSince(cloudLastAttempt) >= 3600 else { return }
        requestCloudSync()
    }
    @discardableResult
    func configureCloud(credentials: CloudCredentials?, method: CloudConnectionMethod, enabled: Bool) -> Bool {
        guard !demo, !syncBusy, !orderSaveBusy else { return false }
        do {
            if enabled {
                guard let credentials, credentials.method == method else { throw ClientError.message("请先填写所选方式的云同步配置。") }
                try CloudVault.save(credentials); cloudEndpoint = credentials.endpoint
            }
            CloudVault.selectedMethod = method
            UserDefaults.standard.set(enabled, forKey: CloudOutbox.enabledKey); cloudEnabled = enabled
            cloudStatus = enabled ? "配置已保存，准备同步" : "云同步已暂停，本地数据和待传文件已保留"
            if enabled {
                Task {
                    do {
                        try await CloudSyncClient.resetProgress()
                        requestCloudSync(manual: true)
                    } catch { cloudStatus = "配置已保存，重置同步状态失败，请重试" }
                }
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func requestCloudSync(manual: Bool = false) {
        guard !demo, isReady, cloudEnabled else { return }
        if orderSaveBusy { Task { if await waitForOrderSave() { requestCloudSync(manual: manual) } }; return }
        if syncBusy { cloudRequested = true; return }
        if !manual && Date().timeIntervalSince(cloudLastAttempt) < 2 {
            if cloudDeferredTask == nil {
                cloudDeferredTask = Task {
                    try? await Task.sleep(for: .seconds(2)); cloudDeferredTask = nil
                    if !Task.isCancelled { requestCloudSync(manual: true) }
                }
            }
            return
        }
        cloudDeferredTask?.cancel(); cloudDeferredTask = nil
        cloudRequested = false; cloudLastAttempt = Date()
        beginCloudSync()
    }
    func beginCloudSync(
        operation: @escaping @Sendable () async throws -> SyncOutcome = {
            guard let credentials = try CloudVault.load(method: CloudVault.selectedMethod) else { throw ClientError.message("请先配置云同步服务器。") }
            return try await CloudSyncClient.run(credentials: credentials)
        },
        snapshot: @escaping @Sendable () async throws -> (PlannerState, SyncLedger) = { try await SyncDatabase.snapshot() }
    ) {
        guard !syncBusy else { return }
        syncBusy = true; cloudStatus = "正在上传完整课表并获取合并结果…"
        syncTask = Task {
            defer { finishSync() }
            do {
                // Keychain access, archive work and SSH teardown must not inherit
                // the main actor from the UI task.
                let outcome = try await Task.detached(priority: .userInitiated, operation: operation).value
                cloudStatus = "已同步 · 云端版本 \(outcome.ledger.cloudProgress?.revision ?? 0) · \(Date().formatted(date: .omitted, time: .shortened))"
            } catch { cloudStatus = "云同步未完成，待传数据已保留：" + error.localizedDescription }
            do {
                try await refreshAfterSync(snapshot: snapshot)
            } catch { errorMessage = "无法读取本地日程：" + error.localizedDescription; isReady = false }
        }
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
        syncTask = Task {
            defer { finishSync() }
            do {
                let outcome = try await SyncClient.run(automatic: automatic, host: host, pairingText: pairingText) { [weak self] message in
                    await self?.recordSyncLog(message)
                }
                if let outcome {
                    syncStatus = "已同步 · 发送 \(outcome.sent) 条，接收 \(outcome.received) 条 · 网络已关闭"
                } else { syncStatus = "等待下次自动同步（手机窗口与热点连接须同时就绪）" }
            } catch { syncStatus = "同步未完成：" + error.localizedDescription }
            // Refresh cached UI models after background transactions.
            do {
                try await refreshAfterSync()
            } catch { errorMessage = "无法重新读取同步后的本地数据：" + error.localizedDescription; isReady = false }
        }
    }
    private func refreshAfterSync(
        snapshot: @escaping @Sendable () async throws -> (PlannerState, SyncLedger) = { try await SyncDatabase.snapshot() }
    ) async throws {
        while true {
            _ = await waitForOrderSave()
            let revision = localEditRevision
            let (loaded, ledger, calculated, load) = try await Task.detached(priority: .userInitiated) {
                let (loaded, ledger) = try await snapshot()
                var state = loaded
                let now = Date()
                // A peer may have regenerated its drafts without the Mac-only request.
                // Publish the requested plan in the task list as well as the assessment.
                let calculated = state.settings.immediateStudy == nil
                    ? ScheduleEngine().assessSavedPlan(state: state, now: now) : state.replan(now: now)
                return (state, ledger, calculated,
                        StudyLoadAnalyzer().assess(state: state, now: now))
            }.value
            // An edit can finish while the snapshot or calculations are running.
            // Re-read instead of publishing a snapshot older than that edit.
            guard revision == localEditRevision, !orderSaveBusy else { continue }
            (repository as? LocalRepository)?.discardCachedModels()
            state = loaded; syncLedger = ledger; result = calculated; studyLoad = load
            return
        }
    }
    private func didSaveLocalEdit() {
        localEditRevision += 1
        if syncBusy { cloudRequested = true }
    }
    private func finishSync() {
        syncTask = nil; syncBusy = false
        if let preview = pendingCompressedPreview ?? compressedPlan.sharedPreview { publishCompressedPreview(preview) }
        if pendingManualSyncs > 0 { pendingManualSyncs -= 1; startSync() }
        else if cloudRequested { requestCloudSync(manual: true) }
    }
    private func recordSyncLog(_ message: String) async {
        syncStatus = message
        syncLog.append(Date().formatted(date: .omitted, time: .standard) + " " + message)
        if syncLog.count > 200 { syncLog.removeFirst(syncLog.count - 200) }
        await SyncFileLog.shared.append(message)
    }
    func loadExample() async {
        guard state.canLoadExample else { return }
        await change { state in
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

import AppKit
import Observation
import StudyCore
import UserNotifications

/// Mac-only preferences, deliberately kept outside PlannerState and all sync archives.
@MainActor @Observable final class PlaybackSupervisor {
    private struct Configuration: Codable {
        var applications: [String: SupervisedApplication] = [:]
        var audioAuthorized: Set<String> = []
    }
    private struct Session {
        var taskIDs: Set<UUID>
        var lastCheck = Date.distantPast
        var unknowns = 0
    }
    static let checkInterval: TimeInterval = 60
    private static let preferenceKey = "macPlaybackSupervision.v1"
    private var configuration = Configuration()
    let reminderSound: SupervisionSoundSettings
    private(set) var statuses: [UUID: String] = [:]
    private(set) var summary = "未绑定监督软件"
    private(set) var storageMessage: String?
    private(set) var permissionMessage = "首次绑定时申请通知及检测权限。"
    private(set) var authorizing = false
    /// The tasks the last tick actually supervised. Empty while supervision is
    /// stopped, suspended or authorizing, so the daily timeline never shows a
    /// stale "supervising" label.
    private(set) var activeTaskIDs: Set<UUID> = []
    @ObservationIgnored private weak var store: PlannerStore?
    private(set) var nextCheckAt: Date?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var observationToken = UUID()
    @ObservationIgnored private var sessions: [UUID: Session] = [:]
    @ObservationIgnored private var lastUnavailableReminders: [UUID: Date] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var lastTick = Date.distantPast
    @ObservationIgnored private var verifiedAudioApps: Set<String> = []
    @ObservationIgnored private var configurationWritable = true
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private let monitoringEnabled: Bool
    @ObservationIgnored private let observationOverride: (@MainActor (SupervisedApplication) async -> PlaybackObservation)?
    @ObservationIgnored private let reminderOverride: (@MainActor (UUID, String) async -> Bool)?

    init(persistent: Bool = true, monitoringEnabled: Bool? = nil,
         observe: (@MainActor (SupervisedApplication) async -> PlaybackObservation)? = nil,
         remind: (@MainActor (UUID, String) async -> Bool)? = nil) {
        self.persistent = persistent
        self.reminderSound = SupervisionSoundSettings(defaults: persistent ? .standard : nil)
        self.monitoringEnabled = monitoringEnabled ?? persistent
        self.observationOverride = observe
        self.reminderOverride = remind
        if persistent, let data = UserDefaults.standard.data(forKey: Self.preferenceKey) {
            do { configuration = try JSONDecoder().decode(Configuration.self, from: data) }
            catch { configurationWritable = false; storageMessage = "软件绑定读取失败；原数据未覆盖，请重新启动后检查。" }
        }
        if hasBindings { summary = "等待计划学习时段" }
    }

    var hasBindings: Bool { !configuration.applications.isEmpty }
    func application(for courseID: UUID) -> SupervisedApplication? { configuration.applications[courseID.uuidString] }

    /// Whether this task's course is being supervised right now. Confirming the
    /// task, rebinding its course or moving its time range makes it false without
    /// waiting for the next tick.
    func isSupervising(_ task: ScheduledTask, now: Date = Date()) -> Bool {
        guard activeTaskIDs.contains(task.id), running, !suspended, !authorizing else { return false }
        guard task.isUnconfirmed, task.start <= now, now < task.end else { return false }
        guard application(for: task.courseID) != nil else { return false }
        return store?.course(task.courseID)?.isArchived == false
    }

    @discardableResult
    func setApplication(_ application: SupervisedApplication?, for courseID: UUID) -> Bool {
        if self.application(for: courseID) == application { return true }
        guard configurationWritable else { return false }
        storageMessage = nil
        if let application {
            guard !application.bundleID.isEmpty, application.bundleID != Bundle.main.bundleIdentifier,
                  let selected = Bundle(url: URL(fileURLWithPath: application.path)),
                  selected.bundleIdentifier == application.bundleID else {
                storageMessage = "所选软件无效，或选择了学习日程自身；请重新选择。"
                return false
            }
        }
        var next = configuration
        next.applications[courseID.uuidString] = application
        guard save(next) else { return false }
        revision = UUID()
        // Drop this course's supervision labels before the session that owns them.
        activeTaskIDs.subtract(sessions[courseID]?.taskIDs ?? [])
        sessions.removeValue(forKey: courseID)
        statuses.removeValue(forKey: courseID)
        if persistent { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(courseID)]) }
        summary = hasBindings ? "等待计划学习时段" : "未绑定监督软件"
        requestCheck()
        return true
    }

    private func save(_ next: Configuration) -> Bool {
        do {
            let encoded = try JSONEncoder().encode(next)
            if persistent { UserDefaults.standard.set(encoded, forKey: Self.preferenceKey) }
            configuration = next
            return true
        } catch {
            storageMessage = "软件绑定未能保存，请重试。"
            return false
        }
    }

    /// Called only from a user action, never from the periodic monitor.
    func authorize(_ application: SupervisedApplication) async {
        guard persistent, !authorizing else { return }
        authorizing = true
        activeTaskIDs = []
        revision = UUID()
        defer { authorizing = false; sessions = [:]; requestCheck() }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            permissionMessage = granted ? "系统通知已允许。" : "通知未允许，请在系统设置中开启学习日程的通知。"
        } catch { permissionMessage = "通知授权未完成，请在系统设置中检查。" }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: application.bundleID).first else {
            permissionMessage += " 请打开“\(application.name)”后点击“授权并检查”，检测不会代你启动软件。"
            return
        }
        let observation = await PlaybackDetection.check(kind: application.scripting, name: application.name,
            requestAutomation: { await PlaybackStateReader.authorize(pid: running.processIdentifier) },
            readScripted: { await PlaybackStateReader.read(application, pid: running.processIdentifier) },
            readAudio: { await self.authorizeAudio(application) })
        switch observation {
        case .playing(let detail), .stopped(let detail), .unavailable(let detail):
            permissionMessage += " " + detail
        }
        for (courseID, bound) in configuration.applications where bound.bundleID == application.bundleID {
            guard let id = UUID(uuidString: courseID) else { continue }
            switch observation {
            case .playing(let detail), .stopped(let detail): statuses[id] = detail
            case .unavailable(let detail): statuses[id] = "检测不可用：" + detail
            }
        }
    }

    private func authorizeAudio(_ application: SupervisedApplication) async -> PlaybackObservation {
        guard #available(macOS 14.2, *) else {
            return .unavailable("通用软件的音频检测需要 macOS 14.2 或更新版本。")
        }
        let sample = await ApplicationAudioProbe.sample(application)
        switch sample {
        case .playing:
            var next = configuration
            next.audioAuthorized.insert(application.bundleID)
            guard save(next) else { return .unavailable(storageMessage ?? "音频检测授权配置未能保存。") }
            verifiedAudioApps.insert(application.bundleID)
            return sample
        case .stopped, .unavailable: return sample
        }
    }

    func start(store: PlannerStore) {
        guard monitoringEnabled, !running else { return }
        self.store = store
        running = true
        suspended = false
        observationToken = UUID()
        trackPlanChanges()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in
                    guard let self, let bundleID,
                          self.configuration.applications.values.contains(where: { $0.bundleID == bundleID }) else { return }
                    self.sessions = [:]; self.revision = UUID()
                    self.requestCheck()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemClockDidChange,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.running else { return }
                    self.sessions = [:]; self.revision = UUID(); self.lastTick = .distantPast
                    self.requestCheck()
                }
            })
        requestCheck()
    }

    func stop() {
        running = false
        revision = UUID(); observationToken = UUID()
        timer?.invalidate(); timer = nil; nextCheckAt = nil
        checkTask?.cancel()
        activeTaskIDs = []; sessions = [:]
        endActivity()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    private func trackPlanChanges() {
        guard running, let store else { return }
        let token = observationToken
        withObservationTracking {
            _ = store.state
            _ = store.isReady
        } onChange: { [weak self] in
            // Observation invokes onChange before the write completes. Read the
            // updated snapshot on the next main-actor turn and re-arm tracking.
            Task { @MainActor in
                guard let self, self.running, self.observationToken == token else { return }
                self.trackPlanChanges()
                self.revision = UUID()
                self.requestCheck()
            }
        }
    }

    private func requestCheck() {
        guard running, !suspended else { return }
        timer?.invalidate(); timer = nil; nextCheckAt = nil
        // Keep the waiting interval out of App Nap too, otherwise the very timer
        // intended to start supervision can be deferred until a window opens.
        if hasBindings {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: "等待并按学习计划监督软件播放状态")
            }
        } else { endActivity() }
        guard checkTask == nil else { needsRefresh = true; return }
        checkTask = Task { [weak self] in
            await self?.tick()
            guard let self else { return }
            self.checkTask = nil
            guard self.running, !self.suspended else { return }
            if self.needsRefresh {
                self.needsRefresh = false
                self.requestCheck()
            } else { self.scheduleNextCheck() }
        }
    }

    private func scheduleNextCheck() {
        guard running, !suspended, let store else { return }
        let now = Date()
        // A short fallback handles day rollover/loading. Every concrete task
        // boundary and per-course check deadline can wake us earlier.
        var next = now.addingTimeInterval(30)
        if hasBindings, store.isReady, !authorizing {
            for task in store.state.tasks where task.isUnconfirmed && application(for: task.courseID) != nil
                && store.course(task.courseID)?.isArchived == false {
                if task.start > now { next = min(next, task.start) }
                if task.end > now { next = min(next, task.end) }
            }
            for session in sessions.values {
                next = min(next, session.lastCheck.addingTimeInterval(Self.checkInterval))
            }
        }
        // Failed/stale observations can leave a session due. Retry promptly,
        // while avoiding a zero-delay loop if the plan changes during a probe.
        next = max(next, now.addingTimeInterval(0.05))
        nextCheckAt = next
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.requestCheck() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func suspend() {
        guard running else { return }
        suspended = true; sessions = [:]; activeTaskIDs = []; revision = UUID()
        timer?.invalidate(); timer = nil; nextCheckAt = nil
        endActivity()
        summary = "屏幕休眠或会话未激活，监督已暂停"
    }
    private func resume() {
        guard running, suspended else { return }
        suspended = false; sessions = [:]; activeTaskIDs = []; revision = UUID(); lastTick = .distantPast
        summary = hasBindings ? "等待计划学习时段" : "未绑定监督软件"
        requestCheck()
    }

    private func tick() async {
        guard running, !Task.isCancelled, let store, store.isReady, !checking, !authorizing, !suspended else { return }
        let now = Date()
        // Resume/long scheduling delays discard previous failure counts; only check current tasks.
        if now.timeIntervalSince(lastTick) > 90 { sessions = [:] }
        defer { lastTick = Date() }
        store.checkDay()
        let liveCourses = Set(store.state.courses.map { $0.id.uuidString })
        if configurationWritable && configuration.applications.keys.contains(where: { !liveCourses.contains($0) }) {
            var next = configuration
            next.applications = next.applications.filter { liveCourses.contains($0.key) }
            _ = save(next)
        }
        guard hasBindings else {
            endActivity(); activeTaskIDs = []; summary = "未绑定监督软件"; return
        }
        // Concrete projected slots avoid supervising every course throughout a shared floating window.
        let active = store.state.tasks.filter {
            $0.isUnconfirmed && $0.start <= now && now < $0.end && application(for: $0.courseID) != nil
                && store.course($0.courseID)?.isArchived == false
        }
        let activeIDs = Set(active.map(\.id))
        if activeTaskIDs != activeIDs { activeTaskIDs = activeIDs }
        let groups = Dictionary(grouping: active, by: \.courseID)
        sessions = sessions.filter { groups[$0.key] != nil }
        statuses = statuses.filter { groups[$0.key] != nil }
        guard !groups.isEmpty else { summary = "等待计划学习时段"; return }
        summary = "正在监督 \(groups.count) 门课程"
        checking = true
        defer { checking = false }
        let token = revision
        var observations: [String: PlaybackObservation] = [:]
        for (courseID, tasks) in groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard !Task.isCancelled, !suspended, revision == token,
                  let app = application(for: courseID) else { return }
            let taskIDs = Set(tasks.map(\.id))
            var session = sessions[courseID] ?? Session(taskIDs: taskIDs)
            if session.taskIDs != taskIDs { session = Session(taskIDs: taskIDs) }
            sessions[courseID] = session
            guard now.timeIntervalSince(session.lastCheck) >= Self.checkInterval else { continue }
            let observation: PlaybackObservation
            if let cached = observations[app.bundleID] { observation = cached }
            else {
                observation = await observe(app)
                observations[app.bundleID] = observation
            }
            guard !Task.isCancelled, revision == token, !suspended,
                  store.state.tasks.contains(where: { taskIDs.contains($0.id) && $0.isUnconfirmed && $0.start <= Date() && Date() < $0.end }) else { continue }
            session.lastCheck = Date()
            let body: String?
            switch observation {
            case .playing(let detail):
                session.unknowns = 0
                statuses[courseID] = detail
                if persistent { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(courseID)]) }
                body = nil
            case .stopped(let detail):
                session.unknowns = 0
                statuses[courseID] = detail
                body = "当前是“\(store.course(courseID)?.name ?? "课程")”的学习时间。\(detail)，请检查“\(app.name)”。"
            case .unavailable(let detail):
                session.unknowns += 1
                statuses[courseID] = "检测不可用：" + detail
                body = session.unknowns >= 2 && Date().timeIntervalSince(lastUnavailableReminders[courseID] ?? .distantPast) >= 900
                    ? "“\(app.name)”的学习监督暂不可用。\(detail) 可在学习设置的“学习监督”中处理。"
                    : nil
            }
            if let body, await notify(courseID: courseID, body: body, revision: token, taskIDs: taskIDs) {
                if case .unavailable = observation { lastUnavailableReminders[courseID] = Date() }
            }
            guard revision == token, !suspended else { return }
            sessions[courseID] = session
        }
    }

    private func observe(_ app: SupervisedApplication) async -> PlaybackObservation {
        if let observationOverride { return await observationOverride(app) }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
            return .stopped("对应软件尚未打开")
        }
        return await PlaybackDetection.check(kind: app.scripting, name: app.name,
            readScripted: { await PlaybackStateReader.read(app, pid: running.processIdentifier) },
            readAudio: { await self.observeAudio(app) })
    }

    private func observeAudio(_ app: SupervisedApplication) async -> PlaybackObservation {
        guard #available(macOS 14.2, *) else {
            return .unavailable("通用软件的音频检测需要 macOS 14.2 或更新版本。")
        }
        let audio = await ApplicationAudioProbe.sample(app,
            captureAllowed: configuration.audioAuthorized.contains(app.bundleID),
            previouslyVerified: verifiedAudioApps.contains(app.bundleID))
        switch audio {
        case .playing: verifiedAudioApps.insert(app.bundleID); return audio
        default: return audio
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    private func notify(courseID: UUID, body: String, revision token: UUID, taskIDs: Set<UUID>) async -> Bool {
        if let reminderOverride { return await reminderOverride(courseID, body) }
        guard persistent else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard revision == token, !suspended,
              store?.state.tasks.contains(where: { taskIDs.contains($0.id) && $0.isUnconfirmed && $0.start <= Date() && Date() < $0.end }) == true else { return false }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            permissionMessage = "系统通知未允许，请在系统设置中开启学习日程的通知。"
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = "学习监督提醒"; content.body = body
        content.sound = reminderSound.notificationSound
        do { try await center.add(UNNotificationRequest(identifier: identifier(courseID), content: content, trigger: nil)); return true }
        catch { permissionMessage = "监督通知发送失败，请检查系统通知设置。"; return false }
    }
    private func identifier(_ courseID: UUID) -> String { "playback-supervision-" + courseID.uuidString }
}

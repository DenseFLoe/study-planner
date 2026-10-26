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
        var firstSeen: Date
        var lastCheck = Date.distantPast
        var misses = 0
        var unknowns = 0
    }
    static let checkInterval: TimeInterval = 180
    private static let preferenceKey = "macPlaybackSupervision.v1"
    private var configuration = Configuration()
    private(set) var statuses: [UUID: String] = [:]
    private(set) var summary = "未绑定监督软件"
    private(set) var storageMessage: String?
    private(set) var permissionMessage = "首次绑定时申请通知及检测权限。"
    private(set) var authorizing = false
    @ObservationIgnored private weak var store: PlannerStore?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var sessions: [UUID: Session] = [:]
    @ObservationIgnored private var lastReminders: [UUID: Date] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var lastTick = Date.distantPast
    @ObservationIgnored private var verifiedAudioApps: Set<String> = []
    @ObservationIgnored private var configurationWritable = true
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let persistent: Bool

    init(persistent: Bool = true) {
        self.persistent = persistent
        if persistent, let data = UserDefaults.standard.data(forKey: Self.preferenceKey) {
            do { configuration = try JSONDecoder().decode(Configuration.self, from: data) }
            catch { configurationWritable = false; storageMessage = "软件绑定读取失败；原数据未覆盖，请重新启动后检查。" }
        }
        if hasBindings { summary = "等待计划学习时段" }
    }

    var hasBindings: Bool { !configuration.applications.isEmpty }
    func application(for courseID: UUID) -> SupervisedApplication? { configuration.applications[courseID.uuidString] }

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
        sessions.removeValue(forKey: courseID)
        statuses.removeValue(forKey: courseID)
        if persistent { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(courseID)]) }
        summary = hasBindings ? "等待计划学习时段" : "未绑定监督软件"
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
        revision = UUID()
        defer { authorizing = false; sessions = [:] }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            permissionMessage = granted ? "系统通知已允许。" : "通知未允许，请在系统设置中开启学习日程的通知。"
        } catch { permissionMessage = "通知授权未完成，请在系统设置中检查。" }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: application.bundleID).first else {
            permissionMessage += " 请打开“\(application.name)”后点击“授权并检查”，检测不会代你启动软件。"
            return
        }
        if application.scripting != nil {
            _ = await PlaybackStateReader.authorize(pid: running.processIdentifier)
            if let state = await PlaybackStateReader.read(application, pid: running.processIdentifier) {
                switch state {
                case .playing(let detail), .stopped(let detail):
                    permissionMessage += " " + detail
                    return
                case .unavailable: break
                }
            }
        }
        guard #available(macOS 14.2, *) else {
            permissionMessage += " 通用软件的音频检测需要 macOS 14.2 或更新版本。"
            return
        }
        var next = configuration
        next.audioAuthorized.insert(application.bundleID)
        guard save(next) else { return }
        let sample = await ApplicationAudioProbe.sample(application, permissionRequest: true)
        switch sample {
        case .playing(let detail):
            verifiedAudioApps.insert(application.bundleID)
            permissionMessage += " " + detail
        case .stopped:
            permissionMessage += " 请让软件有声播放以验证音频检测；静音播放可能无法识别。"
        case .unavailable(let detail): permissionMessage += " " + detail
        }
    }

    func start(store: PlannerStore) {
        guard persistent, monitor == nil else { return }
        self.store = store
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
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }

    func stop() {
        monitor?.cancel(); monitor = nil
        endActivity()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    private func suspend() {
        suspended = true; sessions = [:]; revision = UUID()
        endActivity()
        summary = "屏幕休眠或会话未激活，监督已暂停"
    }
    private func resume() {
        suspended = false; sessions = [:]; revision = UUID(); lastTick = .distantPast
        summary = hasBindings ? "等待计划学习时段" : "未绑定监督软件"
    }

    private func tick() async {
        guard let store, store.isReady, !checking, !authorizing, !suspended else { return }
        let now = Date()
        // Sleep/long scheduling delays start a fresh grace period, with no catch-up alerts.
        if now.timeIntervalSince(lastTick) > 90 { sessions = [:] }
        defer { lastTick = Date() }
        store.checkDay()
        let liveCourses = Set(store.state.courses.map { $0.id.uuidString })
        if configurationWritable && configuration.applications.keys.contains(where: { !liveCourses.contains($0) }) {
            var next = configuration
            next.applications = next.applications.filter { liveCourses.contains($0.key) }
            _ = save(next)
        }
        guard hasBindings else { endActivity(); summary = "未绑定监督软件"; return }
        // Concrete projected slots avoid supervising every course throughout a shared floating window.
        let active = store.state.tasks.filter {
            $0.isUnconfirmed && $0.start <= now && now < $0.end && application(for: $0.courseID) != nil
                && store.course($0.courseID)?.isArchived == false
        }
        let groups = Dictionary(grouping: active, by: \.courseID)
        sessions = sessions.filter { groups[$0.key] != nil }
        statuses = statuses.filter { groups[$0.key] != nil }
        guard !groups.isEmpty else { endActivity(); summary = "等待计划学习时段"; return }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "按学习计划监督软件播放状态")
        }
        summary = "正在监督 \(groups.count) 门课程"
        checking = true
        defer { checking = false }
        let token = revision
        var observations: [String: PlaybackObservation] = [:]
        for (courseID, tasks) in groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard !Task.isCancelled, !suspended, revision == token,
                  let app = application(for: courseID) else { return }
            let taskIDs = Set(tasks.map(\.id))
            var session = sessions[courseID] ?? Session(taskIDs: taskIDs, firstSeen: now)
            if session.taskIDs != taskIDs { session = Session(taskIDs: taskIDs, firstSeen: now) }
            sessions[courseID] = session
            guard now.timeIntervalSince(session.firstSeen) >= Self.checkInterval,
                  now.timeIntervalSince(session.lastCheck) >= Self.checkInterval else {
                if session.lastCheck == .distantPast { statuses[courseID] = "学习开始后保留 3 分钟准备时间" }
                continue
            }
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
                session.misses = 0; session.unknowns = 0
                statuses[courseID] = detail
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(courseID)])
                body = nil
            case .stopped(let detail):
                session.misses += 1; session.unknowns = 0
                statuses[courseID] = detail + "（连续 \(session.misses) 次）"
                body = session.misses >= 2 ? "当前是“\(store.course(courseID)?.name ?? "课程")”的学习时间。\(detail)，请检查“\(app.name)”。" : nil
            case .unavailable(let detail):
                session.misses = 0; session.unknowns += 1
                statuses[courseID] = "检测不可用：" + detail
                body = session.unknowns >= 2 ? "“\(app.name)”的学习监督暂不可用。\(detail) 可在学习设置的“学习监督”中处理。" : nil
            }
            if let body, Date().timeIntervalSince(lastReminders[courseID] ?? .distantPast) >= 900 {
                if await notify(courseID: courseID, body: body, revision: token, taskIDs: taskIDs) { lastReminders[courseID] = Date() }
            }
            guard revision == token, !suspended else { return }
            sessions[courseID] = session
        }
    }

    private func observe(_ app: SupervisedApplication) async -> PlaybackObservation {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
            return .stopped("对应软件尚未打开")
        }
        let scripted = await PlaybackStateReader.read(app, pid: running.processIdentifier)
        if let scripted {
            switch scripted {
            case .playing, .stopped: return scripted
            case .unavailable: break
            }
        }
        guard configuration.audioAuthorized.contains(app.bundleID), #available(macOS 14.2, *) else {
            return scripted ?? .unavailable("请让软件有声播放，再点击“授权并检查”完成系统音频检测授权。")
        }
        let audio = await ApplicationAudioProbe.sample(app, previouslyVerified: verifiedAudioApps.contains(app.bundleID))
        switch audio {
        case .playing: verifiedAudioApps.insert(app.bundleID); return audio
        case .stopped where !verifiedAudioApps.contains(app.bundleID):
            return .unavailable("尚未验证音频权限；请让软件有声播放，再点击“授权并检查”。")
        default: return audio
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    private func notify(courseID: UUID, body: String, revision token: UUID, taskIDs: Set<UUID>) async -> Bool {
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
        do { try await center.add(UNNotificationRequest(identifier: identifier(courseID), content: content, trigger: nil)); return true }
        catch { permissionMessage = "监督通知发送失败，请检查系统通知设置。"; return false }
    }
    private func identifier(_ courseID: UUID) -> String { "playback-supervision-" + courseID.uuidString }
}

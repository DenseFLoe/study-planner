import Foundation
import Observation
import StudyCore

@MainActor @Observable
final class WebsiteCourseUpdater {
    typealias Fetch = @MainActor (URL, String, CourseWebsite, Bool) async throws -> WebCourseSnapshot
    private(set) var sources: [UUID: WebsiteCourseSource] = [:]
    private(set) var updating: UUID?
    private var editors: [UUID: Int] = [:]
    private weak var store: PlannerStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let fetch: Fetch?
    private static let key = "studyPlannerWebsiteSources.v1"

    init(defaults: UserDefaults? = nil, fetch: Fetch? = nil) {
        self.defaults = defaults
        self.fetch = fetch
        if let data = defaults?.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([UUID: WebsiteCourseSource].self, from: data) {
            sources = decoded.filter { _, source in
                WebsiteCourseSource.intervals.contains(source.intervalMinutes) &&
                    URL(string: source.url).flatMap(CourseWebsite.identify) != nil
            }
        }
    }
    var hasEnabledSources: Bool {
        guard let store else { return false }
        return store.courses.contains { sources[$0.id]?.enabled == true && CourseWebsite.identify($0.webCourse) != nil }
    }
    func source(for course: Course) -> WebsiteCourseSource {
        sources[course.id] ?? WebsiteCourseSource(url: course.webCourse?.sourceURL ?? "")
    }
    func start(store: PlannerStore) {
        self.store = store
        guard loop == nil, !store.demo else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func beginEditing(_ id: UUID) { editors[id, default: 0] += 1 }
    func endEditing(_ id: UUID) {
        if let count = editors[id], count > 1 { editors[id] = count - 1 }
        else { editors.removeValue(forKey: id) }
    }
    func configure(course: Course, url: String, enabled: Bool, interval: Int) throws {
        guard let snapshot = course.webCourse, let site = CourseWebsite.identify(snapshot),
              !course.isArchived, course.mergedSources == nil else {
            throw WebsiteUpdateError.message("只有研途和学丞导入的独立课程可以自动更新。")
        }
        let safe = try site.courseURL(url, packageID: snapshot.packageID)
        guard WebsiteCourseSource.intervals.contains(interval) else { throw WebsiteUpdateError.message("请选择有效的更新间隔。") }
        var value = source(for: course)
        value.url = safe.absoluteString; value.enabled = enabled; value.intervalMinutes = interval
        // Saving a switch must not repeatedly submit a failed password. Explicit retry resumes it.
        sources[course.id] = value
        persist()
    }
    func tick(now: Date = Date()) async {
        guard updating == nil, let store, store.isReady, !store.orderSaveBusy else { return }
        let due = store.courses.first { editors[$0.id] == nil && sources[$0.id]?.isDue(at: now) == true && CourseWebsite.identify($0.webCourse) != nil }
        if let due { await update(courseID: due.id, interactive: false, now: now) }
    }
    func update(courseID: UUID, interactive: Bool = true, now: Date = Date()) async {
        guard updating == nil, let store, store.isReady, !store.orderSaveBusy,
              let course = store.course(courseID), !course.isArchived, course.mergedSources == nil,
              let previous = course.webCourse, let site = CourseWebsite.identify(previous) else { return }
        let binding = source(for: course)
        updating = courseID
        var value = binding
        value.lastAttempt = now; value.status = "正在读取\(site.name)…"; value.needsAttention = false
        sources[courseID] = value; persist()
        defer { updating = nil }
        do {
            let url = try site.courseURL(binding.url, packageID: previous.packageID)
            let snapshot: WebCourseSnapshot
            if let fetch {
                snapshot = try await fetch(url, previous.packageID, site, interactive)
            } else {
                let reader = WebLessonReader()
                snapshot = try await reader.managedSnapshot(url: url, packageID: previous.packageID, interactive: interactive) { [weak self] status in
                    guard let self, self.updating == courseID else { return }
                    self.sources[courseID]?.status = status
                }
            }
            try Task.checkCancellation()
            // Do not replace the snapshot underneath an open course/order editor's unsaved draft.
            while editors[courseID] != nil {
                sources[courseID]?.status = "课程读取完成，等待关闭编辑窗口后保存"
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let latest = store.course(courseID), !latest.isArchived, latest.mergedSources == nil,
                  latest.webCourse?.packageID == previous.packageID,
                  CourseWebsite.identify(latest.webCourse) == site,
                  sources[courseID]?.url == binding.url,
                  interactive || sources[courseID]?.enabled == true else {
                throw WebsiteUpdateError.message("课程或更新设置已变化，本次结果未写入。")
            }
            try Self.validate(snapshot, replacing: latest)
            // A local edit can finish during the network read. Merge into the latest state after its transaction.
            guard await store.waitForOrderSave() else { throw WebsiteUpdateError.message("本地保存失败，本次网站更新未写入。") }
            guard editors[courseID] == nil, sources[courseID]?.url == binding.url,
                  interactive || sources[courseID]?.enabled == true else {
                throw WebsiteUpdateError.message("课程正在编辑或更新设置已变化，本次结果未写入。")
            }
            let saveTime = Date()
            let saved = await store.change(now: saveTime) { state in
                guard let current = state.courses.first(where: { $0.id == courseID }), !current.isArchived,
                      current.mergedSources == nil, current.webCourse?.packageID == previous.packageID,
                      CourseWebsite.identify(current.webCourse) == site else {
                    throw WebsiteUpdateError.message("原课程已被修改或删除，本次更新取消。")
                }
                let snapshot = try Self.validate(snapshot, replacing: current)
                try state.importWebCourses([snapshot], deadline: max(current.deadline, Calendar.current.startOfDay(for: saveTime)), now: saveTime)
                if let index = state.courses.firstIndex(where: { $0.id == courseID }) {
                    state.courses[index].name = current.name
                    state.courses[index].type = current.type
                }
            }
            guard saved else { throw WebsiteUpdateError.message("网站数据已读取，但本地未保存成功，请检查课程设置后重试。") }
            sources[courseID]?.lastSuccess = Date()
            sources[courseID]?.needsAttention = false
            let pending = snapshot.lessons.filter { !$0.published }.count
            sources[courseID]?.status = pending == 0 ? "更新成功" : "更新成功；\(pending) 个课节尚未更新，已保留目录，将按设置继续检查"
            // A successful manual read proves the shared website session works again.
            for peer in store.courses where CourseWebsite.identify(peer.webCourse) == site && peer.id != courseID {
                if sources[peer.id]?.status == WebsiteUpdateError.loginRequired.localizedDescription {
                    sources[peer.id]?.needsAttention = false
                    sources[peer.id]?.lastAttempt = nil
                    sources[peer.id]?.status = "登录已恢复，等待更新"
                }
            }
        } catch {
            // Never surface raw website, browser or keychain errors (they may contain private values).
            if error is CancellationError || Task.isCancelled {
                sources[courseID]?.needsAttention = false
                sources[courseID]?.lastAttempt = nil
                sources[courseID]?.status = "更新已停止，下次运行时继续检查"
            } else {
                sources[courseID]?.needsAttention = true
                sources[courseID]?.status = (error as? WebsiteUpdateError)?.localizedDescription
                    ?? "更新暂停：请检查网络、浏览器授权及网站登录状态，再点“立即更新”。原课程已保留。"
                if let error = error as? WebsiteUpdateError, case .loginRequired = error {
                    for peer in store.courses where CourseWebsite.identify(peer.webCourse) == site && sources[peer.id] != nil {
                        sources[peer.id]?.needsAttention = true
                        sources[peer.id]?.status = error.localizedDescription
                    }
                }
            }
        }
        persist()
    }
    @discardableResult
    static func validate(_ snapshot: WebCourseSnapshot, replacing course: Course) throws -> WebCourseSnapshot {
        guard let old = course.webCourse, snapshot.packageID == old.packageID,
              let site = CourseWebsite.identify(old), CourseWebsite.identify(snapshot) == site,
              snapshot.importProblem == nil else {
            throw WebsiteUpdateError.message("课程不匹配或抓取不完整，原课程已保留。")
        }
        let deleted = Set(course.deletedLessonIDs ?? [])
        guard snapshot.fetchedAt >= old.fetchedAt else {
            throw WebsiteUpdateError.message("这门课已有更新的网站数据，本次较早的读取结果未写入。")
        }
        let snapshot = site == .xuecheng ? try retainingXuechengLessonIDs(snapshot, replacing: course) : snapshot
        let previousIDs = Set(old.lessons.map(\.id)).subtracting(deleted)
        let missing = previousIDs.subtracting(snapshot.lessons.map(\.id))
        guard missing.isEmpty else {
            throw WebsiteUpdateError.message("本次读取 \(snapshot.lessons.count) 节，已有 \(missing.count) 节未能对应，可能是目录未读全或编号变化。请核对网站目录后重试，原课程已保留。")
        }
        return snapshot
    }

    /// Older live rows used a title occurrence; current rows use an accordion path.
    /// Keep the persisted ID so task history, ordering and deletion tombstones still refer
    /// to the same lesson. Never infer identity for provider IDs or ambiguous titles.
    private static func retainingXuechengLessonIDs(_ snapshot: WebCourseSnapshot, replacing course: Course) throws -> WebCourseSnapshot {
        guard let old = course.webCourse else { return snapshot }
        let deleted = Set(course.deletedLessonIDs ?? [])
        let oldByID = Dictionary(old.lessons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let knownIDs = Set(oldByID.keys).union(deleted)
        let incomingIDs = Set(snapshot.lessons.map(\.id))
        let incomingByName = Dictionary(grouping: snapshot.lessons, by: \.name)
        var knownByName = Dictionary(grouping: old.lessons, by: \.name).mapValues { Set($0.map(\.id)) }
        let ambiguous = WebsiteUpdateError.message("学丞直播课节编号变化，但同名课节无法唯一对应。请人工核对，原课程和删除记录已保留。")
        // Deleted rows no longer have metadata. Only recognize their exact embedded title
        // and one of our two generated suffix formats; do not guess by duration or position.
        for id in deleted where oldByID[id] == nil {
            let names = incomingByName.keys.filter { xuechengLiveID(id, name: $0, packageID: old.packageID) }
            guard names.count <= 1 else { throw ambiguous }
            if let name = names.first { knownByName[name, default: []].insert(id) }
        }
        var result = snapshot
        for index in result.lessons.indices {
            let lesson = result.lessons[index]
            guard !knownIDs.contains(lesson.id), lesson.kind == "living",
                  xuechengLiveID(lesson.id, name: lesson.name, packageID: snapshot.packageID),
                  let candidates = knownByName[lesson.name], !candidates.isEmpty else { continue }
            guard candidates.count == 1, incomingByName[lesson.name]?.count == 1,
                  let id = candidates.first, !incomingIDs.contains(id) else { throw ambiguous }
            guard xuechengLiveID(id, name: lesson.name, packageID: old.packageID) else { continue }
            if let previous = oldByID[id] {
                guard previous.kind == "living", previous.subject == lesson.subject,
                      previous.stage == lesson.stage, previous.chapter == lesson.chapter else { continue }
            }
            result.lessons[index].id = id
        }
        return result
    }

    private static func xuechengLiveID(_ id: String, name: String, packageID: String) -> Bool {
        let prefix = packageID + ":live:" + name + ":"
        guard !name.isEmpty, id.hasPrefix(prefix) else { return false }
        let suffix = String(id.dropFirst(prefix.count))
        // Legacy occurrence (1), flat row (:0), or nested directory path (0.1.0.2:3).
        return suffix.range(of: #"^(?:[0-9]+|(?:[0-9]+(?:\.[0-9]+)*)?:[0-9]+)$"#,
                            options: .regularExpression) != nil
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(sources) { defaults?.set(data, forKey: Self.key) }
    }
}

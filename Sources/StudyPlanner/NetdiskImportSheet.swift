import AppKit
import SwiftUI
import WebKit
import StudyCore

@MainActor @Observable
final class NetdiskImportReader: NSObject, WKNavigationDelegate {
    var address = ""
    var passcode = ""
    var status = "输入夸克分享链接后打开，软件会递归读取其中的文件。"
    var busy = false
    var result: NetdiskCrawler.Result?
    var revision = UUID()
    var existingCourses: [Course] = []
    let transport = WebViewNetdiskTransport()
    private var currentLink: NetdiskLink?
    private var pendingRead = false
    private var generation = UUID()
    private var crawlTask: Task<Void, Never>?

    override init() {
        super.init()
        transport.webView.navigationDelegate = self
    }

    func open(existingCourses: [Course]) { self.existingCourses = existingCourses }

    func load() {
        guard let link = NetdiskLink.parse(address) else {
            status = NetdiskAPIError.badLink.localizedDescription
            return
        }
        generation = UUID()
        crawlTask?.cancel()
        result = nil
        currentLink = link
        pendingRead = true
        busy = true
        status = "正在打开分享页面…"
        let supplied = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = supplied.hasPrefix("https://") ? supplied : "https://" + supplied
        var components = URLComponents(string: normalized)
        components?.scheme = "https"
        components?.host = "pan.quark.cn"
        guard let url = components?.url else {
            busy = false
            status = NetdiskAPIError.badLink.localizedDescription
            return
        }
        transport.loadShare(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard pendingRead, webView.url?.host?.lowercased() == "pan.quark.cn" else { return }
        pendingRead = false
        refresh()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard pendingRead else { return }
        pendingRead = false
        busy = false
        status = "分享页面未能打开：\(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard pendingRead else { return }
        pendingRead = false
        busy = false
        status = "分享页面未能打开：\(error.localizedDescription)"
    }

    func refresh() {
        guard let link = currentLink else { load(); return }
        generation = UUID()
        let current = generation
        crawlTask?.cancel()
        busy = true
        status = "正在读取分享目录…"
        let sourceURL = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = passcode.isEmpty ? link.inAppPasscode : passcode
        crawlTask = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (NetdiskCrawler.Progress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.status = "\(progress.detail) 已见 \(progress.videosSeen) 个视频。"
                }
            }
            do {
                let value: NetdiskCrawler.Result
                do {
                    // Public shares can be read directly. This also avoids waiting for the
                    // embedded page's login overlay before starting a large directory scan.
                    value = try await NetdiskCrawler(transport: PlainNetdiskTransport(), onProgress: progress)
                        .crawl(link: link, passcode: code, sourceURL: sourceURL,
                               existingCourses: existingCourses, now: Date())
                } catch let error as NetdiskAPIError {
                    switch error {
                    case .notLoggedIn, .http(401, _), .http(403, _):
                        status = "此分享需要登录，正在使用右侧页面的会话重试…"
                        value = try await NetdiskCrawler(transport: transport, onProgress: progress)
                            .crawl(link: link, passcode: code, sourceURL: sourceURL,
                                   existingCourses: existingCourses, now: Date())
                    default: throw error
                    }
                }
                guard generation == current else { return }
                result = value
                revision = UUID()
                status = "读取完成：\(value.scan.packages.count) 门课程候选，\(value.scan.totalVideoCount) 个视频。"
            } catch is CancellationError {
                return
            } catch {
                guard generation == current else { return }
                status = "读取失败：\(error.localizedDescription)"
            }
            if generation == current { busy = false }
        }
    }

    func stop() {
        generation = UUID()
        crawlTask?.cancel()
        transport.stop()
        busy = false
    }
}

private struct QuarkPage: NSViewRepresentable {
    let reader: NetdiskImportReader
    func makeNSView(context: Context) -> WKWebView { reader.transport.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct NetdiskImportSheet: View {
    @Bindable var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var reader = NetdiskImportReader()
    @State private var selected = Set<String>()
    @State private var searchText = ""
    @State private var expandedGroups = Set<String>()
    @State private var mergeSelected = false
    @State private var mergeName = ""
    @State private var showMergedPreview = false
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 90, to: Date())!
    @State private var message = ""

    private var chosen: [NetdiskSnapshotBuilder.Course] {
        reader.result?.courses.filter { selected.contains($0.packageID) && $0.refusal == nil } ?? []
    }
    private var mergedCandidate: NetdiskSnapshotBuilder.Course? {
        guard let result = reader.result else { return nil }
        return NetdiskSnapshotBuilder.merge(chosen, name: mergeName, scan: result.scan)
    }
    private var importCandidates: [NetdiskSnapshotBuilder.Course] {
        if !mergeSelected { return chosen }
        guard let mergedCandidate, mergedCandidate.refusal == nil else { return [] }
        return [mergedCandidate]
    }

    var body: some View {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
        let width = min(max(screen.width - 80, 960), 1500)
        let height = min(max(screen.height - 40, 680), 1120)
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("从夸克网盘导入课程").font(.title2.bold())
                    Text("读取分享文件、识别视频课程、按名称排序并检查重复")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            HStack {
                TextField("夸克网盘分享链接", text: $reader.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { reader.load() }
                SecureField("提取码（如有）", text: $reader.passcode)
                    .textFieldStyle(.roundedBorder).frame(width: 135)
                Button("打开并识别") { reader.load() }
            }
            HStack {
                if reader.busy { ProgressView().controlSize(.small) }
                Text(reader.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("重新读取") { reader.existingCourses = store.state.courses; reader.refresh() }
                    .disabled(reader.busy)
            }
            HStack(alignment: .top, spacing: 14) {
                sidebar.frame(width: min(480, width * 0.42))
                VStack(alignment: .leading, spacing: 8) {
                    Label("分享页面", systemImage: "globe").font(.headline)
                    Text("如分享要求登录，请在下方页面登录后点“重新读取”。只读取目录信息，不转存或下载视频。")
                        .font(.caption).foregroundStyle(.secondary)
                    QuarkPage(reader: reader)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text(message).font(.caption).foregroundStyle(.red)
                Spacer()
                Text(mergeSelected ? "将 \(chosen.count) 门合并导入为 1 门" : "已选 \(chosen.count) 门")
                    .font(.caption).foregroundStyle(.secondary)
                Button("导入并生成计划") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(importCandidates.isEmpty || reader.busy || (reader.result?.scan.unreadFolders ?? 0) > 0)
            }
        }
        .padding(20)
        .frame(width: width, height: height)
        .onAppear { reader.open(existingCourses: store.state.courses) }
        .onDisappear { reader.stop() }
        .onChange(of: reader.revision) { _, _ in
            guard let result = reader.result else { return }
            searchText = ""
            expandedGroups = []
            mergeSelected = false
            mergeName = result.scan.displayName
            showMergedPreview = false
            let autoDropped = Set(result.duplicates.droppedPackages
                .filter { !$0.requiresReview }.map(\.droppedPackageID))
            let alreadyPresent = Set(result.duplicates.existingCourseMatches
                .filter { $0.overlapRatio >= 0.9 }.map(\.packageID))
            selected = Set(result.courses.filter { candidate in
                candidate.refusal == nil && !autoDropped.contains(candidate.packageID)
                    && !alreadyPresent.contains(candidate.packageID)
                    && (result.scan.packages.first { $0.packageID == candidate.packageID }?.signal.score ?? 0)
                        >= NetdiskDigest.Limits.standard.autoSelectScore
            }.map(\.packageID))
            let groups = NetdiskCourseBrowser(courses: result.courses, packages: result.scan.packages)
                .grouped(result.courses)
            expandedGroups = groups.children.count <= 3 ? Set(groups.children.map(\.path)) : []
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("识别结果", systemImage: "list.bullet.rectangle").font(.headline)
                Spacer()
                if let result = reader.result {
                    Text("\(result.courses.count) 门 · \(result.scan.totalVideoCount) 个视频")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result = reader.result {
                let browser = NetdiskCourseBrowser(courses: result.courses, packages: result.scan.packages)
                let matches = browser.matching(searchText)
                let searchActive = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let scores = Dictionary(result.scan.packages.map { ($0.packageID, $0.signal.score) },
                                        uniquingKeysWith: { first, _ in first })
                DatePicker("新课程截止日", selection: $deadline, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact)
                TextField("搜索课程、目录或课节", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Text(searchActive ? "找到 \(matches.count) 门课程" : "按网盘目录分类")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("全部勾选") { selected.formUnion(browser.selectableIDs) }
                        .disabled(browser.selectableIDs.isEmpty || browser.selectableIDs.isSubset(of: selected))
                    Button("全部不勾选") { selected.subtract(browser.selectableIDs) }
                        .disabled(selected.isDisjoint(with: browser.selectableIDs))
                }
                .controlSize(.small)
                if searchActive {
                    HStack(spacing: 8) {
                        Button("勾选搜索结果") {
                            selected.formUnion(matches.filter { $0.refusal == nil }.map(\.packageID))
                        }
                        Button("取消搜索结果") { selected.subtract(matches.map(\.packageID)) }
                        Spacer()
                    }
                    .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("将已选课程合并为一门", isOn: $mergeSelected)
                        .font(.callout.weight(.semibold))
                        .disabled(chosen.count < 2 && !mergeSelected)
                    if mergeSelected {
                        TextField("合并后课程名称", text: $mergeName)
                            .textFieldStyle(.roundedBorder)
                        if chosen.count < 2 {
                            Text("请至少勾选两门可导入课程。")
                                .font(.caption).foregroundStyle(.orange)
                        } else if mergeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("请填写合并后的课程名称。")
                                .font(.caption).foregroundStyle(.orange)
                        } else if let problem = mergedCandidate?.refusal {
                            Text(problem).font(.caption).foregroundStyle(.orange)
                        } else if let merged = mergedCandidate {
                            Text("\(merged.videoCount) 节课；先按来源课程名称，再按各课程的课节名称排序。导入后可调整课节顺序。")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("预览合并顺序", isExpanded: $showMergedPreview) {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(merged.snapshot.lessons.enumerated()), id: \.element.id) { index, lesson in
                                            Text("\(index + 1). \(lesson.name) · \(lesson.subject)")
                                                .font(.caption2)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .frame(maxHeight: 180)
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                if result.scan.unreadFolders > 0 {
                    Label("有 \(result.scan.unreadFolders) 个目录未读完，请使用更具体的子目录链接重试。",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                ForEach(result.scan.issues, id: \.self) { issue in
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
                if !result.unassignedVideos.isEmpty {
                    DisclosureGroup("未归入课程的视频（\(result.unassignedVideos.count)）") {
                        ForEach(result.unassignedVideos, id: \.fid) { video in
                            Text(video.relativePath).font(.caption2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.caption).foregroundStyle(.orange)
                }
                NetdiskCourseResults(browser: browser, report: result.duplicates, scores: scores,
                                     searchText: $searchText, selected: $selected,
                                     expandedGroups: $expandedGroups)
                    .id(reader.revision)
                Text("分类按分享目录；疑似重复保留供核对。批量勾选仅包含可导入课程。")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView("等待分享目录", systemImage: "externaldrive",
                    description: Text("打开链接后会自动读取视频课程。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private func save() {
        guard let result = reader.result else { return }
        let courses = importCandidates
        guard !courses.isEmpty else {
            message = mergeSelected ? "请至少勾选两门课程并填写有效的合并名称。" : "请勾选要导入的课程。"
            return
        }
        let success = store.change { state in
            try state.importNetdiskCourses(courses, scan: result.scan, duplicates: result.duplicates,
                                           deadline: deadline, now: Date())
        }
        if success { dismiss() } else { message = store.errorMessage ?? "保存失败" }
    }
}

struct NetdiskCourseResults: View {
    let browser: NetdiskCourseBrowser
    let report: NetdiskDuplicateReport
    let scores: [String: Double]
    @Binding var searchText: String
    @Binding var selected: Set<String>
    @Binding var expandedGroups: Set<String>
    @State private var locatedCourseID: String?

    private var searchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let matches = browser.matching(searchText)
        let groups = browser.grouped(matches)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                // Eager folder stacks register deep course anchors as soon as their
                // ancestors open, even when the target starts outside the viewport.
                VStack(alignment: .leading, spacing: 10) {
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(groups.courses, id: \.packageID) { course in
                            NetdiskCourseCard(course: course, report: report,
                                              path: browser.paths[course.packageID] ?? "",
                                              score: scores[course.packageID], selected: $selected,
                                              isLocated: locatedCourseID == course.packageID,
                                              showLocationButton: searchActive,
                                              locate: { locate(course.packageID) })
                        }
                        ForEach(groups.children) { group in
                            NetdiskFolderGroupView(group: group, report: report,
                                                   paths: browser.paths, scores: scores,
                                                   searchActive: searchActive, selected: $selected,
                                                   expandedGroups: $expandedGroups,
                                                   locatedCourseID: locatedCourseID,
                                                   locate: { locate($0) })
                        }
                    }
                }
                .padding(2)
            }
            .onChange(of: locatedCourseID) { _, packageID in
                guard let packageID else { return }
                // Wait for the cleared search and expanded groups to lay out their cards.
                DispatchQueue.main.async {
                    guard locatedCourseID == packageID, !searchActive else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(packageID, anchor: .center)
                    }
                }
            }
        }
        .onChange(of: searchText) { _, _ in
            if searchActive { locatedCourseID = nil }
        }
    }

    private func locate(_ packageID: String) {
        guard let ancestors = browser.grouped(browser.courses).ancestorPaths(containing: packageID) else { return }
        searchText = ""
        expandedGroups.formUnion(ancestors)
        locatedCourseID = packageID
    }
}

private struct NetdiskFolderGroupView: View {
    let group: NetdiskCourseBrowser.Group
    let report: NetdiskDuplicateReport
    let paths: [String: String]
    let scores: [String: Double]
    let searchActive: Bool
    @Binding var selected: Set<String>
    @Binding var expandedGroups: Set<String>
    let locatedCourseID: String?
    let locate: (String) -> Void

    var body: some View {
        let ids = group.selectableIDs
        let selectedCount = ids.intersection(selected).count
        return DisclosureGroup(isExpanded: Binding(
            get: { searchActive || expandedGroups.contains(group.path) },
            set: { if $0 { expandedGroups.insert(group.path) } else { expandedGroups.remove(group.path) } }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.courses, id: \.packageID) { course in
                    NetdiskCourseCard(course: course, report: report,
                                      path: paths[course.packageID] ?? "",
                                      score: scores[course.packageID], selected: $selected,
                                      isLocated: locatedCourseID == course.packageID,
                                      showLocationButton: searchActive,
                                      locate: { locate(course.packageID) })
                }
                ForEach(group.children) { child in
                    NetdiskFolderGroupView(group: child, report: report, paths: paths, scores: scores,
                                           searchActive: searchActive, selected: $selected,
                                           expandedGroups: $expandedGroups,
                                           locatedCourseID: locatedCourseID, locate: locate)
                }
            }
            .padding(.leading, 10)
            .padding(.top, 7)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text(group.title).font(.system(size: 18, weight: .bold)).lineLimit(2)
                    Spacer(minLength: 2)
                    Text("\(selectedCount)/\(ids.count) · \(group.count) 门")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 7) {
                    Button("勾选本类") { selected.formUnion(ids) }
                        .disabled(ids.isEmpty || selectedCount == ids.count)
                    Button("清空本类") { selected.subtract(ids) }
                        .disabled(selectedCount == 0)
                    Spacer()
                }
            }
            .controlSize(.mini)
        }
        .padding(9)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct NetdiskCourseCard: View {
    let course: NetdiskSnapshotBuilder.Course
    let report: NetdiskDuplicateReport
    let path: String
    let score: Double?
    @Binding var selected: Set<String>
    let isLocated: Bool
    let showLocationButton: Bool
    let locate: () -> Void

    var body: some View {
        let duplicate = NetdiskDuplicateSummary.compact(report, packageID: course.packageID)
        return VStack(alignment: .leading, spacing: 7) {
            Toggle(course.name, isOn: Binding(get: { selected.contains(course.packageID) }, set: {
                if $0 { selected.insert(course.packageID) } else { selected.remove(course.packageID) }
            }))
            .font(.system(size: 16, weight: .semibold))
            .disabled(course.refusal != nil)
            if showLocationButton {
                Button("定位课程", systemImage: "scope", action: locate)
                    .controlSize(.small)
                    .help("回到完整目录，展开分类并定位这门课程")
                    .accessibilityLabel("定位课程：\(course.name)")
            } else if isLocated {
                Label("已定位", systemImage: "scope")
                    .font(.caption.weight(.semibold)).foregroundStyle(PlannerTheme.accent)
            }
            if !path.isEmpty {
                Text(path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).help(path)
            }
            Text("\(course.videoCount) 节 · \(WebLessonTiming.clock(course.snapshot.totalSeconds)) · \(ByteCountFormatter.string(fromByteCount: course.totalBytes, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            Text(course.detection).font(.caption2).foregroundStyle(.secondary)
            ForEach(course.notes.filter { !course.detection.contains($0) }, id: \.self) { note in
                Text(note).font(.caption2).foregroundStyle(.orange)
            }
            if let score,
               score < NetdiskDigest.Limits.standard.autoSelectScore {
                Label("课程特征较弱，需手动勾选", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let refusal = course.refusal { Text(refusal).font(.caption).foregroundStyle(.orange) }
            ForEach(duplicate.relatedPackages + duplicate.relatedCourses + duplicate.groups, id: \.self) { item in
                Label(item, systemImage: "square.on.square").font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("查看按名称排序的课节") {
                ForEach(Array(course.snapshot.lessons.enumerated()), id: \.element.id) { index, lesson in
                    Text("\(index + 1). \(lesson.name) · \(WebLessonTiming.clock(lesson.durationSeconds ?? 0))")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.caption)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isLocated ? PlannerTheme.accent : .clear, lineWidth: 2)
        }
        .id(course.packageID)
    }
}

import SwiftUI
import AppKit
import StudyCore

struct WebsiteCourseSourceSheet: View {
    @Bindable var store: PlannerStore
    let courseID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var enabled = false
    @State private var interval = 60
    @State private var accountSheet = false
    @State private var message = ""
    private var course: Course? { store.course(courseID) }
    private var site: CourseWebsite? { CourseWebsite.identify(course?.webCourse) }
    private var busy: Bool { store.websiteUpdater.updating != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("网站来源与更新").font(.title2.bold())
                    Text(course?.name ?? "课程已删除").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("完成") { if save() { dismiss() } }
                    .keyboardShortcut(.defaultAction)
            }
            Divider()
            if let site {
                HStack {
                    Label(site.name, systemImage: "globe").font(.headline)
                    Spacer()
                    Button("管理账号密码", systemImage: "key") { accountSheet = true }
                }
                TextField("对应课程的网址", text: $url).textFieldStyle(.roundedBorder)
                HStack {
                    Button("打开课程网站") { openWebsite() }
                    Text("网址须对应原课程编号").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("允许自动更新这门课程", isOn: $enabled)
                Picker("检查间隔", selection: $interval) {
                    ForEach(WebsiteCourseSource.intervals, id: \.self) { minutes in
                        Text(minutes < 60 ? "每 \(minutes) 分钟" : "每 \(minutes / 60) 小时").tag(minutes)
                    }
                }.frame(maxWidth: 300)
                Text("使用默认浏览器的独立窗口读取。Mac 唤醒且应用运行时更新；关闭主窗口后继续，退出应用后停止。首次使用需允许浏览器自动化和来自 Apple 事件的 JavaScript。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("自动更新会补充新课节、更新网站进度并重新排课。验证码或登录失败时暂停，完成验证后点“立即更新”恢复。")
                    .font(.callout).foregroundStyle(.secondary)
                if let source = store.websiteUpdater.sources[courseID] {
                    Divider()
                    Text(source.status).foregroundStyle(source.needsAttention ? Color.orange : .secondary)
                        .textSelection(.enabled)
                    if let success = source.lastSuccess {
                        Text("上次成功：\(success.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if store.websiteUpdater.updating == courseID { ProgressView().controlSize(.small) }
                    Button("立即更新") {
                        guard save() else { return }
                        Task { await store.websiteUpdater.update(courseID: courseID) }
                    }.disabled(busy || store.demo)
                    Spacer()
                    Text("账号和更新设置仅保存在此 Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.red).font(.callout) }
        }
        .padding(24).frame(width: 620)
        .onAppear {
            if let course {
                let source = store.websiteUpdater.source(for: course)
                url = source.url; enabled = source.enabled; interval = source.intervalMinutes
            }
        }
        .sheet(isPresented: $accountSheet) {
            if let site { WebsiteAccountSheet(site: site, demo: store.demo) }
        }
    }
    private func save() -> Bool {
        guard let course else { dismiss(); return false }
        do {
            try store.websiteUpdater.configure(course: course, url: url, enabled: enabled, interval: interval)
            message = ""
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private func openWebsite() {
        guard let course, let snapshot = course.webCourse, let site else { return }
        do { NSWorkspace.shared.open(try site.courseURL(url, packageID: snapshot.packageID)) }
        catch { message = error.localizedDescription }
    }
}

private struct WebsiteAccountSheet: View {
    let site: CourseWebsite
    let demo: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var hasSaved = false
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(site.name)账号").font(.title2.bold())
            Text("此 Mac 上的\(site.name)课程共用这个账号。已登录时直接沿用浏览器会话；需要密码登录时才使用保存的账号。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("手机号 / 账号", text: $username).textFieldStyle(.roundedBorder)
            SecureField(hasSaved ? "留空保留已保存密码" : "密码", text: $password).textFieldStyle(.roundedBorder)
            Text("加密保存在 macOS 钥匙串，不随课程同步或备份。验证码、扫码和协议确认由你在浏览器完成。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("删除已保存账号", role: .destructive) { perform(delete: true) }.disabled(!hasSaved || demo)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { perform(delete: false) }.disabled(demo)
            }
        }.padding(24).frame(width: 500).disabled(busy)
            .task {
                guard !demo else { return }
                busy = true
                defer { busy = false }
                do {
                    let credentials = try await Task.detached { try WebsiteCredentialVault.load(site, interactive: true) }.value
                    username = credentials?.username ?? ""; hasSaved = credentials != nil
                } catch { message = error.localizedDescription }
            }
    }
    private func perform(delete: Bool) {
        busy = true
        let username = username, password = password
        Task {
            defer { busy = false }
            do {
                try await Task.detached {
                    if delete { try WebsiteCredentialVault.delete(site) }
                    else {
                        let saved = password.isEmpty ? try WebsiteCredentialVault.load(site, interactive: true) : nil
                        guard !password.isEmpty || saved?.username == username else {
                            throw WebsiteUpdateError.message("修改账号时请同时填写新密码。")
                        }
                        try WebsiteCredentialVault.save(.init(username: username, password: password.isEmpty ? (saved?.password ?? "") : password), site: site)
                    }
                }.value
                self.password = ""; dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}

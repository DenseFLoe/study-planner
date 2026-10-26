import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CourseSupervisionPicker: View {
    @Binding var selection: SupervisedApplication?
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selection?.name ?? "未选择，不监督此课程")
                Spacer()
                Button("选择软件…") { choose() }
                if selection != nil { Button("取消监督") { selection = nil; message = "" } }
            }
            Text("仅在本课程的计划学习时段检查软件是否打开及播放。绑定只保存在此 Mac，随课程保存。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "选择此课程对应的软件"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty,
                  bundleID != Bundle.main.bundleIdentifier else {
                message = "请选择有效的观看软件，不能选择学习日程自身。"
                return
            }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            selection = SupervisedApplication(bundleID: bundleID, name: name, path: url.path)
            message = ""
        }
    }
}

struct PlaybackSupervisionSettings: View {
    let store: PlannerStore
    private var supervisor: PlaybackSupervisor { store.playbackSupervisor }

    var body: some View {
        Section("学习监督 · 此 Mac") {
            Text(supervisor.summary).font(.headline)
            Text("每门课程只需绑定观看软件。每 3 分钟检查一次；开始后留 3 分钟准备，连续两次未播放再提醒，同一课程的提醒至少间隔 15 分钟。")
                .font(.callout).foregroundStyle(.secondary)
            Text("跨桌面、全屏和后台均按软件状态检测，不切换桌面或抢焦点。已绑定时关窗继续运行；从菜单栏可重新打开或退出。休眠与会话未激活时暂停。")
                .font(.caption).foregroundStyle(.secondary)
            Text("只检查软件是否播放，不核对课程、网站或课节。浮动任务按课表当前排列出的具体时间监督；完成、休息或未绑定的课程不检查。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(store.courses) { course in
                if let app = supervisor.application(for: course.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(course.name).fontWeight(.medium)
                            Spacer()
                            Text(app.name).foregroundStyle(.secondary)
                            Button("授权并检查") { Task { await supervisor.authorize(app) } }
                                .disabled(supervisor.authorizing)
                        }
                        if let status = supervisor.statuses[course.id] {
                            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.padding(.vertical, 4)
                }
            }
            if !supervisor.hasBindings {
                Text("在“课程 → 编辑课程 → 学习监督”中选择对应软件即可启用。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if supervisor.authorizing { ProgressView("正在检查检测权限…") }
            Text(supervisor.permissionMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let message = supervisor.storageMessage { Text(message).foregroundStyle(.orange) }
        }
        Section("检测权限与限制") {
            Text("浏览器及部分播放器使用自动化权限读取播放状态；浏览器可能还需在开发者菜单允许来自 Apple 事件的 JavaScript。跨域嵌入播放器或无法读取状态的软件会尝试音频检测。")
                .font(.caption).foregroundStyle(.secondary)
            Text("通用软件需 macOS 14.2 及以上，并允许系统音频录制。仅在检测时短暂分析该软件的音量，不保存或上传音频，也不截图。音频方式可能无法识别静音或极低音量播放，首次需有声播放以验证。")
                .font(.caption).foregroundStyle(.secondary)
            Text("缺权限或不能读取时会显示“检测不可用”，不会记作未学习。通知显示受系统通知与专注模式设置影响。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SupervisionSoundPicker: View {
    let settings: SupervisionSoundSettings

    var body: some View {
        Section("监督提醒提示音 · 此 Mac") {
            Text(settings.title).font(.headline).lineLimit(2).textSelection(.enabled)
            HStack {
                Button("选择音频…") { choose() }
                Button("试听") { settings.playPreview() }.disabled(settings.customSoundURL == nil)
                Button("停止试听") { settings.stopPreview() }.disabled(settings.customSoundURL == nil)
                Button("恢复默认") { settings.restoreDefault() }.disabled(settings.selection == nil)
            }.disabled(settings.importing || settings.testing)
            Button(settings.testing ? "正在发送…" : "发送测试通知") {
                Task { await settings.sendTestNotification() }
            }.disabled(settings.importing || settings.testing)
            if settings.importing { ProgressView("正在导入提示音…") }
            Text("选择短于 30 秒、最多 30 MB 的音频，支持 MP3、M4A、WAV、AIFF、CAF 等系统可读取的格式。导入后立即生效；文件会复制保存，原文件移走也可继续使用。此设置仅用于本机的学习监督提醒，不参与同步。")
                .font(.caption).foregroundStyle(.secondary)
            Text("试听用于检查音频；实际通知声音仍受系统通知声音开关、音量和专注模式影响。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = settings.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.onDisappear { settings.stopPreview() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "选择学习监督提示音"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await settings.importSound(from: url) }
        }
    }
}

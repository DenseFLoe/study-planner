import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StudyCore
import StudyPersistence

struct DataBackupView: View {
    @Bindable var store: PlannerStore
    @State private var candidate: PlannerBackup?
    @State private var reviewedState: PlannerState?
    @State private var confirmingRestore = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section("备份与恢复") {
            Text("每次修改前自动保留一份本机备份，最多保留最近 20 份。备份包含课程、课表和学习记录，不包含云同步密钥或此 Mac 的监督设置。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("立即备份") { Task { await store.createBackup() } }
                Button("导出备份…", action: exportBackup)
                Button("从文件恢复…", action: chooseBackup)
            }.disabled(working || store.orderSaveBusy)
            if working { ProgressView("正在处理备份…") }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            if let message = store.backupMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("自动备份保存在本机。导出到其他磁盘可以在设备故障后恢复。恢复前会再次备份当前数据；开启云同步时，恢复操作也会同步到其他设备。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("最近的自动与手动备份") {
            if store.backupEntries.isEmpty { Text("暂时没有备份，可以点击“立即备份”。").foregroundStyle(.secondary) }
            ForEach(store.backupEntries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                        Text("\(entry.reason) · \(entry.courseCount) 门课程").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let id = entry.deletedCourseID, store.course(id) == nil {
                        Button("恢复「\(entry.deletedCourseName ?? "课程")」") {
                            Task { _ = await store.undoCourseDeletion(entry.id) }
                        }
                    }
                    Button("恢复全部…") {
                        Task {
                            do {
                                candidate = try await store.backups.load(entry.id)
                                reviewedState = store.state
                                confirmingRestore = true
                            }
                            catch { message = "无法读取备份，当前数据未改动。" }
                        }
                    }
                }.disabled(working || store.orderSaveBusy || store.syncBusy)
            }
        }
        .confirmationDialog("恢复这份备份？", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("备份当前数据并恢复", role: .destructive) {
                guard let candidate, let reviewedState else { return }
                Task {
                    if await store.restoreBackup(candidate, from: reviewedState) { message = "已恢复备份。恢复前的数据也已保留在列表中。" }
                    self.candidate = nil
                    self.reviewedState = nil
                }
            }
            Button("取消", role: .cancel) { candidate = nil; reviewedState = nil }
        } message: {
            if let candidate {
                Text("备份时间：\(candidate.createdAt.formatted())\n包含 \(candidate.state.courses.count) 门课程、\(candidate.state.completions.count) 条学习记录。\n当前日程：\(reviewedState?.courses.count ?? 0) 门课程、\(reviewedState?.completions.count ?? 0) 条学习记录。\n将替换当前日程；开启云同步时也会同步此改动。")
            }
        }
        .task { await store.refreshBackups() }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "学习日程备份.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = PlannerBackup(state: store.state, reason: "导出备份")
        working = true; message = nil
        Task {
            defer { working = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try PlannerBackupRepository.encode(snapshot).write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }.value
                message = "备份已导出。"
            } catch { message = "导出失败：" + error.localizedDescription }
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; message = nil
        Task {
            defer { working = false }
            do {
                candidate = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try PlannerBackupRepository.read(url)
                }.value
                reviewedState = store.state
                confirmingRestore = true
            } catch { message = "备份无法读取或格式不受支持，当前数据未改动。" }
        }
    }
}

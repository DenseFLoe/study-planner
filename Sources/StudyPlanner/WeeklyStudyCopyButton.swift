import AppKit
import SwiftUI
import StudyCore

struct WeeklyStudyCopyButton: View {
    let day: Date
    let state: PlannerState
    @State private var copying = false
    @State private var message: String?

    var body: some View {
        Button(copying ? "正在整理…" : "复制本周统计", systemImage: "doc.on.doc") {
            let snapshot = state, date = day, calendar = Calendar.current
            copying = true
            Task {
                do {
                    let report = try await Task.detached(priority: .userInitiated) {
                        try WeeklyStudyReport.make(day: date, state: snapshot, calendar: calendar)
                    }.value
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(report.text, forType: .string)
                    message = copied ? "已复制 \(report.rangeLabel) 的周统计" : "无法写入剪贴板，请重试。"
                } catch { message = error.localizedDescription }
                copying = false
            }
        }
        .disabled(copying)
        .help("复制完整课表的每日和课程汇总，分开列出实际已学与计划，不附带备注或来源链接")
        .alert("周学习统计", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }
}

import AppKit
import SwiftUI
import StudyCore

struct DayAgendaCopyButton: View {
    let day: Date
    let state: PlannerState
    @State private var copying = false
    @State private var message: String?

    var body: some View {
        Button(copying ? "正在整理…" : "复制当天安排", systemImage: "doc.on.doc") {
            let snapshot = state, date = day, calendar = Calendar.current
            copying = true
            Task {
                let text = await Task.detached(priority: .userInitiated) {
                    DayAgendaText.make(day: date, state: snapshot, calendar: calendar)
                }.value
                NSPasteboard.general.clearContents()
                let copied = NSPasteboard.general.setString(text, forType: .string)
                copying = false
                message = copied ? "已复制 \(date.formatted(.dateTime.year().month().day())) 的安排" : "无法写入剪贴板，请重试。"
            }
        }
        .disabled(copying)
        .help("复制所选日期的任务、固定事项和完成状态，不附带备注或来源链接")
        .alert("当天安排", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }
}

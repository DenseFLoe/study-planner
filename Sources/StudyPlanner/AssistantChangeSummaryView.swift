import SwiftUI

struct AssistantChangeSummaryView: View {
    let summary: AssistantChangeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("方案预览", systemImage: "calendar.badge.clock")
                    .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Text(summary.title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(summary.highlights.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 64), spacing: 10), count: 3), spacing: 10) {
                metric("新增", value: summary.added, symbol: "plus", color: .teal)
                metric("修改", value: summary.modified, symbol: "pencil", color: .blue)
                metric("删除", value: summary.removed, symbol: "minus", color: .orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.counts.filter { $0.total > 0 }, id: \.category) { count in
                    Text(count.text).font(.callout).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
                if !summary.unchangedCategories.isEmpty {
                    Label(summary.unchangedCategories + "保持不变", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("数量为对象的增删改条数；重排可同时删除旧任务并新增任务，不等于新增学习量。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let chart = summary.workload {
                VStack(alignment: .leading, spacing: 8) {
                    AssistantChartView(chart: chart)
                    Text(AssistantChangeSummary.workloadNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            if summary.conflictCount > 0 || summary.unscheduledDeadlineCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Label("需要留意", systemImage: "exclamationmark.triangle").font(.subheadline.bold())
                    if summary.conflictCount > 0 { Text("排程约束冲突  \(summary.conflictCount) 项") }
                    if summary.unscheduledDeadlineCount > 0 { Text("仍有未排入量的截止日期  \(summary.unscheduledDeadlineCount) 个") }
                    Text("未排入量不代表无解。请在全部差异中核对提醒。")
                        .font(.caption).foregroundStyle(.secondary)
                }.font(.callout).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("生成时的预览 · \(summary.capturedAt)\n保存结果以本机操作记录为准。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .textSelection(.enabled)
    }

    private func metric(_ title: String, value: Int, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            Text(value.formatted()).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title) \(value) 条")
    }
}

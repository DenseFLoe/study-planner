import SwiftUI
import StudyCore

struct ScheduleHealthWarning: View {
    let health: ScheduleHealth
    let adjustments: [String]
    var showDetails: () -> Void
    private var tint: Color {
        switch health.status {
        case .scheduled: .teal
        case .heavy, .pending: .orange
        case .shortage: .red
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(health.title, systemImage: health.status == .scheduled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
            Text(health.explanation).font(.caption).fixedSize(horizontal: false, vertical: true)
            LabeledContent("剩余学习量", value: hours(health.remainingMinutes)).font(.caption)
            if health.unscheduledMinutes > 0 {
                LabeledContent("暂未排入", value: hours(health.unscheduledMinutes)).font(.caption.weight(.semibold)).foregroundStyle(tint)
            }
            if health.pausedMinutes > 0 {
                Text("其中暂停自动排程：\(hours(health.pausedMinutes))，需恢复排程后核对。").font(.caption)
            }
            LabeledContent("后续最重一天", value: hours(health.peakMinutes))
            LabeledContent("有学习安排的日均", value: hours(Int(health.averageMinutes.rounded()))).font(.caption)
            if health.heavyDays > 0 {
                Text("\(health.heavyDays) 天超过你设置的每日负担提醒线。").font(.caption).foregroundStyle(tint)
            }
            if health.reviewedMinutes > 0 {
                Text("今日已确认：实际学习 \(hours(health.creditedMinutes)) / 原计划 \(hours(health.reviewedMinutes))。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !health.recovery.isEmpty {
                Text("已排入的待补内容分布在 \(health.recovery.count) 个日期；点开查看具体安排。")
                    .font(.caption.weight(.medium))
            }
            if let adjustment = adjustments.first { Text(adjustment).font(.caption2).foregroundStyle(.secondary) }
            Button("查看补回安排与每日负担", action: showDetails).buttonStyle(.link).font(.caption)
            Text("截止日期保持不变；科目混排和倍率会在需要时让步。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(tint.opacity(0.4)))
    }
}

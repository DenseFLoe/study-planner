import SwiftUI
import StudyCore

struct StudyLoadWarning: View {
    let load: StudyLoadAssessment

    private var tint: Color {
        switch load.level {
        case .normal: .teal
        case .warning: .orange
        case .critical: .red
        }
    }
    private var title: String {
        if load.isHorizonLimited { return "总学习负荷 · 未来十年内估算" }
        return switch load.level {
        case .normal: "总学习负荷 · 尚有余量"
        case .warning: "时间紧张 · 已达 80% 上限线"
        case .critical: "最高警告 · 已无法按期完成"
        }
    }
    private func daily(_ minutes: Double) -> String {
        (minutes / 60).formatted(.number.precision(.fractionLength(2))) + " 小时"
    }
    private var utilizationText: String {
        guard let ratio = load.utilization else { return "截止前已无可分配时间" }
        let percent = (load.level == .critical ? ceil(ratio * 10000) : floor(ratio * 10000)) / 100
        return "已占可分配时长的 \(percent.formatted(.number.precision(.fractionLength(0...2))))%"
    }
    private var countdown: String {
        if load.isHorizonLimited { return "请将超出范围的课程日期调整到未来十年内，再查看完整负荷与倒计时。" }
        if load.level == .critical { return "请增加可学习时间、减少学习量或延长截止日期。" }
        var lines: [String] = []
        if load.level == .normal, let days = load.daysUntilWarning {
            lines.append("再不学习 \(days) 天 → 时间紧张警告")
        }
        if let days = load.daysUntilCritical {
            lines.append("再不学习 \(days) 天 → 无法按期完成")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: load.level == .critical ? "exclamationmark.octagon.fill" : (load.level == .warning ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(load.level == .normal ? tint : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(load.level == .normal ? tint.opacity(0.12) : tint, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 6) {
                Text("日均最低总学习时间")
                    .font(.caption).foregroundStyle(.secondary)
                Text(daily(load.requiredDailyMinutes))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text("临界日均上限 \(daily(load.criticalDailyMinutes))")
                    .font(.caption.weight(.semibold))
                Text(utilizationText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                if load.level == .critical {
                    Text("\(load.isHorizonLimited ? "计算范围内" : "截止前")至少缺少 \(load.requiredMinutes - load.availableMinutes) 分钟")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                }
            }

            Text(countdown)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Text("最紧张区间：\(load.windowStart.formatted(.dateTime.month().day()))—\(load.deadline.formatted(.dateTime.month().day()))。按完整自然日估算，包含暂停排程的未完成课程。")
                .font(.caption2).foregroundStyle(.secondary)
            Text(load.isHorizonLimited ? "部分课程日期超出支持范围，本次仅计算未来十年。" : "仅扣除每日重复事项，忽略非每日事项。超过理论上限即无法按期完成；未超过仍以实际排程为准。倒计时假设从今天起连续不学习。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(tint.opacity(load.level == .normal ? 0.25 : 0.8), lineWidth: load.level == .normal ? 1 : 2))
        .accessibilityElement(children: .combine)
    }
}

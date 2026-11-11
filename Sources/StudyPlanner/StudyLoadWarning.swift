import SwiftUI
import StudyCore

struct ScheduleHealthWarning: View {
    let health: ScheduleHealth
    let warningMinutes: Int
    var showDetails: () -> Void
    private var tint: Color {
        switch health.status {
        case .scheduled: .teal
        case .heavy, .pending: .orange
        case .shortage: .red
        }
    }
    var body: some View {
        let presentation = ScheduleHealthPresentation(health: health, warningMinutes: warningMinutes)
        VStack(alignment: .leading, spacing: 12) {
            Label(presentation.title, systemImage: health.status == .scheduled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
            ScheduleTimeOverview(presentation: presentation)
            Text(presentation.guidance)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(presentation.loadSummary)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if let peak = health.dayPlans.max(by: { $0.plannedMinutes < $1.plannedMinutes }) {
                DailyStudyTimeBar(day: peak, warningMinutes: presentation.warningMinutes,
                                  scaleMinutes: max(peak.plannedMinutes, presentation.warningMinutes),
                                  title: "最重一天 · \(studyDate(peak.date))")
            }
            if !health.recovery.isEmpty {
                Text("今天未完成的部分内容已安排到 \(health.recovery.count) 个日期，可查看具体补回安排。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("查看课程安排与每日负担", action: showDetails).buttonStyle(.link).font(.callout)
        }
        .padding(16)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(tint.opacity(0.4)))
    }
}

import SwiftUI
import StudyCore

/// Two labelled portions of time. A shared scale keeps daily rows comparable.
struct StudyTimeBar: View {
    let title: String
    let summary: String
    let firstLabel: String
    let firstMinutes: Int
    let secondLabel: String
    let secondMinutes: Int
    var scaleMinutes: Int? = nil
    var markerMinutes: Int? = nil

    var body: some View {
        let first = Double(max(0, firstMinutes))
        let second = Double(max(0, secondMinutes))
        let scale = max(1, first + second, Double(scaleMinutes ?? 0))
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 12)
                    Text(summary).fontWeight(.semibold).monospacedDigit().fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.secondary)
                    Text(summary).fontWeight(.semibold).monospacedDigit()
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                    HStack(spacing: 0) {
                        Color.teal.frame(width: geometry.size.width * first / scale)
                        Color.orange.frame(width: geometry.size.width * second / scale)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    if let markerMinutes, markerMinutes > 0, Double(markerMinutes) <= scale {
                        Rectangle().fill(Color.primary.opacity(0.65))
                            .frame(width: 1, height: 20)
                            .offset(x: min(geometry.size.width - 1, geometry.size.width * Double(markerMinutes) / scale))
                    }
                }
            }
            .frame(height: 14)
            .padding(.vertical, 3)
            .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    legend(firstLabel, minutes: firstMinutes, color: .teal).fixedSize()
                    Spacer(minLength: 0)
                    legend(secondLabel, minutes: secondMinutes, color: .orange).fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    legend(firstLabel, minutes: firstMinutes, color: .teal)
                    legend(secondLabel, minutes: secondMinutes, color: .orange)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func legend(_ label: String, minutes: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text("\(label) · \(studyDuration(max(0, minutes)))").monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ScheduleTimeOverview: View {
    let presentation: ScheduleHealthPresentation

    var body: some View {
        let health = presentation.health
        let planned = max(0, health.remainingMinutes - health.unscheduledMinutes - health.pausedMinutes)
        VStack(alignment: .leading, spacing: 8) {
            StudyTimeBar(title: "剩余学习时间", summary: studyDuration(health.remainingMinutes),
                         firstLabel: "已安排", firstMinutes: planned,
                         secondLabel: "未安排", secondMinutes: health.remainingMinutes - planned)
            if health.pausedMinutes > 0 {
                Text("未安排中，\(studyDuration(health.unscheduledMinutes))待排入日程，\(studyDuration(health.pausedMinutes))因课程暂停自动排程而未安排。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DailyStudyTimeBar: View {
    let day: ScheduleDayPlan
    let warningMinutes: Int
    let scaleMinutes: Int
    var title: String? = nil

    var body: some View {
        StudyTimeBar(title: title ?? studyDate(day.date), summary: "已安排 \(studyDuration(day.plannedMinutes))",
                     firstLabel: "提醒线内", firstMinutes: min(day.plannedMinutes, warningMinutes),
                     secondLabel: "超出提醒线", secondMinutes: max(0, day.plannedMinutes - warningMinutes),
                     scaleMinutes: scaleMinutes, markerMinutes: warningMinutes)
    }
}

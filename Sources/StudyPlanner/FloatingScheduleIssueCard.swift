import SwiftUI
import StudyCore

struct FloatingScheduleIssueCard: View {
    let issue: FloatingScheduleIssue
    var reviewEvents: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(issue.date.formatted(date: .abbreviated, time: .omitted)) · \(issue.isProvenConflict ? "事项时间冲突" : "事项排法待核对")").font(.headline)
            ForEach(issue.events) { event in
                Text("\(event.title) · \(clockTime(event.startMinute))–\(clockTime(event.endMinute))" +
                     (event.isFloating ? " · 浮动占用 \(event.occupiedMinutes) 分钟" : " · 固定时间"))
                    .font(.callout)
            }
            Text(issue.explanation)
            Text(issue.recovery).font(.callout).foregroundStyle(.secondary)
            Button("查看当天事项并调整") { reviewEvents(issue.date) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

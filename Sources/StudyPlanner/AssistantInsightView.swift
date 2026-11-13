import SwiftUI

struct AssistantInsightView: View {
    let insight: AssistantInsight
    private var symbol: String {
        switch insight.kind {
        case .course: "book.closed"
        case .statistics: "chart.xyaxis.line"
        case .schedule: "calendar"
        case .conflicts: "calendar.badge.exclamationmark"
        case .rules: "slider.horizontal.3"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(insight.title, systemImage: symbol).font(.headline).foregroundStyle(.blue)
                Text(insight.subtitle).font(.caption).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(insight.metrics.indices, id: \.self) { index in
                    let metric = insight.metrics[index]
                    VStack(alignment: .leading, spacing: 8) {
                        Text(metric.title).font(.caption).foregroundStyle(.secondary)
                        Text(metric.text).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                    }.fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
                        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .ignore).accessibilityLabel(metric.title + "，" + metric.text)
                }
            }
            if let progress = insight.progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("有效进度").foregroundStyle(.secondary)
                        Spacer()
                        Text(progress.formatted(.percent.precision(.fractionLength(0...1)))).monospacedDigit()
                    }.font(.callout)
                    ProgressView(value: progress).tint(.teal).accessibilityLabel("有效课程进度")
                }
            }
            if let chart = insight.chart { AssistantChartView(chart: chart) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(insight.notes.indices, id: \.self) { index in
                    Text(insight.notes[index]).font(.caption).foregroundStyle(.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
            Text("查询时的数据快照 · " + insight.capturedAt).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .textSelection(.enabled)
    }
}

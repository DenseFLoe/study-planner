import SwiftUI
import Charts
import AppKit

struct AssistantChartView: View {
    let chart: AssistantChart
    @State private var kind: AssistantChart.Kind
    @State private var selectedLabel: String?
    @State private var selectedAngle: Double?
    @State private var showingData = false
    @State private var copied = false
    private let palette: [Color] = [.blue, .orange, .teal, .purple, .pink, .indigo, .brown]

    init(chart: AssistantChart) {
        self.chart = chart
        _kind = State(initialValue: chart.kind)
    }
    private var selectedIndex: Int? {
        if kind == .donut {
            guard let angle = selectedAngle else { return nil }
            var end = 0.0
            for index in chart.labels.indices {
                end += chart.series[0].values[index]
                if angle < end { return index }
            }
            return nil
        }
        return selectedLabel.flatMap { chart.labels.firstIndex(of: $0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chart.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { controls; Spacer(minLength: 12); dataButtons }
                VStack(alignment: .leading, spacing: 10) { controls; dataButtons }
            }
            if showingData { dataTable }
            else {
                if kind == .donut { donut.frame(height: 235) }
                else { cartesian.frame(height: 235) }
                selectionDetails
            }
            Text("生成时的数据快照 · \(chart.capturedAt)")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08), lineWidth: 1))
        .onChange(of: kind) { _, _ in selectedLabel = nil; selectedAngle = nil }
    }
    private var controls: some View {
        Picker("图表类型", selection: $kind) {
            ForEach(AssistantChart.Kind.allCases.filter { $0 != .donut || chart.supportsDonut }, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }.pickerStyle(.segmented).labelsHidden().frame(width: chart.supportsDonut ? 216 : 152)
            .accessibilityLabel("图表类型")
    }
    private var dataButtons: some View {
        HStack(spacing: 12) {
            Button(showingData ? "查看图表" : "查看数据", systemImage: showingData ? "chart.bar" : "tablecells") {
                showingData.toggle()
            }
            Button(copied ? "已复制" : "复制数据", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(chart.tableText, forType: .string)
            }
        }.font(.caption).buttonStyle(.borderless)
    }
    private var cartesian: some View {
        Chart {
            ForEach(chart.series.indices, id: \.self) { seriesIndex in
                let series = chart.series[seriesIndex]
                ForEach(chart.labels.indices, id: \.self) { index in
                    if kind == .bar {
                        BarMark(x: .value("项目", chart.labels[index]), y: .value(chart.unit, series.values[index]))
                            .foregroundStyle(by: .value("序列", series.name))
                            .position(by: .value("序列", series.name))
                            .cornerRadius(3)
                            .accessibilityLabel(chart.labels[index] + "，" + series.name)
                            .accessibilityValue(chart.valueText(series.values[index]) + chart.unit)
                    } else {
                        LineMark(x: .value("项目", chart.labels[index]), y: .value(chart.unit, series.values[index]))
                            .foregroundStyle(by: .value("序列", series.name))
                            .symbol(by: .value("序列", series.name))
                            .interpolationMethod(.linear)
                            .accessibilityLabel(chart.labels[index] + "，" + series.name)
                            .accessibilityValue(chart.valueText(series.values[index]) + chart.unit)
                    }
                }
            }
            if let selectedLabel {
                RuleMark(x: .value("项目", selectedLabel)).foregroundStyle(.secondary.opacity(0.35))
            }
        }
        .chartForegroundStyleScale(domain: chart.series.map(\.name), range: Array(palette.prefix(chart.series.count)))
        .chartXScale(domain: chart.labels)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: axisLabels) { value in
                AxisTick()
                AxisValueLabel {
                    if let label = value.as(String.self) { Text(chart.axisLabel(label)) }
                }
            }
        }
        .chartYAxisLabel(chart.unit)
        .chartXSelection(value: $selectedLabel)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let bounds = geometry[frame]
                            selectedLabel = bounds.contains(location) ? proxy.value(atX: location.x - bounds.minX, as: String.self) : nil
                        case .ended: selectedLabel = nil
                        }
                    }
            }
        }
    }
    private var axisLabels: [String] {
        let stride = max(1, Int(ceil(Double(chart.labels.count) / 6)))
        return chart.labels.indices.filter { $0 % stride == 0 || $0 == chart.labels.count - 1 }.map { chart.labels[$0] }
    }
    private var donut: some View {
        Chart(chart.labels.indices, id: \.self) { index in
            SectorMark(angle: .value(chart.unit, chart.series[0].values[index]), innerRadius: .ratio(0.62))
                .foregroundStyle(by: .value("项目", chart.labels[index]))
                .opacity(selectedIndex == nil || selectedIndex == index ? 1 : 0.4)
                .accessibilityLabel(chart.labels[index])
                .accessibilityValue(chart.valueText(chart.series[0].values[index]) + chart.unit)
        }
        .chartForegroundStyleScale(domain: chart.labels, range: Array(palette.prefix(chart.labels.count)))
        .chartAngleSelection(value: $selectedAngle)
    }
    private var selectionDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let index = selectedIndex {
                Text(chart.labels[index]).fontWeight(.medium)
                ForEach(chart.series.indices, id: \.self) { series in
                    Text("\(chart.series[series].name)：\(chart.valueText(chart.series[series].values[index]))\(chart.unit)")
                }
            } else {
                Text(kind == .donut ? "点击扇区查看数值，也可切换到数据表。" : "指向或点击图表查看数值，也可切换到数据表。")
                    .foregroundStyle(.secondary)
            }
        }.font(.caption).monospacedDigit().frame(minHeight: 38, alignment: .topLeading)
    }
    private var dataTable: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Text("项目").fontWeight(.semibold)
                    ForEach(chart.series.indices, id: \.self) { index in
                        Text(chart.series[index].name + (chart.unit.isEmpty ? "" : "（\(chart.unit)）")).fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(chart.labels.indices, id: \.self) { index in
                    GridRow {
                        Text(chart.labels[index])
                        ForEach(chart.series.indices, id: \.self) { series in
                            Text(chart.valueText(chart.series[series].values[index])).monospacedDigit()
                        }
                    }
                }
            }.font(.callout).padding(4).textSelection(.enabled)
        }.frame(height: min(270, CGFloat(chart.labels.count + 1) * 32 + 16))
    }
}

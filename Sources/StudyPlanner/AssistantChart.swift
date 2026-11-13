import Foundation
import CoreFoundation

/// A small native answer component. Only resolved, bounded data reaches Swift Charts.
struct AssistantChart: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case bar, line, donut
        var title: String {
            switch self { case .bar: "柱状图"; case .line: "折线图"; case .donut: "环形图" }
        }
    }
    struct Series: Codable, Equatable, Sendable {
        let name: String
        let values: [Double]
    }
    let title: String
    let kind: Kind
    let unit: String
    let labels: [String]
    let series: [Series]
    let capturedAt: String

    var supportsDonut: Bool {
        series.count == 1 && labels.count <= 7 && series[0].values.allSatisfy { $0 >= 0 }
            && series[0].values.contains { $0 > 0 }
    }
    func validate() throws {
        func short(_ text: String, limit: Int) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit
                && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard short(title, limit: 100), unit.count <= 20, short(capturedAt, limit: 64),
              (1...31).contains(labels.count), Set(labels).count == labels.count,
              labels.allSatisfy({ short($0, limit: 60) }), (1...4).contains(series.count),
              Set(series.map(\.name)).count == series.count,
              series.allSatisfy({ short($0.name, limit: 60) && $0.values.count == labels.count
                  && $0.values.allSatisfy { $0.isFinite && abs($0) <= 1e12 } }),
              kind != .donut || supportsDonut else { throw AssistantError.protocolError }
    }
    static func decode(_ source: String) -> Self? {
        guard source.utf8.count <= 24_000, let value = try? JSONDecoder().decode(Self.self, from: Data(source.utf8)),
              (try? value.validate()) != nil else { return nil }
        return value
    }
    func valueText(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
    /// Compact axis captions only; selection, copied data and tables retain full dates.
    func axisLabel(_ label: String) -> String {
        if label.count == 10 {
            let parts = label.split(separator: "-")
            if parts.count == 3, parts[0].count == 4, Int(parts[0]) != nil,
               let month = Int(parts[1]), let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day) {
                return "\(month)/\(day)"
            }
        }
        let parts = label.components(separatedBy: " · ")
        if parts.count == 2, let index = Int(parts[0]), parts[1].count == 10, axisLabel(parts[1]) != parts[1] {
            return "窗口\(index)"
        }
        return label
    }
    var tableText: String {
        ([(["项目"] + series.map { $0.name + (unit.isEmpty ? "" : "（\(unit)）") }).joined(separator: "\t")]
            + labels.indices.map { row in ([labels[row]] + series.map { valueText($0.values[row]) }).joined(separator: "\t") })
            .joined(separator: "\n")
    }
}

enum AssistantCharts {
    static let unavailable = "图表未生成：数据缺失或格式不支持。可让助手重新查询后生成。"
    static let instructions = """
    Mac 回答支持原生图表。用户要求图表时，或多日趋势、课程对比、完成占比明显适合可视化时，先查询，再在回答对应位置输出 study-chart 围栏代码块；程序会将其渲染为图表，不解释 JSON。
    格式：{"title":"课程进度","kind":"bar","unit":"分钟","labels":["已完成","剩余"],"series":[{"name":"有效进度","values":["E2.data.completed_minutes","E2.data.remaining_minutes"]}]}。
    kind 仅 bar（对比）、line（按时间顺序的趋势）、donut（同一总量的组成）。每条 values 必须是本轮工具证据中真实数值的路径，不能填写数字、表达式、旧轮证据或自行构造数据；本机会解析引用。每条序列与 labels 等长，标签和序列名称不重复。最多3张图、每图31个标签、4条同单位序列；donut仅1条非负序列、最多7项且总量大于0。所有值为0时使用柱状图。
    标题、标签、序列名与单位必须准确反映查询口径；实际学习分钟、有效进度和计划分钟不可混淆。计划按任务开始日统计，日期不明的实际学习量须在正文单独说明，不能放进某日。缺失值不能冒充0。图表是本轮快照，不代表实时更新，也不修改日程。不需要图表时仍正常用文字回答。
    """

    private struct Request: Decodable {
        struct Series: Decodable { let name: String; let values: [String] }
        let title: String
        let kind: AssistantChart.Kind
        let unit: String
        let labels: [String]
        let series: [Series]
    }

    static func resolve(_ source: String, evidence: [AssistantToolEvidence], capturedAt: String) throws -> AssistantChart {
        guard source.utf8.count <= 16_000 else { throw AssistantError.limit }
        let request = try JSONDecoder().decode(Request.self, from: Data(source.utf8))
        guard request.labels.count <= 31, request.series.count <= 4 else { throw AssistantError.limit }
        var objects: [String: Any] = [:]
        for item in evidence { objects[item.id] = try JSONSerialization.jsonObject(with: Data(item.json.utf8)) }
        func number(_ path: String) throws -> Double {
            let parts = path.components(separatedBy: ".")
            guard path.utf8.count <= 160, parts.count >= 3, parts.count <= 12, parts[1] == "data",
                  var value = objects[parts[0]] else { throw AssistantError.protocolError }
            for part in parts.dropFirst() {
                if let dict = value as? [String: Any], let next = dict[part] { value = next }
                else if let array = value as? [Any], let index = Int(part), String(index) == part,
                        array.indices.contains(index) { value = array[index] }
                else { throw AssistantError.protocolError }
            }
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { throw AssistantError.protocolError }
            return value.doubleValue
        }
        let chart = AssistantChart(title: request.title, kind: request.kind, unit: request.unit, labels: request.labels,
            series: try request.series.map { series in
                guard series.values.count == request.labels.count else { throw AssistantError.protocolError }
                return .init(name: series.name, values: try series.values.map(number))
            }, capturedAt: capturedAt)
        try chart.validate()
        return chart
    }

    /// Resolve before saving the answer. No model-provided numbers are trusted as chart data.
    /// Other code fences are opaque, and a broken chart never discards the surrounding answer.
    static func materialize(_ answer: String, evidence: [AssistantToolEvidence], capturedAt: String) -> String {
        let lines = answer.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = [], index = 0, count = 0
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            guard trimmed.hasPrefix("```") else { output.append(line); continue }
            var body: [String] = []
            while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces) != "```" {
                body.append(lines[index]); index += 1
            }
            let closed = index < lines.count
            if closed { index += 1 }
            guard trimmed == "```study-chart" else {
                output += [line] + body + (closed ? ["```"] : []); continue
            }
            count += 1
            if closed, count <= 3,
               let chart = try? resolve(body.joined(separator: "\n"), evidence: evidence, capturedAt: capturedAt),
               let data = try? assistantJSON(chart) {
                output += ["```study-chart", String(decoding: data, as: UTF8.self), "```"]
            } else { output.append(unavailable) }
        }
        return output.joined(separator: "\n")
    }
}

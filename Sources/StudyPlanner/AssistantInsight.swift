import Foundation
import CoreFoundation

/// Read-only presentation built exclusively from this turn's successful local queries.
/// Stores display values, never planner state, tool identifiers, or executable actions.
struct AssistantInsight: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case course, statistics, schedule, conflicts, rules }
    struct Metric: Codable, Equatable, Sendable {
        let title: String
        let value: Double
        let unit: String
        var text: String { value.formatted(.number.precision(.fractionLength(0...1))) + " " + unit }
    }
    let kind: Kind
    let title: String
    let subtitle: String
    let metrics: [Metric]
    var progress: Double?
    var chart: AssistantChart?
    let notes: [String]
    let capturedAt: String

    var plainText: String {
        ([title, subtitle] + metrics.map { $0.title + "：" + $0.text } + notes
            + (chart.map { [$0.title, $0.tableText] } ?? []) + ["查询时的数据快照 · " + capturedAt]).joined(separator: "\n")
    }
    func validate() throws {
        guard !title.isEmpty, title.count <= 200, subtitle.count <= 300, capturedAt.count <= 100,
              (1...4).contains(metrics.count), metrics.allSatisfy({
                  !$0.title.isEmpty && $0.title.count <= 80 && $0.unit.count <= 20
                      && $0.value.isFinite && (0...1e12).contains($0.value)
              }), notes.count <= 8, notes.allSatisfy({ $0.count <= 1000 }),
              progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw AssistantError.history }
        try chart?.validate()
    }
}

struct AssistantInsightQuery: Sendable {
    let name: String
    let input: [String: String]
    let evidence: AssistantToolEvidence
}

enum AssistantInsights {
    static let instructions = """
    Mac 会根据本轮实际查询自动附上课程进度卡（含进度条）、学习统计卡（含每日实际/计划图）、日程核对卡、排程分析卡和规则卡。回答先给简短结论，再解释趋势、风险或下一步，不重复逐项抄写卡片数字。自动卡仅覆盖已查询范围；不要为填满卡片多查无关数据。只有额外的对比角度才输出 study-chart，避免重复相同图表。修改预览已有独立方案卡。
    """

    static func build(_ queries: [AssistantInsightQuery], answer: String) -> [AssistantInsight] {
        var result: [AssistantInsight] = [], positions: [String: Int] = [:]
        let existingCharts = AssistantMarkdown.blocks(answer).compactMap { block -> AssistantChart? in
            if case .chart(let chart) = block { return chart }; return nil
        }
        for query in queries.prefix(24) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(query.evidence.json.utf8)) as? [String: Any],
                  let data = object["data"] as? [String: Any], let stamp = object["captured_at"] as? String else { continue }
            let capturedAt = stamp + " " + (object["time_zone"] as? String ?? "")
            func number(_ key: String, in source: [String: Any]? = nil) -> Double? {
                guard let value = (source ?? data)[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, (0...1e12).contains(value.doubleValue) else { return nil }
                return value.doubleValue
            }
            func metric(_ title: String, _ value: Double, _ unit: String = "分钟") -> AssistantInsight.Metric {
                .init(title: title, value: value, unit: unit)
            }
            var key: String
            var card: AssistantInsight
            switch query.name {
            case "inspect_course":
                guard let id = data["course_id"] as? String, let name = data["untrusted_name"] as? String,
                      let total = number("total_minutes"), let completed = number("completed_minutes"),
                      let remaining = number("remaining_minutes"), let deadline = data["deadline"] as? String else { continue }
                key = "course:" + id
                card = .init(kind: .course, title: name.isEmpty ? "课程进度" : name, subtitle: "课程进度 · 截止 " + deadline,
                    metrics: [metric("有效完成", completed), metric("剩余学习量", remaining), metric("课程总量", total)],
                    progress: total > 0 ? min(1, completed / total) : nil,
                    notes: ["按有效课程进度统计，与实际学习用时不同。"], capturedAt: capturedAt)
            case "inspect_progress":
                guard let days = data["days"] as? [[String: Any]], (1...31).contains(days.count),
                      let unknown = number("unknown_date_minutes") else { continue }
                let dates = days.compactMap { $0["date"] as? String }
                let actual = days.compactMap { number("actual_minutes", in: $0) }
                let planned = days.compactMap { number("planned_by_start_day_minutes", in: $0) }
                guard dates.count == days.count, actual.count == days.count, planned.count == days.count else { continue }
                let scope = query.input["course", default: ""]
                let courseName = queries.first(where: { $0.name == "inspect_course" && $0.input["course"] == scope })
                    .flatMap { try? JSONSerialization.jsonObject(with: Data($0.evidence.json.utf8)) as? [String: Any] }
                    .flatMap { ($0["data"] as? [String: Any])?["untrusted_name"] as? String }
                let range = dates.first! + " 至 " + dates.last!
                key = "statistics:" + scope + ":" + range
                card = .init(kind: .statistics, title: "学习统计", subtitle: (scope.isEmpty ? "全部课程" : (courseName ?? "指定课程")) + " · " + range,
                    metrics: [metric("实际学习", actual.reduce(0, +)), metric("计划学习", planned.reduce(0, +)), metric("日期不明", unknown)],
                    chart: .init(title: "每日实际与计划", kind: days.count > 1 ? .line : .bar, unit: "分钟", labels: dates,
                        series: [.init(name: "实际学习", values: actual), .init(name: "计划学习", values: planned)], capturedAt: capturedAt),
                    notes: ["实际学习用时不等于有效课程进度；计划量按任务开始日统计，跨日任务未拆分。",
                            "日期不明为所选课程全部无日期记录，未计入所选日期范围的合计与图表。"], capturedAt: capturedAt)
            case "inspect_schedule", "inspect_time_conflicts":
                let check = query.name == "inspect_schedule" ? data["time_check"] as? [String: Any] : data
                guard let check, let date = check["date"] as? String,
                      let overlaps = number("fixed_overlap_count", in: check), let floating = number("floating_window_count", in: check),
                      let deficits = number("proven_floating_deficit_count", in: check), let invalid = number("invalid_entry_count", in: check),
                      let excluded = number("excluded_confirmed_task_count", in: check) else { continue }
                key = "schedule:" + date
                var notes = ["固定时段按重叠对数统计；浮动窗口不等于实际占用，容量不足与时间重叠分开核对。",
                             "已排除 \(Int(excluded)) 条已确认或历史任务，其原计划不代表实际学习时段。"]
                if invalid > 0 { notes.append("有 \(Int(invalid)) 条无效数据未能核实，不能据此判断没有冲突。") }
                if check["joint_floating_status"] as? String == "not_verified" { notes.append("多个浮动窗口能否同时排入：尚未核实。") }
                if check["next_offset"] is String { notes.append("数量覆盖当天全部核对结果；冲突明细尚有未读取的分页。") }
                // Both tools expose the same full-day counts, even on later detail pages.
                card = .init(kind: .schedule, title: "日程核对", subtitle: date + " · 已保存的安排",
                    metrics: [metric("固定时段重叠", overlaps, "对"), metric("浮动窗口", floating, "项"), metric("已证实容量不足", deficits, "项")],
                    notes: notes, capturedAt: capturedAt)
            case "inspect_conflicts":
                guard let total = number("total"), data["rows"] is [[String: Any]] else { continue }
                key = "conflicts"
                // Rebuild from distinct queried pages; never count a repeated page twice.
                var pages: [String: [[String: Any]]] = [:]
                for item in queries where item.name == "inspect_conflicts" {
                    if let object = try? JSONSerialization.jsonObject(with: Data(item.evidence.json.utf8)) as? [String: Any],
                       let payload = object["data"] as? [String: Any], let values = payload["rows"] as? [[String: Any]] {
                        pages[item.input["offset", default: "0"]] = values
                    }
                }
                let allRows = pages.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.flatMap { pages[$0] ?? [] }
                let constraints = allRows.filter { $0["kind"] as? String == "constraint" }
                let risks = allRows.filter { $0["kind"] as? String == "unbooked" }
                let complete = Double(allRows.count) == total
                let chartRows = Array(constraints.prefix(12))
                let required = chartRows.compactMap { number("required_minutes", in: $0) }
                let available = chartRows.compactMap { number("available_minutes", in: $0) }
                let chart: AssistantChart? = !chartRows.isEmpty && required.count == chartRows.count && available.count == chartRows.count
                    ? .init(title: "已读约束窗口的需求与可用量", kind: .bar, unit: "分钟",
                        labels: chartRows.enumerated().map { "\($0.offset + 1) · \($0.element["deadline"] as? String ?? "未知日期")" },
                        series: [.init(name: "所需时间", values: required), .init(name: "可用时间", values: available)], capturedAt: capturedAt) : nil
                card = .init(kind: .conflicts, title: "排程分析", subtitle: "当前已保存课表 · 容量与规则",
                    metrics: [metric("提醒总数", total, "项"), metric("已读约束冲突", Double(constraints.count), "项"), metric("已读未排入截止日期", Double(risks.count), "个")], chart: chart,
                    notes: [complete ? "已读取全部提醒。" : "仅读取 \(allRows.count)/\(Int(total)) 项提醒，分类数量仅覆盖已读部分。",
                            "未排入量不代表客观缺口或无解；此评估不判断实际时段是否重叠。",
                            "图表最多展示 12 个已读约束窗口；窗口可能相互重叠，不可相加。休息与连续时段约束仍须结合文字分析。"], capturedAt: capturedAt)
            case "inspect_rules":
                guard let minimum = number("minimum_block_minutes"), let rest = number("break_minutes"),
                      let order = data["priority_order"] as? [String] else { continue }
                key = "rules"
                card = .init(kind: .rules, title: "排程规则", subtitle: "当前保存的设置",
                    metrics: [metric("最小学习块", minimum), metric("休息间隔", rest)],
                    notes: ["优先顺序：" + order.joined(separator: " → "), "均摊和每日倍率是偏好，不是每日硬上限；最终余量可短于最小学习块。"], capturedAt: capturedAt)
            default: continue
            }
            if let chart = card.chart, existingCharts.contains(where: {
                $0.unit == chart.unit && $0.series == chart.series && $0.labels == chart.labels
            }) { card.chart = nil }
            guard (try? card.validate()) != nil else { continue }
            if let position = positions[key] { result[position] = card }
            else { positions[key] = result.count; result.append(card) }
        }
        return result
    }
}

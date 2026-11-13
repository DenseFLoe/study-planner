import SwiftUI

struct AssistantUsageBar: View {
    let usage: AssistantTurnUsage?
    let busy: Bool
    let hasHistory: Bool
    @State private var showingDetails = false
    private var cost: String {
        guard let usage else { return hasHistory ? "本轮费用未记录" : "本轮 ¥0" }
        if busy && usage.requests > usage.responses { return "本轮计费中…" }
        return usage.costLabel
    }
    var body: some View {
        Button { showingDetails = true } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    Label(requestText, systemImage: "gauge.with.dots.needle.33percent")
                    Label(tokenText, systemImage: "cylinder.split.1x2")
                    Label(cost, systemImage: "yensign.circle")
                }
                HStack(spacing: 12) {
                    Text(usage.map { "\($0.requests) 次请求" } ?? (hasHistory ? "未记录" : "0 次请求"))
                    Text(usage?.tokenLabel ?? (hasHistory ? "用量未记录" : "0 tok"))
                    Text(cost)
                }
                Text(cost)
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            .padding(.vertical, 3).frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("本轮用量与费用，" + cost)
        .help("查看本轮请求、用量和费用明细")
        .popover(isPresented: $showingDetails, arrowEdge: .top) { details }
    }
    private var requestText: String {
        guard let usage else { return hasHistory ? "请求未记录" : "0 次请求 · 0 次查询" }
        var text = "\(usage.requests) 次请求 · \(usage.tools) 次查询"
        if usage.requestSeconds > 0 {
            text += String(format: " · 平均 %.1f tok/s", Double(usage.output) / usage.requestSeconds)
        }
        return text
    }
    private var tokenText: String {
        let text = usage?.tokenLabel ?? (hasHistory ? "用量未记录" : "0 tok")
        return text + (usage?.cacheLabel.map { " · " + $0 } ?? "")
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本轮用量与费用").font(.headline)
            Text(cost).font(.title3.weight(.semibold)).monospacedDigit()
            if let usage {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                    row("模型请求 / 本机查询", "\(usage.requests) / \(usage.tools)")
                    row("输入 / 输出 token", "\(usage.input) / \(usage.output)")
                    row("缓存命中 token", "\(usage.cachedInput)")
                    row("已返回用量", "\(usage.measuredResponses) / \(usage.requests) 次请求")
                    if usage.requestSeconds > 0 {
                        row("请求总耗时", String(format: "%.1f 秒", usage.requestSeconds))
                        row("平均输出速度", String(format: "%.1f tok/s", Double(usage.output) / usage.requestSeconds))
                    }
                    if usage.pricedResponses > 0 && usage.pricedResponses < usage.requests {
                        row("已知部分费用", "约 " + usage.cost.text)
                    }
                }.font(.caption).monospacedDigit()
                if let date = usage.priceCheckedAt {
                    Text("价格检查：" + date.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(usage.priceNotice.isEmpty ? "尚未发出模型请求。" : usage.priceNotice)
                    .font(.caption).foregroundStyle(.secondary)
                if usage.requests > usage.pricedResponses && !usage.simulated {
                    Text("缺少费用的请求可能仍已扣费，不按 0 元计算。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if usage.cost.lower != usage.cost.upper {
                    Text("跨计费时段或节假日信息未确认时，显示估算范围。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("本轮包含这条消息触发的全部模型请求和自动重新查询。平均速度包含网络等待；本机查询不额外计模型费用。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(hasHistory ? "旧对话未保存用量，无法补算历史花费。新发送的消息会开始记录。" : "发送消息后统计本轮用量与估算花费。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Link("查看 DeepSeek 官方价格", destination: AssistantPriceBook.source).font(.caption)
        }.padding(18).frame(width: 310).fixedSize(horizontal: false, vertical: true)
    }
    private func row(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value) }
    }
}

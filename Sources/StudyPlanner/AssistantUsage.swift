import Foundation
import CoreFoundation

struct AssistantTokenUsage: Codable, Equatable, Sendable {
    /// Total input, including cache reads/writes; reasoning is already part of output.
    let input: Int
    let output: Int
    let cachedInput: Int?
    let cacheWrite: Int
    var total: Int { input + output }

    static func parse(_ response: String, provider: AssistantProvider) -> Self? {
        guard response.utf8.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }
        func count(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let n = number.doubleValue
            guard n.isFinite, n >= 0, n <= 1_000_000_000, n.rounded() == n else { return nil }
            return Int(n)
        }
        if provider == .anthropic {
            guard let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]) else { return nil }
            let read = count(usage["cache_read_input_tokens"] ?? 0), write = count(usage["cache_creation_input_tokens"] ?? 0)
            guard let read, let write else { return nil }
            return .init(input: input + read + write, output: output, cachedInput: read, cacheWrite: write)
        }
        guard let input = count(usage["prompt_tokens"]), let output = count(usage["completion_tokens"]) else { return nil }
        if let total = usage["total_tokens"], count(total) != input + output { return nil }
        let details = usage["prompt_tokens_details"] as? [String: Any]
        let cachedRaw = usage["prompt_cache_hit_tokens"] ?? details?["cached_tokens"]
        let cached = count(cachedRaw)
        guard cachedRaw == nil || (cached != nil && cached! <= input) else { return nil }
        if let raw = usage["prompt_cache_miss_tokens"] {
            guard let miss = count(raw), let cached, miss + cached == input else { return nil }
        }
        if let raw = details?["cached_tokens"], let cached, count(raw) != cached { return nil }
        guard let write = count(details?["cache_write_tokens"] ?? 0), write + (cached ?? 0) <= input else { return nil }
        return .init(input: input, output: output, cachedInput: cached, cacheWrite: write)
    }
}

struct AssistantCostEstimate: Codable, Equatable, Sendable {
    var lower: Double
    var upper: Double
    var text: String {
        func money(_ amount: Double) -> String {
            if amount > 0 && amount < 0.000001 { return "<0.000001" }
            return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), amount)
                .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        }
        return lower == upper ? "¥" + money(upper) : "¥" + money(lower) + "–" + money(upper)
    }
}

enum AssistantUsageEvent: Sendable {
    case requestStarted
    case response(AssistantTokenUsage?, start: Date, end: Date, seconds: Double)
    case tool
}

struct AssistantTurnUsage: Codable, Equatable, Sendable {
    var requests = 0
    var responses = 0
    var tools = 0
    var measuredResponses = 0
    var input = 0
    var output = 0
    var cachedInput = 0
    var cacheResponses = 0
    var requestSeconds: Double = 0
    var pricedResponses = 0
    var cost = AssistantCostEstimate(lower: 0, upper: 0)
    var priceCheckedAt: Date?
    var priceNotice = ""
    var simulated = false

    var valid: Bool {
        (0...32).contains(requests) && (0...requests).contains(responses) && (0...96).contains(tools)
            && (0...responses).contains(measuredResponses) && (0...measuredResponses).contains(pricedResponses)
            && (0...measuredResponses).contains(cacheResponses)
            && (0...96_000_000_000).contains(input) && (0...32_000_000_000).contains(output)
            && (0...input).contains(cachedInput) && requestSeconds.isFinite && (0...1e7).contains(requestSeconds)
            && cost.lower.isFinite && cost.upper.isFinite && (0...1e15).contains(cost.lower)
            && (cost.lower...1e15).contains(cost.upper) && priceNotice.utf8.count < 2000
    }

    mutating func record(_ event: AssistantUsageEvent, pricing: AssistantPricingResult, model: String) {
        switch event {
        case .requestStarted: requests += 1
        case .tool: tools += 1
        case .response(let tokens, let start, let end, let seconds):
            responses += 1
            guard let tokens else { return }
            measuredResponses += 1; input += tokens.input; output += tokens.output
            requestSeconds += max(0, seconds)
            if let cached = tokens.cachedInput { cacheResponses += 1; cachedInput += cached }
            if simulated { pricedResponses += 1 }
            else if let amount = pricing.book?.estimate(tokens, model: model, start: start, end: end) {
                pricedResponses += 1; cost.lower += amount.lower; cost.upper += amount.upper
            } else if let book = pricing.book, !book.isFresh(at: end) {
                priceNotice = "价格待更新：本轮进行期间价格缓存已过期，部分请求未估算费用。"
            } else if pricing.book != nil && tokens.cachedInput == nil {
                priceNotice = "接口未返回缓存用量，暂时无法按缓存单价估算本轮费用。"
            }
        }
    }
    var costLabel: String {
        if simulated { return "模拟 ¥0" }
        if requests == 0 { return "本轮 ¥0" }
        if pricedResponses == requests { return "本轮约 " + cost.text }
        if pricedResponses > 0 { return "本轮费用不完整" }
        if measuredResponses > 0 && priceCheckedAt == nil {
            return priceNotice.hasPrefix("价格待更新") ? "本轮价格待更新" : "本轮费用未知"
        }
        return "本轮费用待核实"
    }
    var tokenLabel: String {
        guard measuredResponses > 0 else { return requests == 0 ? "0 tok" : "用量待返回" }
        let number = input + output
        let text = number >= 1_000_000 ? String(format: "%.1fM", Double(number) / 1_000_000)
            : number >= 1000 ? String(format: "%.1fK", Double(number) / 1000) : String(number)
        return (measuredResponses < requests ? "已知 " : "") + text + " tok"
    }
    var cacheLabel: String? {
        guard cacheResponses == requests, requests > 0, input > 0 else { return nil }
        return "命中 " + String(format: "%.0f%%", Double(cachedInput) / Double(input) * 100)
    }
}

import Foundation

/// Public prices only. This file never receives an API credential, chat, or planner data.
struct AssistantPriceBook: Codable, Equatable, Sendable {
    struct Rates: Codable, Equatable, Sendable {
        let input: Double
        let cachedInput: Double
        let output: Double
        var valid: Bool { [input, cachedInput, output].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 } }
    }
    struct Model: Codable, Equatable, Sendable {
        let offPeak: Rates
        let peak: Rates
    }
    let checkedAt: Date
    let models: [String: Model]
    static let source = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/")!
    static let lifetime: TimeInterval = 86_400

    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(checkedAt)
        return age >= -300 && age < Self.lifetime && !models.isEmpty && models.count <= 20
            && models.values.allSatisfy { $0.offPeak.valid && $0.peak.valid }
    }
    static func supports(_ configuration: AssistantConfiguration) -> Bool {
        guard let url = URLComponents(string: configuration.baseURL), url.scheme == "https",
              url.host?.lowercased() == "api.deepseek.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return ["", "/", "/v1", "/v1/", "/anthropic", "/anthropic/"].contains(url.path)
    }

    /// Parse only the labelled CNY table and the explicitly supported time rule.
    /// A new layout/rule fails closed instead of silently reusing a different billing scheme.
    static func parse(_ html: String, at date: Date) throws -> Self {
        guard html.utf8.count <= 1_048_576 else { throw AssistantError.protocolError }
        let plain = clean(html)
        let rule = "北京时间周一至周五（不含中国法定节假日）9:00-12:00、14:00-18:00为高峰时段"
        guard plain.contains(rule), plain.contains("包括周末及中国法定节假日全天均为空闲时段") else {
            throw AssistantError.protocolError
        }
        for table in matches(#"(?is)<table\b[^>]*>(.*?)</table>"#, html) {
            let rows = try grid(table[1])
            guard let header = rows.first, header.count >= 4, header[0] == "模型" else { continue }
            let names = Array(header.dropFirst(3))
            guard names.count <= 20, Set(names).count == names.count,
                  names.allSatisfy({ $0.range(of: #"^deepseek-[a-z0-9.-]+$"#, options: .regularExpression) != nil }) else {
                throw AssistantError.protocolError
            }
            let prices = rows.filter { $0.first == "价格" }
            guard prices.count == 6, prices.allSatisfy({ $0.count == header.count }) else { throw AssistantError.protocolError }
            var models: [String: Model] = [:]
            for (index, name) in names.enumerated() {
                func rate(_ category: String, _ period: String) throws -> Double {
                    let matching = prices.filter { $0[1] == category && $0[2] == period }
                    guard matching.count == 1 else { throw AssistantError.protocolError }
                    let value = matching[0][index + 3]
                    guard value.range(of: #"^[0-9]+(?:\.[0-9]+)?元$"#, options: .regularExpression) != nil,
                          let number = Double(value.dropLast()), number.isFinite, number <= 1_000_000 else {
                        throw AssistantError.protocolError
                    }
                    return number
                }
                func rates(_ period: String) throws -> Rates {
                    try .init(input: rate("百万tokens输入（缓存未命中）", period),
                              cachedInput: rate("百万tokens输入（缓存命中）", period), output: rate("百万tokens输出", period))
                }
                models[name] = try .init(offPeak: rates("空闲时段"), peak: rates("高峰时段"))
            }
            return .init(checkedAt: date, models: models)
        }
        throw AssistantError.protocolError
    }
    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    private static func clean(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?is)<sup\b[^>]*>.*?</sup>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: "")
            .replacingOccurrences(of: #"[\s\u200B]+"#, with: "", options: .regularExpression)
    }
    private static func grid(_ table: String) throws -> [[String]] {
        let rawRows = matches(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, table)
        guard rawRows.count <= 64 else { throw AssistantError.protocolError }
        var cells: [Int: String] = [:], output: [[String]] = []
        for (r, row) in rawRows.enumerated() {
            var c = 0
            for cell in matches(#"(?is)<t[dh]\b([^>]*)>(.*?)</t[dh]>"#, row[1]) {
                while cells[r * 32 + c] != nil && c < 32 { c += 1 }
                func span(_ name: String) throws -> Int {
                    let values = matches("(?i)" + name + #"\s*=\s*[\"']?([0-9]+)"#, cell[1])
                    guard values.count <= 1 else { throw AssistantError.protocolError }
                    let value = values.first.flatMap { Int($0[1]) } ?? 1
                    guard (1...20).contains(value) else { throw AssistantError.protocolError }
                    return value
                }
                let width = try span("colspan"), height = try span("rowspan")
                guard c + width <= 32, r + height <= rawRows.count else { throw AssistantError.protocolError }
                let text = clean(cell[2])
                for rr in r..<(r + height) { for cc in c..<(c + width) {
                    guard cells[rr * 32 + cc] == nil else { throw AssistantError.protocolError }
                    cells[rr * 32 + cc] = text
                } }
                c += width
            }
            let last = (0..<32).last { cells[r * 32 + $0] != nil } ?? -1
            output.append(last < 0 ? [] : (0...last).map { cells[r * 32 + $0] ?? "" })
        }
        return output
    }

    /// Unknown holiday years yield a range during weekday peak hours.
    /// 2026 calendar: State Council notice 国办发明电〔2025〕7号.
    static func peak(at date: Date) -> Bool? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let p = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let minute = (p.hour ?? 0) * 60 + (p.minute ?? 0)
        guard (2...6).contains(p.weekday ?? 0), (540..<720).contains(minute) || (840..<1080).contains(minute) else { return false }
        guard p.year == 2026 else { return nil }
        let day = (p.month ?? 0) * 100 + (p.day ?? 0)
        let holidays = [101...103, 215...223, 404...406, 501...505, 619...621, 925...927, 1001...1007]
        return !holidays.contains { $0.contains(day) }
    }
    func estimate(_ tokens: AssistantTokenUsage, model: String, start: Date, end: Date) -> AssistantCostEstimate? {
        guard isFresh(at: end), let price = models[model], let cached = tokens.cachedInput,
              tokens.cacheWrite == 0 else { return nil }
        func amount(_ rates: Rates) -> Double {
            (Double(tokens.input - cached) * rates.input + Double(cached) * rates.cachedInput
                + Double(tokens.output) * rates.output) / 1_000_000
        }
        let startPeak = Self.peak(at: start), endPeak = Self.peak(at: end)
        if let startPeak, startPeak == endPeak {
            let value = amount(startPeak ? price.peak : price.offPeak)
            return .init(lower: value, upper: value)
        }
        let a = amount(price.offPeak), b = amount(price.peak)
        return .init(lower: min(a, b), upper: max(a, b))
    }
}

struct AssistantPricingResult: Sendable {
    var book: AssistantPriceBook?
    var notice: String
    static let simulated = Self(notice: "合成验收，不会联网或产生费用。")
    static let unsupported = Self(notice: "当前仅自动读取 DeepSeek 官方人民币价格；此接口的费用暂不可用。")
}

actor AssistantPriceStore {
    static let shared = AssistantPriceStore()
    private struct Cache: Codable { var lastAttempt: Date?; var book: AssistantPriceBook?; var failed = false }
    private let url: URL?
    private var cache = Cache()
    private var loaded = false
    private var pending: Task<AssistantPriceBook, Error>?
    private let fetch: @Sendable () async throws -> String
    init(url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StudyPlannerAssistant/pricing-v1.json"),
         fetch: @escaping @Sendable () async throws -> String = { try await AssistantPriceStore.download() }) {
        self.url = url; self.fetch = fetch
    }
    func quote(for configuration: AssistantConfiguration, now: Date = Date()) async -> AssistantPricingResult {
        guard AssistantPriceBook.supports(configuration) else { return .unsupported }
        if !loaded {
            loaded = true
            if let url, let data = try? Data(contentsOf: url), data.count <= 64_000,
               let saved = try? JSONDecoder().decode(Cache.self, from: data) { cache = saved }
        }
        if let pending {
            _ = await pending.result
            // The owner publishes the shared cache; use the task's result directly meanwhile.
            if case .success(let book) = await pending.result { return result(book: book, failed: false, now: now, model: configuration.model) }
            return result(book: cache.book, failed: true, now: now, model: configuration.model)
        }
        let age = cache.lastAttempt.map { now.timeIntervalSince($0) }
        if age == nil || age! >= AssistantPriceBook.lifetime || age! < -300 {
            cache.lastAttempt = now
            save() // Persist the throttle even if this process quits during the fetch.
            let task = Task { try AssistantPriceBook.parse(await fetch(), at: now) }
            pending = task
            do { cache.book = try await task.value; cache.failed = false }
            catch { cache.failed = true }
            pending = nil; save()
        }
        return result(book: cache.book, failed: cache.failed, now: now, model: configuration.model)
    }
    private func result(book: AssistantPriceBook?, failed: Bool, now: Date, model: String) -> AssistantPricingResult {
        guard !failed, let book, book.isFresh(at: now) else {
            return .init(notice: "价格待更新：官方价格读取失败或已过期，24 小时内不重复请求。")
        }
        guard book.models[model] != nil else { return .init(notice: "官方价格页未列出当前模型，暂不估算费用。") }
        return .init(book: book, notice: "按官方人民币单价和接口返回用量估算，实际扣费以服务商账单为准。价格每天最多检查一次。")
    }
    private func save() {
        guard let url else { return }
        // Only public numeric rates/timestamps, kept outside planner sync and backups.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
    }
    static func download(configurationFactory: @Sendable () -> URLSessionConfiguration = { .ephemeral }) async throws -> String {
        let configuration = configurationFactory()
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: AssistantNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: AssistantPriceBook.source, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == AssistantPriceBook.source else { throw AssistantError.network }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw AssistantError.limit }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw AssistantError.protocolError }
        return text
    }
}

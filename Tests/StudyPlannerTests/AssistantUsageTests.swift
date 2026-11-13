import XCTest
import SwiftUI
import AppKit
@testable import StudyPlanner

final class AssistantUsageTests: XCTestCase, @unchecked Sendable {
    static let rule = "北京时间周一至周五（不含中国法定节假日）9:00 - 12:00、14:00 - 18:00 为高峰时段；其余时段，包括周末及中国法定节假日全天均为空闲时段。"
    /// Synthetic rates, matching only the public table's labelled/merged-cell shape.
    static let html = """
    <table><tr><td colspan="3">模型</td><td>deepseek-flash<sup>(1)</sup></td></tr>
    <tr><td rowspan="6">价格<sup>(2)</sup></td><td rowspan="2">百万tokens输入<br>（缓存命中）</td><td>空闲时段</td><td>0.1元</td></tr>
    <tr><td>高峰时段</td><td>0.2元</td></tr>
    <tr><td rowspan="2">百万tokens输入<br>（缓存未命中）</td><td>空闲时段</td><td>2元</td></tr>
    <tr><td>高峰时段</td><td>4元</td></tr>
    <tr><td rowspan="2">百万tokens输出</td><td>空闲时段</td><td>3元</td></tr>
    <tr><td>高峰时段</td><td>6元</td></tr></table>
    """ + rule
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var config: AssistantConfiguration { .init(provider: .deepseek, baseURL: "https://api.deepseek.com/v1", model: "deepseek-flash") }
    private func usage(_ object: [String: Any], provider: AssistantProvider = .deepseek) throws -> AssistantTokenUsage? {
        AssistantTokenUsage.parse(try AssistantWire.encode(["usage": object]), provider: provider)
    }
    func testCacheAccountingDoesNotDoubleCountInputOrReasoning() throws {
        let deepseek = try XCTUnwrap(usage(["prompt_tokens": 1000, "completion_tokens": 200,
            "prompt_cache_hit_tokens": 400, "prompt_cache_miss_tokens": 600,
            "completion_tokens_details": ["reasoning_tokens": 150]]))
        XCTAssertEqual(deepseek.total, 1200); XCTAssertEqual(deepseek.cachedInput, 400)
        let anthropic = try XCTUnwrap(usage(["input_tokens": 600, "output_tokens": 200,
            "cache_read_input_tokens": 300, "cache_creation_input_tokens": 100], provider: .anthropic))
        XCTAssertEqual(anthropic.total, 1200); XCTAssertEqual(anthropic.cacheWrite, 100)
        let openai = try XCTUnwrap(usage(["prompt_tokens": 1000, "completion_tokens": 200,
            "prompt_tokens_details": ["cached_tokens": 400]], provider: .openai))
        XCTAssertEqual(deepseek, openai)
        XCTAssertNil(try usage(["prompt_tokens": true, "completion_tokens": 2]))
        XCTAssertNil(try usage(["prompt_tokens": 1.5, "completion_tokens": 2]))
        XCTAssertNil(try usage(["prompt_tokens": -1, "completion_tokens": 2]))
        XCTAssertNil(try usage(["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 99]))
        XCTAssertNil(try usage(["prompt_tokens": 10, "completion_tokens": 2, "prompt_cache_hit_tokens": 11]))
        XCTAssertNil(try usage(["prompt_tokens": 10, "completion_tokens": 2, "prompt_cache_hit_tokens": 4, "prompt_cache_miss_tokens": 9]))
        XCTAssertNil(try usage(["prompt_tokens": 10, "completion_tokens": 2, "prompt_cache_hit_tokens": 4,
                               "prompt_tokens_details": ["cached_tokens": 5]]))
        XCTAssertNil(try usage([:]))
    }
    func testPublicTableParserAndChangedRulesFailClosed() throws {
        let now = Self.date("2026-11-13T02:00:00Z")
        let book = try AssistantPriceBook.parse(Self.html, at: now)
        XCTAssertEqual(book.models["deepseek-flash"]?.peak.input, 4)
        XCTAssertEqual(book.models["deepseek-flash"]?.offPeak.output, 3)
        for html in [Self.html.replacingOccurrences(of: "0.1元", with: "$0.1"),
                     Self.html.replacingOccurrences(of: "9:00", with: "8:00"),
                     Self.html.replacingOccurrences(of: "百万tokens输出", with: "每千tokens输出"),
                     Self.html.replacingOccurrences(of: "rowspan=\"6\"", with: "rowspan=\"999\""),
                     Self.html.replacingOccurrences(of: "0.1元", with: "-0.1元") ] {
            XCTAssertThrowsError(try AssistantPriceBook.parse(html, at: now))
        }
        XCTAssertFalse(book.isFresh(at: now.addingTimeInterval(86_400)))
        var proxy = config; proxy.baseURL = "https://api.deepseek.com.example.invalid/v1"
        XCTAssertFalse(AssistantPriceBook.supports(proxy))
    }
    func testRatesFollowBeijingTimeAndUnknownHolidaysUseRange() throws {
        let now = Self.date("2026-11-13T02:00:00Z") // Friday 10:00 Beijing.
        let tokens = AssistantTokenUsage(input: 1000, output: 200, cachedInput: 400, cacheWrite: 0)
        let book = try AssistantPriceBook.parse(Self.html, at: now)
        let peak = try XCTUnwrap(book.estimate(tokens, model: "deepseek-flash", start: now, end: now))
        XCTAssertEqual(peak.upper, 0.00368, accuracy: 1e-10); XCTAssertEqual(peak.lower, peak.upper)
        let evening = now.addingTimeInterval(10 * 3600)
        let off = try XCTUnwrap(book.estimate(tokens, model: "deepseek-flash", start: evening, end: evening))
        XCTAssertEqual(off.upper, 0.00184, accuracy: 1e-10)
        XCTAssertFalse(try XCTUnwrap(AssistantPriceBook.peak(at: Self.date("2026-10-01T02:00:00Z"))))
        XCTAssertFalse(try XCTUnwrap(AssistantPriceBook.peak(at: Self.date("2026-11-14T02:00:00Z"))))
        XCTAssertNil(AssistantPriceBook.peak(at: Self.date("2027-01-04T02:00:00Z")))
        let later = Self.date("2027-01-04T02:00:00Z")
        let newBook = try AssistantPriceBook.parse(Self.html, at: later)
        let range = try XCTUnwrap(newBook.estimate(tokens, model: "deepseek-flash", start: later, end: later))
        XCTAssertLessThan(range.lower, range.upper)
        XCTAssertNil(book.estimate(tokens, model: "unknown", start: now, end: now))
        XCTAssertNil(book.estimate(.init(input: 1000, output: 200, cachedInput: nil, cacheWrite: 0), model: "deepseek-flash", start: now, end: now))
    }
    func testAllRequestsAndIncompleteCostsRemainDistinctFromZero() throws {
        let now = Self.date("2026-11-13T02:00:00Z")
        let pricing = AssistantPricingResult(book: try .parse(Self.html, at: now), notice: "合成价格")
        var turn = AssistantTurnUsage(priceCheckedAt: now)
        let tokens = AssistantTokenUsage(input: 1000, output: 200, cachedInput: 400, cacheWrite: 0)
        for _ in 0..<2 {
            turn.record(.requestStarted, pricing: pricing, model: config.model)
            turn.record(.response(tokens, start: now, end: now, seconds: 2), pricing: pricing, model: config.model)
        }
        XCTAssertEqual(turn.requests, 2); XCTAssertEqual(turn.input, 2000)
        XCTAssertEqual(turn.cost.upper, 0.00736, accuracy: 1e-10)
        XCTAssertEqual(turn.costLabel, "本轮约 ¥0.00736")
        turn.record(.requestStarted, pricing: pricing, model: config.model)
        XCTAssertEqual(turn.costLabel, "本轮费用不完整")
        turn.record(.response(nil, start: now, end: now, seconds: 2), pricing: pricing, model: config.model)
        XCTAssertEqual(turn.pricedResponses, 2); XCTAssertEqual(turn.responses, 3)
        XCTAssertEqual(turn.costLabel, "本轮费用不完整")
        XCTAssertEqual(AssistantCostEstimate(lower: 0.00000001, upper: 0.00000001).text, "¥<0.000001")
    }
    private actor Fetcher {
        var count = 0
        var failing = false
        func fetch() throws -> String {
            count += 1
            if failing { throw AssistantError.network }
            return AssistantUsageTests.html
        }
        func fail() { failing = true }
    }
    func testPriceRefreshIsThrottledPersistedAndFailureCannotUseStalePrices() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("prices.json"), fetcher = Fetcher()
        let store = AssistantPriceStore(url: url, fetch: { try await fetcher.fetch() })
        let now = Self.date("2026-11-13T02:00:00Z")
        let selectedConfig = config
        async let first = store.quote(for: selectedConfig, now: now)
        async let second = store.quote(for: selectedConfig, now: now)
        let quotes = await [first, second]
        XCTAssertTrue(quotes.allSatisfy { $0.book != nil })
        var count = await fetcher.count; XCTAssertEqual(count, 1)
        let reopened = AssistantPriceStore(url: url, fetch: { try await fetcher.fetch() })
        let reused = await reopened.quote(for: config, now: now.addingTimeInterval(3600))
        XCTAssertNotNil(reused.book)
        count = await fetcher.count; XCTAssertEqual(count, 1)
        await fetcher.fail()
        let failed = await reopened.quote(for: config, now: now.addingTimeInterval(86_401))
        XCTAssertNil(failed.book); XCTAssertTrue(failed.notice.contains("价格待更新"))
        let again = AssistantPriceStore(url: url, fetch: { try await fetcher.fetch() })
        let stillFailed = await again.quote(for: config, now: now.addingTimeInterval(86_402))
        XCTAssertNil(stillFailed.book)
        count = await fetcher.count; XCTAssertEqual(count, 2)
    }
    func testPreviouslySavedHistoryHasNoInventedCost() throws {
        let entry = try JSONDecoder().decode(AssistantChatEntry.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"role\":\"你\",\"text\":\"旧问题\"}".utf8))
        XCTAssertNil(entry.usage)
        let saved = AssistantChatEntry(role: "你", text: "新问题", usage: .init(requests: 3, pricedResponses: 2,
            cost: .init(lower: 0.1, upper: 0.2)))
        let restored = try JSONDecoder().decode(AssistantChatEntry.self, from: assistantJSON(saved))
        XCTAssertEqual(restored.usage, saved.usage)
        XCTAssertFalse(AssistantTurnUsage(requests: 0, input: Int.max).valid)
        XCTAssertFalse(AssistantTurnUsage(cost: .init(lower: -1, upper: 0)).valid)
    }
    func testActualPublicPageWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["STUDYPLANNER_PUBLIC_PRICE_HTML"] else {
            throw XCTSkip("Optional public webpage integration check")
        }
        let book = try AssistantPriceBook.parse(String(contentsOfFile: path, encoding: .utf8), at: Date())
        XCTAssertNotNil(book.models["deepseek-flash"])
        XCTAssertNotNil(book.models["deepseek-v4-pro"])
    }
    func testPriceDownloadHasNoCredentialsOrChatAndUsesOnlyPublicEndpoint() async throws {
        let html = try await AssistantPriceStore.download(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PriceIntercept.self]
            return configuration
        })
        XCTAssertEqual(html, Self.html)
    }
    @MainActor func testUsageBarFitsOneRowAtMinimumAndWideWindowSizes() throws {
        _ = NSApplication.shared
        let usage = AssistantTurnUsage(requests: 12, responses: 12, tools: 24, measuredResponses: 12,
            input: 123456, output: 1234, cachedInput: 90000, cacheResponses: 12, pricedResponses: 12,
            cost: .init(lower: 0.012345, upper: 0.02469), priceCheckedAt: Date(), priceNotice: "合成展示数据")
        for (width, scheme) in [(358.0, ColorScheme.light), (712.0, ColorScheme.dark)] {
            let content = AssistantUsageBar(usage: usage, busy: false, hasHistory: true)
                .frame(width: width).padding(12)
                .background(scheme == .dark ? Color.black : .white).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: width + 24, height: host.fittingSize.height)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, width + 24, accuracy: 1)
            XCTAssertLessThan(host.fittingSize.height, 60)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let folder = ProcessInfo.processInfo.environment["STUDYPLANNER_USAGE_RENDER_DIR"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("usage-\(Int(width)).png"))
            }
        }
    }
}

private final class PriceIntercept: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url == AssistantPriceBook.source, request.httpMethod == "GET", request.httpBody == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "x-api-key") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil else {
            client?.urlProtocol(self, didFailWithError: AssistantError.protocolError); return
        }
        let response = HTTPURLResponse(url: AssistantPriceBook.source, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(AssistantUsageTests.html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

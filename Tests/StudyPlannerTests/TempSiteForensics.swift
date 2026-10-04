import XCTest
import WebKit
@testable import StudyPlanner
import StudyCore

private struct ProbePayload: Decodable {
    let url: String
    let body: String
}

final class TempSiteForensics: XCTestCase {
    @MainActor
    private func snapshot(_ reader: WebLessonReader) async -> [ProbePayload] {
        let value = try? await reader.webView.callAsyncJavaScript(
            "return JSON.stringify(window.studyGenericCrawler ? window.studyGenericCrawler.snapshot() : []);",
            arguments: [:], in: nil, contentWorld: .page)
        guard let json = value as? String, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ProbePayload].self, from: data)) ?? []
    }

    @MainActor
    private func report(_ label: String, _ payloads: [ProbePayload]) {
        print("=== \(label): \(payloads.count) responses ===")
        for payload in payloads {
            let head = payload.body.prefix(260).replacingOccurrences(of: "\n", with: " ")
            print("--- \(payload.url) [\(payload.body.count) bytes]")
            print("    \(head)")
        }
    }

    @MainActor
    func testForensics() async throws {
        guard ProcessInfo.processInfo.environment["STUDYPLANNER_LIVE_SITE_FORENSICS"] == "1" else {
            throw XCTSkip("Live-site diagnostics are opt-in: set STUDYPLANNER_LIVE_SITE_FORENSICS=1.")
        }
        let reader = WebLessonReader(); defer { reader.stop() }
        reader.address = "https://www.ixuecheng.cn/list"
        reader.loadAddress()
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            if !reader.webView.isLoading, reader.webView.url != nil { break }
        }
        try await Task.sleep(for: .seconds(10))
        report("LIST", await snapshot(reader))

        let links = try? await reader.webView.callAsyncJavaScript(
            "return JSON.stringify([...document.querySelectorAll('a')].map(a => a.getAttribute('href')).filter(h => h && (h.includes('detail') || h.includes('course'))).slice(0, 5));",
            arguments: [:], in: nil, contentWorld: .page)
        print("=== LINKS \(String(describing: links))")

        reader.webView.load(URLRequest(url: URL(string: "https://www.ixuecheng.cn/my-course")!))
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            if !reader.webView.isLoading, reader.webView.url != nil { break }
        }
        try await Task.sleep(for: .seconds(10))
        print("=== MY-COURSE url=\(reader.webView.url?.absoluteString ?? "nil")")
        report("MY-COURSE", await snapshot(reader))
    }
}

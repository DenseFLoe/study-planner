import XCTest
import WebKit
@testable import StudyPlanner

final class WebsiteLoginTests: XCTestCase {
    @MainActor private func page(_ html: String, host: String) async throws -> WebLessonReader {
        let reader = WebLessonReader(useExternalBrowser: false)
        reader.webView.loadHTMLString("<html><body>" + html + "</body></html>", baseURL: URL(string: "https://" + host + "/login"))
        for _ in 0..<60 {
            if (try? await reader.webView.evaluateJavaScript("document.querySelector('#fixture') !== null")) as? Bool == true { return reader }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("WebKit fixture could not load")
    }
    private let credential = WebsiteCredentials(username: "PLACEHOLDER_ACCOUNT", password: "PLACEHOLDER_PASSWORD")

    @MainActor func testYantuFormFillsAndSubmitsItsExternalButtonOnce() async throws {
        let reader = try await page("""
            <div id="fixture"><form><input placeholder="请输入手机号"><input type="password" placeholder="请输入密码"></form>
            <button onclick="window.submissions=(window.submissions||0)+1">开启我的上岸之旅</button></div>
            """, host: "www.kaoyanvip.cn")
        defer { reader.stop() }
        let result = try await reader.webView.evaluateJavaScript(BrowserCourseSession.loginScript(site: .yantu, credentials: credential))
        XCTAssertEqual(result as? String, "submitted")
        try await Task.sleep(for: .milliseconds(400))
        let submissions = try await reader.webView.evaluateJavaScript("window.submissions")
        XCTAssertEqual(submissions as? Int, 1)
        let followup = try await reader.webView.evaluateJavaScript(BrowserCourseSession.loginScript(site: .yantu, credentials: nil))
        XCTAssertEqual(followup as? String, "login-required")
    }
    @MainActor func testXuechengAgreementIsNotSilentlyAccepted() async throws {
        let reader = try await page("""
            <div id="fixture" class="login-sub-wrapper"><input placeholder="请输入手机号码"><input type="password">
            <button class="loginBtn" onclick="window.submissions=1">立即登录</button>
            <div class="agreement-line"><img class="check-img" onclick="window.agreed=true" style="width:10px;height:10px"></div></div>
            """, host: "www.ixuecheng.cn")
        defer { reader.stop() }
        _ = try await reader.webView.evaluateJavaScript(BrowserCourseSession.loginScript(site: .xuecheng, credentials: credential))
        try await Task.sleep(for: .milliseconds(400))
        let next = try await reader.webView.evaluateJavaScript(BrowserCourseSession.loginScript(site: .xuecheng, credentials: nil))
        XCTAssertEqual(next as? String, "verification")
        let untouched = try await reader.webView.evaluateJavaScript("!window.submissions && !window.agreed")
        XCTAssertEqual(untouched as? Bool, true)
    }
    @MainActor func testXuechengAgreedFormCanSubmit() async throws {
        let reader = try await page("""
            <div id="fixture" class="login-sub-wrapper"><input placeholder="请输入手机号码"><input type="password">
            <button class="loginBtn-check" onclick="window.submissions=1">立即登录</button>
            <div class="agreement-line"><img class="check-img" style="width:10px;height:10px"></div></div>
            """, host: "ixuecheng.cn")
        defer { reader.stop() }
        _ = try await reader.webView.evaluateJavaScript(BrowserCourseSession.loginScript(site: .xuecheng, credentials: credential))
        try await Task.sleep(for: .milliseconds(400))
        let result = try await reader.webView.evaluateJavaScript("window.submissions")
        XCTAssertEqual(result as? Int, 1)
    }
    @MainActor func testCaptchaBlocksCredentialEntryAndSubmission() async throws {
        let reader = try await page("""
            <form id="fixture"><input placeholder="手机号"><input type="password"><input placeholder="验证码">
            <button onclick="window.submissions=1">立即登录</button></form>
            """, host: "www.kaoyanvip.cn")
        defer { reader.stop() }
        let result = try await reader.webView.evaluateJavaScript(BrowserCourseSession.loginScript(site: .yantu, credentials: credential))
        XCTAssertEqual(result as? String, "verification")
        let empty = try await reader.webView.evaluateJavaScript("[...document.querySelectorAll('input')].every(e => !e.value)")
        XCTAssertEqual(empty as? Bool, true)
    }
    @MainActor func testWrongHostAndCrossOriginFormNeverReceiveCredentials() async throws {
        for host in ["example.com", "www.kaoyanvip.cn"] {
            let reader = try await page("""
                <form id="fixture" action="https://example.invalid/signin"><input placeholder="手机号"><input type="password">
                <button>立即登录</button></form>
                """, host: host)
            defer { reader.stop() }
            let result = try await reader.webView.evaluateJavaScript(BrowserCourseSession.loginScript(site: .yantu, credentials: credential))
            XCTAssertEqual(result as? String, "verification")
            let empty = try await reader.webView.evaluateJavaScript("[...document.querySelectorAll('input')].every(e => !e.value)")
            XCTAssertEqual(empty as? Bool, true)
        }
    }
    @MainActor func testMovedTabNeverReceivesCredentials() async throws {
        let reader = try await page("""
            <form id="fixture"><input placeholder="手机号"><input type="password"><button>立即登录</button></form>
            """, host: "www.kaoyanvip.cn")
        defer { reader.stop() }
        let result = try await reader.webView.evaluateJavaScript(BrowserCourseSession.loginScript(site: .yantu,
            credentials: credential, owner: "expected-update-window"))
        XCTAssertEqual(result as? String, "verification")
        let empty = try await reader.webView.evaluateJavaScript("[...document.querySelectorAll('input')].every(e => !e.value)")
        XCTAssertEqual(empty as? Bool, true)
    }
}

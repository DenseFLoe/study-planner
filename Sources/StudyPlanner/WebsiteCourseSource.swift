import Foundation
import Security
import StudyCredentials
import StudyCore

enum CourseWebsite: String, Codable, CaseIterable, Sendable {
    case yantu, xuecheng
    var name: String { self == .yantu ? "研途" : "学丞教育" }
    var hosts: [String] {
        self == .yantu ? ["www.kaoyanvip.cn", "kaoyanvip.cn"] : ["www.ixuecheng.cn", "ixuecheng.cn"]
    }
    static func identify(_ url: URL) -> Self? {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return allCases.first { $0.hosts.contains(url.host?.lowercased() ?? "") }
    }
    static func identify(_ snapshot: WebCourseSnapshot?) -> Self? {
        guard let snapshot, let url = URL(string: snapshot.sourceURL) else { return nil }
        return identify(url)
    }
    func courseURL(_ text: String, packageID: String) throws -> URL {
        guard let url = WebLessonTiming.addressURL(text), Self.identify(url) == self,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WebsiteUpdateError.message("请输入这门课对应的\(name) HTTPS 课程网址。")
        }
        switch self {
        case .yantu:
            guard !packageID.isEmpty, packageID.allSatisfy({ $0.isASCII && $0.isNumber }),
                  url.path == "/appmanage/my/mycourse/delivery-packages/\(packageID)/outline",
                  components.query == nil else {
                throw WebsiteUpdateError.message("请使用这门课的研途课程大纲网址，课程包编号须与原课程一致。")
            }
        case .xuecheng:
            let items = components.queryItems ?? []
            guard url.path == "/detail", items.filter({ $0.name == "id" }).count == 1,
                  let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty,
                  packageID == "generic:" + id,
                  items.allSatisfy({ $0.name == "id" || $0.name == "type" }),
                  items.filter({ $0.name == "type" }).count <= 1 else {
                throw WebsiteUpdateError.message("请使用这门课的学丞详情网址（/detail?id=…），课程编号须与原课程一致。")
            }
        }
        components.fragment = nil
        guard let safe = components.url else { throw WebsiteUpdateError.message("课程网址无效。") }
        return safe
    }
}

enum WebsiteUpdateError: LocalizedError {
    case message(String)
    case loginRequired
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .loginRequired: "需要登录或人工验证。请在课程更新窗口完成登录，再点“立即更新”；同网站的自动更新已暂停。"
        }
    }
}

struct WebsiteCourseSource: Codable, Equatable, Sendable {
    var url: String
    var enabled = false
    var intervalMinutes = 60
    var lastAttempt: Date?
    var lastSuccess: Date?
    var needsAttention = false
    var status = "尚未更新"
    static let intervals = [30, 60, 180, 360]
    func isDue(at now: Date) -> Bool {
        enabled && !needsAttention && (lastAttempt.map { now.timeIntervalSince($0) >= Double(intervalMinutes * 60) } ?? true)
    }
}

struct WebsiteCredentials: Codable, Sendable {
    var username: String
    var password: String
}

/// Accounts never enter PlannerState, backups, sync archives or UserDefaults.
enum WebsiteCredentialVault {
    static func load(_ site: CourseWebsite, interactive: Bool = false) throws -> WebsiteCredentials? {
        let (data, status) = CredentialClient.perform(.init(.load, service: "local.studyplanner.website-account", account: site.rawValue, interactive: interactive))
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data,
              let value = try? JSONDecoder().decode(WebsiteCredentials.self, from: data) else {
            throw WebsiteUpdateError.message("无法读取网站账号钥匙串，请解锁钥匙串或重新保存账号。")
        }
        return value
    }
    static func save(_ value: WebsiteCredentials, site: CourseWebsite) throws {
        guard !value.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.password.isEmpty else {
            throw WebsiteUpdateError.message("请填写账号和密码。")
        }
        let (_, status) = CredentialClient.perform(.init(.save, service: "local.studyplanner.website-account", account: site.rawValue, value: try JSONEncoder().encode(value)))
        guard status == errSecSuccess else { throw WebsiteUpdateError.message("无法保存网站账号钥匙串。") }
    }
    static func delete(_ site: CourseWebsite) throws {
        let (_, status) = CredentialClient.perform(.init(.delete, service: "local.studyplanner.website-account", account: site.rawValue))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WebsiteUpdateError.message("无法删除网站账号钥匙串。") }
    }
}

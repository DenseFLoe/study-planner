import Foundation
import Security
import LocalAuthentication
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
    private static func query(_ site: CourseWebsite) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.studyplanner.website-account",
         kSecAttrAccount as String: site.rawValue,
         kSecAttrSynchronizable as String: false]
    }
    static func load(_ site: CourseWebsite, interactive: Bool = false) throws -> WebsiteCredentials? {
        var q = query(site)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(WebsiteCredentials.self, from: data) else {
            throw WebsiteUpdateError.message("无法读取网站账号钥匙串，请解锁钥匙串或重新保存账号。")
        }
        return value
    }
    static func save(_ value: WebsiteCredentials, site: CourseWebsite) throws {
        guard !value.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.password.isEmpty else {
            throw WebsiteUpdateError.message("请填写账号和密码。")
        }
        let data = try JSONEncoder().encode(value), q = query(site)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        var item = q
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard status == errSecItemNotFound, SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw WebsiteUpdateError.message("网站账号未保存，请检查钥匙串访问权限。")
        }
    }
    static func delete(_ site: CourseWebsite) throws {
        let status = SecItemDelete(query(site) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WebsiteUpdateError.message("未能删除保存的网站账号。")
        }
    }
}

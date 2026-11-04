import Foundation

/// Only public navigation information belongs in course records, backups and sync.
public enum WebCourseIdentity {
    public static func safeURL(_ value: String) -> String {
        guard var url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return "" }
        url.scheme = "https"
        url.host = host
        url.user = nil
        url.password = nil
        url.fragment = nil
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let items = (host == "ixuecheng.cn" || host.hasSuffix(".ixuecheng.cn")) && url.path == "/detail"
            ? url.queryItems?.filter {
                ($0.name == "id" || $0.name == "type") && $0.value.map {
                    !$0.isEmpty && $0.count <= 128 && $0.unicodeScalars.allSatisfy(allowed.contains)
                } == true
            } : nil
        url.queryItems = items?.isEmpty == false ? items : nil
        return url.string ?? ""
    }

    public static func origin(_ value: String) -> String? {
        guard let url = URLComponents(string: safeURL(value)), let host = url.host else { return nil }
        let port = url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
        let siteHost = ["www.ixuecheng.cn", "www.kaoyanvip.cn"].contains(host) ? String(host.dropFirst(4)) : host
        return "https://" + siteHost + port
    }
}

extension WebCourseSnapshot {
    /// Provider IDs and lesson IDs stay unchanged, preserving history and deletion markers.
    /// Generic IDs are local to a site; this composite key is used everywhere we match them.
    public var identityKey: String {
        guard packageID.hasPrefix("generic:") else { return packageID }
        let site = WebCourseIdentity.origin(sourceURL) ?? ""
        return "\(site.utf8.count):\(site)\(packageID)"
    }

    public func matchesIdentity(of other: WebCourseSnapshot) -> Bool {
        guard packageID == other.packageID else { return false }
        guard packageID.hasPrefix("generic:") else { return true }
        guard let site = WebCourseIdentity.origin(sourceURL),
              let otherSite = WebCourseIdentity.origin(other.sourceURL) else { return false }
        return site == otherSite
    }

    public func matchingCourseIndices(in courses: [Course]) throws -> [Int] {
        let candidates = courses.indices.filter { courses[$0].webCourse?.packageID == packageID }
        if packageID.hasPrefix("generic:"), !candidates.isEmpty,
           WebCourseIdentity.origin(sourceURL) == nil || candidates.contains(where: {
               WebCourseIdentity.origin(courses[$0].webCourse!.sourceURL) == nil
           }) {
            throw WebCourseImportError.invalid("已有同编号课程的来源无法确认，请先核对来源；原课程和学习记录已保留。")
        }
        let matches = candidates.filter { courses[$0].webCourse!.matchesIdentity(of: self) }
        guard matches.count <= 1 else {
            throw WebCourseImportError.invalid("已有多个课程绑定同一网站的同一课程包，请先整理重复课程。")
        }
        return matches
    }
}

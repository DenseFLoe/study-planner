import Foundation

/// Player position is not evidence of completed study (the user may seek).
public struct WebLessonTiming: Equatable, Sendable {
    public let duration: Double
    public let position: Double
    public let rate: Double
    public init?(duration: Double, position: Double, rate: Double) {
        guard duration.isFinite, duration > 0, duration <= 36_000_000,
              position.isFinite, position >= 0, rate.isFinite, rate > 0 else { return nil }
        self.duration = duration
        self.position = min(position, duration)
        self.rate = rate
    }
    public var totalMinutes: Int { Int(ceil(duration / 60)) }
    public var remainingSeconds: Double { (duration - position) / rate }
    public static func websiteURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    /// Addresses typed by hand: a bare host or path is completed to HTTPS, anything else must already be HTTPS.
    public static func addressURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        return websiteURL(trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }
    /// The reader only crawls the site it was pointed at, so an address change cannot silently read another host.
    public static func isSameWebsite(current: URL, target: URL) -> Bool {
        guard current.scheme?.lowercased() == "https", let currentHost = current.host, let targetHost = target.host,
              currentHost.caseInsensitiveCompare(targetHost) == .orderedSame else { return false }
        return true
    }
    /// Auto-crawl gate. An addressed page opens the crawl as soon as it loads; a bare host waits for any deeper page.
    public static func isOnTargetPage(current: URL, target: URL) -> Bool {
        guard isSameWebsite(current: current, target: target) else { return false }
        let prefix = target.path
        guard !prefix.isEmpty, prefix != "/" else { return !current.path.isEmpty && current.path != "/" }
        return current.path.hasPrefix(prefix)
    }
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= 36_000_000 else { return "—" }
        let value = Int(seconds)
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

import Foundation

/// A date transition is acknowledged only after its updated plan is durably saved.
public struct DayRolloverState: Sendable {
    public static let retryDelay: TimeInterval = 300
    private var savedDay: Date
    private var failedDay: Date?
    private var failedAt: TimeInterval = 0
    public init(savedDay: Date) { self.savedDay = savedDay }

    public func isDue(day: Date, uptime: TimeInterval) -> Bool {
        day != savedDay && (day != failedDay || uptime < failedAt || uptime - failedAt >= Self.retryDelay)
    }

    public mutating func succeeded(day: Date) { savedDay = day; failedDay = nil }
    public mutating func failed(day: Date, uptime: TimeInterval) { failedDay = day; failedAt = uptime }
}

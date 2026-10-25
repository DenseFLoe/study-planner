import Foundation

/// Navigation only. Opening a category never saves settings or reschedules tasks.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case display = "显示设置"
    case availability = "每日可学习时间"
    case load = "学习负担提醒"
    case priorities = "排课逻辑权重"
    case explanation = "排课原因"
    case defaults = "默认规则"
    case localSync = "热点局域网同步"
    case cloudSync = "云端同步"
    case data = "数据保存"

    var id: Self { self }
    var editsSchedule: Bool { self == .availability || self == .priorities || self == .defaults }
    var icon: String {
        switch self {
        case .display: "textformat.size"
        case .availability: "clock"
        case .load: "bell"
        case .priorities: "slider.horizontal.3"
        case .explanation: "text.bubble"
        case .defaults: "gearshape"
        case .localSync: "wifi"
        case .cloudSync: "cloud"
        case .data: "internaldrive"
        }
    }
}

import Foundation

public enum SettingsEditError: LocalizedError {
    case conflictingChanges
    case invalidSettings

    public var errorDescription: String? {
        switch self {
        case .conflictingChanges:
            "学习设置在编辑期间已有其他修改，与当前草稿冲突。草稿和最新数据均已保留；请先记录草稿，再点击“恢复已保存设置”查看最新值后重新编辑。"
        case .invalidSettings:
            "请检查各时段的起止时间、最小时间块和每日确认时间。"
        }
    }
}

public extension AppSettings {
    /// Only these fields are owned by the settings editor. Runtime scheduling
    /// state (including daily drag order) must never make a draft dirty or stale.
    func hasSameEditableSettings(as other: AppSettings) -> Bool {
        minimumScheduleUnit == other.minimumScheduleUnit &&
        notificationMinute == other.notificationMinute &&
        availability == other.availability &&
        schedulingRuleLevels == other.schedulingRuleLevels
    }

    var hasValidEditableSettings: Bool {
        (1...1440).contains(minimumScheduleUnit) && (0..<1440).contains(notificationMinute) &&
        availability.allSatisfy {
            (1...7).contains($0.weekday) && $0.startMinute >= 0 &&
            $0.endMinute <= 1440 && $0.startMinute < $0.endMinute
        }
    }

    func mergingSettingsDraft(from baseline: AppSettings, into current: AppSettings) throws -> AppSettings {
        func resolve<T: Equatable>(_ edited: T, _ old: T, _ latest: T) throws -> T {
            if edited == old { return latest }
            guard latest == old || latest == edited else { throw SettingsEditError.conflictingChanges }
            return edited
        }
        var merged = current
        merged.minimumScheduleUnit = try resolve(minimumScheduleUnit, baseline.minimumScheduleUnit, current.minimumScheduleUnit)
        merged.notificationMinute = try resolve(notificationMinute, baseline.notificationMinute, current.notificationMinute)
        // Treat each collection as one setting: never synthesize a window list
        // or priority ordering that neither editor reviewed.
        merged.availability = try resolve(availability, baseline.availability, current.availability)
        merged.schedulingRuleLevels = try resolve(schedulingRuleLevels, baseline.schedulingRuleLevels, current.schedulingRuleLevels)
        guard merged.hasValidEditableSettings else { throw SettingsEditError.invalidSettings }
        return merged
    }
}

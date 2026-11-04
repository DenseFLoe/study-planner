import Foundation

public enum FixedEventDuplicationError: LocalizedError {
    case invalidDate
    public var errorDescription: String? {
        "无法复制到所选日期，请选择今天起十年以内的日期后重试。"
    }
}

public extension FixedEvent {
    /// Independent unsaved draft. Old occurrence exclusions belong to the source only.
    func duplicate(startingOn selectedDay: Date, now: Date = Date(), calendar: Calendar = .current) throws -> FixedEvent {
        guard [selectedDay, now, startDate, endDate].allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw FixedEventDuplicationError.invalidDate
        }
        let today = calendar.startOfDay(for: now)
        let first = max(today, calendar.startOfDay(for: selectedDay))
        guard let maximum = calendar.date(byAdding: .year, value: 10, to: today), first <= maximum,
              let availableDays = calendar.dateComponents([.day], from: first, to: maximum).day,
              let originalDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate),
                                                         to: calendar.startOfDay(for: endDate)).day,
              let last = calendar.date(byAdding: .day, value: weekdays.isEmpty ? 0 : min(max(0, originalDays), availableDays), to: first) else {
            throw FixedEventDuplicationError.invalidDate
        }
        var draft = self
        draft.id = UUID(); draft.startDate = first; draft.endDate = last
        draft.excludedDates = []
        return draft
    }
}

import Foundation

public enum CourseType: String, Codable, CaseIterable, Sendable {
    case recorded = "录播课程", tutoring = "补习回放", other = "其他学习"
}
public enum TaskStatus: String, Codable, Sendable {
    case planned, completed, partial, missed, rescheduled, future
}

public struct Course: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var type: CourseType = .recorded
    public var totalMinutes: Int
    public var initialCompletedMinutes: Int = 0
    public var startDate: Date
    /// Inclusive local calendar day, not an instant at midnight.
    public var deadline: Date
    public var publishedDate: Date?
    public var priority: Int = 2
    public var color: String = "blue"
    /// Zero follows the global default. The final remainder may be shorter.
    public var minimumBlockMinutes: Int = 60
    public var autoScheduleEnabled = true
    public var isArchived = false
    public var notes = ""
    public init(name: String, totalMinutes: Int, startDate: Date, deadline: Date, minimumBlockMinutes: Int = 60) {
        self.name = name; self.totalMinutes = totalMinutes
        self.startDate = startDate; self.deadline = deadline
        self.minimumBlockMinutes = minimumBlockMinutes
    }
}

public struct FixedEvent: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var startMinute: Int
    public var endMinute: Int
    public var startDate: Date
    public var endDate: Date
    /// Foundation weekdays: Sunday = 1. Empty means a single occurrence on startDate.
    public var weekdays: Set<Int>
    /// Calendar days on which a recurring event is intentionally skipped.
    /// Dates are compared by calendar day, so callers may provide any time on the day.
    public var excludedDates: Set<Date> = []
    public var color = "orange"
    public var notes = ""
    private enum CodingKeys: String, CodingKey {
        case id, title, startMinute, endMinute, startDate, endDate, weekdays, excludedDates, color, notes
    }
    public init(title: String, startMinute: Int, endMinute: Int, startDate: Date, endDate: Date, weekdays: Set<Int> = [], excludedDates: Set<Date> = []) {
        self.title = title; self.startMinute = startMinute; self.endMinute = endMinute
        self.startDate = startDate; self.endDate = endDate; self.weekdays = weekdays; self.excludedDates = excludedDates
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try values.decode(String.self, forKey: .title)
        self.startMinute = try values.decode(Int.self, forKey: .startMinute)
        self.endMinute = try values.decode(Int.self, forKey: .endMinute)
        self.startDate = try values.decode(Date.self, forKey: .startDate)
        self.endDate = try values.decode(Date.self, forKey: .endDate)
        self.weekdays = try values.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? []
        self.excludedDates = try values.decodeIfPresent(Set<Date>.self, forKey: .excludedDates) ?? []
        self.color = try values.decodeIfPresent(String.self, forKey: .color) ?? "orange"
        self.notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
    public func occurs(on day: Date, calendar: Calendar) -> Bool {
        let date = calendar.startOfDay(for: day)
        guard date >= calendar.startOfDay(for: startDate), date <= calendar.startOfDay(for: endDate) else { return false }
        guard !excludedDates.contains(where: { calendar.isDate($0, inSameDayAs: date) }) else { return false }
        return weekdays.isEmpty ? calendar.isDate(date, inSameDayAs: startDate) : weekdays.contains(calendar.component(.weekday, from: date))
    }
}

public struct FixedEventConflict: Identifiable, Equatable, Sendable {
    public var id: String { "\(eventID.uuidString)-\(date.timeIntervalSince1970)" }
    public var eventID: UUID
    public var title: String
    public var date: Date
    public init(eventID: UUID, title: String, date: Date) {
        self.eventID = eventID; self.title = title; self.date = date
    }
}

public struct ScheduledTask: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var courseID: UUID
    public var start: Date
    public var durationMinutes: Int
    public var status: TaskStatus = .planned
    public var completedMinutes: Int = 0
    public var confirmedAt: Date?
    public var end: Date { start.addingTimeInterval(Double(durationMinutes) * 60) }
    public var isUnconfirmed: Bool { confirmedAt == nil && (status == .planned || status == .future) }
    public init(courseID: UUID, start: Date, durationMinutes: Int, status: TaskStatus = .planned) {
        self.courseID = courseID; self.start = start; self.durationMinutes = durationMinutes; self.status = status
    }
}

public struct CompletionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var courseID: UUID
    public var taskID: UUID
    public var minutes: Int
    public var recordedAt: Date
}

public struct DailyAvailability: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var weekday: Int
    public var startMinute: Int
    public var endMinute: Int
    public init(weekday: Int, startMinute: Int, endMinute: Int) {
        self.weekday = weekday; self.startMinute = startMinute; self.endMinute = endMinute
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var minimumScheduleUnit = 60
    public var notificationMinute = 21 * 60
    public var availability: [DailyAvailability] = (1...7).map { .init(weekday: $0, startMinute: 8 * 60, endMinute: 23 * 60) }
    public init() {}
}

public struct PlannerState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var courses: [Course] = []
    public var fixedEvents: [FixedEvent] = []
    public var tasks: [ScheduledTask] = []
    public var completions: [CompletionRecord] = []
    public var settings = AppSettings()
    public init() {}
    public func completedMinutes(for course: Course) -> Int {
        min(course.totalMinutes, max(0, course.initialCompletedMinutes) + completions.filter { $0.courseID == course.id }.reduce(0) { $0 + $1.minutes })
    }
    public func remainingMinutes(for course: Course) -> Int { max(0, course.totalMinutes - completedMinutes(for: course)) }
    public func confirmationCandidates(at now: Date, calendar: Calendar = .current) -> [ScheduledTask] {
        let today = calendar.startOfDay(for: now)
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let enabled = Set(courses.filter { !$0.isArchived }.map(\.id))
        return tasks.filter {
            $0.isUnconfirmed && enabled.contains($0.courseID) &&
            ($0.end <= today || (minute >= settings.notificationMinute && $0.end <= now))
        }.sorted { $0.start < $1.start }
    }

    /// Keep recurring rules for past dates and today's already-started occurrence intact.
    public mutating func updateFixedEvent(_ event: FixedEvent, now: Date, calendar: Calendar = .current, skippingDates: Set<Date> = []) throws {
        guard event.startMinute >= 0, event.endMinute <= 1440, event.startMinute < event.endMinute,
              event.weekdays.allSatisfy({ (1...7).contains($0) }) else { throw PlannerError.invalidFixedEvent }
        let today = calendar.startOfDay(for: now)
        let index = fixedEvents.firstIndex { $0.id == event.id }
        var boundary = today
        if let index, fixedEvents[index].occurs(on: today, calendar: calendar),
           ScheduleEngine(calendar: calendar).instant(day: today, minute: fixedEvents[index].startMinute) <= now {
            boundary = calendar.date(byAdding: .day, value: 1, to: today)!
        }
        var updated = event
        updated.startDate = max(boundary, calendar.startOfDay(for: event.startDate))
        guard updated.endDate >= updated.startDate else { throw PlannerError.pastFixedEvent }
        updated.excludedDates = Set(event.excludedDates.map { calendar.startOfDay(for: $0) })
        let skipped = Set(skippingDates.map { calendar.startOfDay(for: $0) })
        for other in fixedEvents where other.id != event.id && other.startMinute < updated.endMinute && other.endMinute > updated.startMinute {
            var candidate = max(calendar.startOfDay(for: other.startDate), updated.startDate)
            let end = min(other.endDate, updated.endDate)
            var conflicts: [FixedEventConflict] = []
            while candidate <= end {
                if other.occurs(on: candidate, calendar: calendar) && updated.occurs(on: candidate, calendar: calendar) {
                    conflicts.append(.init(eventID: other.id, title: other.title, date: candidate))
                }
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
            }
            conflicts.removeAll { skipped.contains($0.date) }
            if !conflicts.isEmpty { throw PlannerError.fixedConflict(conflicts) }
            updated.excludedDates.formUnion(skippingDates.map { calendar.startOfDay(for: $0) })
        }
        if updated.occurs(on: today, calendar: calendar) {
            let start = ScheduleEngine(calendar: calendar).instant(day: today, minute: updated.startMinute)
            let end = ScheduleEngine(calendar: calendar).instant(day: today, minute: updated.endMinute)
            if tasks.contains(where: { $0.isUnconfirmed && $0.start < now && $0.end > now && $0.start < end && $0.end > start }) {
                throw PlannerError.activeConflict
            }
        }
        if let index {
            if calendar.startOfDay(for: fixedEvents[index].startDate) < boundary {
                fixedEvents[index].endDate = min(fixedEvents[index].endDate, calendar.date(byAdding: .day, value: -1, to: boundary)!)
                updated.id = UUID()
                fixedEvents.append(updated)
            } else { fixedEvents[index] = updated }
        } else { fixedEvents.append(updated) }
    }
    public mutating func removeFixedEvent(id: UUID, now: Date, calendar: Calendar = .current) {
        guard let index = fixedEvents.firstIndex(where: { $0.id == id }) else { return }
        let event = fixedEvents[index], today = calendar.startOfDay(for: now)
        let startedToday = event.occurs(on: today, calendar: calendar) && ScheduleEngine(calendar: calendar).instant(day: today, minute: event.startMinute) <= now
        let boundary = startedToday ? calendar.date(byAdding: .day, value: 1, to: today)! : today
        if calendar.startOfDay(for: event.startDate) < boundary {
            fixedEvents[index].endDate = min(event.endDate, calendar.date(byAdding: .day, value: -1, to: boundary)!)
        } else { fixedEvents.remove(at: index) }
    }

    /// Idempotent confirmations are essential: saving/reopening must never add progress twice.
    public mutating func confirm(taskID: UUID, actualMinutes: Int, now: Date) throws {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].isUnconfirmed,
              let course = courses.first(where: { $0.id == tasks[index].courseID }) else { throw PlannerError.alreadyConfirmed }
        guard actualMinutes >= 0, actualMinutes <= tasks[index].durationMinutes else { throw PlannerError.invalidCompletion }
        let credited = min(actualMinutes, remainingMinutes(for: course))
        tasks[index].completedMinutes = credited
        tasks[index].confirmedAt = now
        tasks[index].status = actualMinutes == 0 ? .missed : (actualMinutes == tasks[index].durationMinutes ? .completed : .partial)
        completions.append(.init(id: stablePlannerID("completion|" + taskID.uuidString), courseID: course.id, taskID: taskID, minutes: credited, recordedAt: now))
    }
    /// Remove a task confirmation and restore its original plan so the released progress
    /// is included in the next automatic replan.
    public mutating func undoConfirmation(taskID: UUID, now: Date, calendar: Calendar = .current) throws {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].confirmedAt != nil else {
            throw PlannerError.notConfirmed
        }
        guard completions.contains(where: { $0.taskID == taskID }) else { throw PlannerError.notConfirmed }
        completions.removeAll { $0.taskID == taskID }
        tasks[index].completedMinutes = 0
        tasks[index].confirmedAt = nil
        tasks[index].status = calendar.isDate(tasks[index].start, inSameDayAs: now) ? .planned : .future
    }
    public mutating func replan(now: Date, calendar: Calendar = .current) -> ScheduleResult {
        let result = ScheduleEngine(calendar: calendar).generate(state: self, now: now)
        // Past, active, and confirmed plans form an immutable journal. Only untouched future plans are replaced.
        tasks.removeAll { $0.start >= now && $0.isUnconfirmed }
        tasks.append(contentsOf: result.tasks)
        tasks.sort { $0.start < $1.start }
        return result
    }
}

public enum PlannerError: Error, LocalizedError {
    case alreadyConfirmed, notConfirmed, invalidCompletion, activeConflict, pastFixedEvent, invalidFixedEvent
    case fixedConflict([FixedEventConflict])
    public var errorDescription: String? {
        switch self {
        case .alreadyConfirmed: return "这项任务已确认或课程已删除，请刷新后重试。"
        case .notConfirmed: return "这项任务尚未确认，无需撤销。"
        case .invalidCompletion: return "实际学习时长必须在 0 与计划时长之间。"
        case .activeConflict: return "该固定事项与正在进行的学习任务冲突。请先确认该任务的实际完成量，或调整固定事项时间。"
        case .pastFixedEvent: return "该事项已经开始或结束，历史课表不能修改。请添加未来日期的事项。"
        case .invalidFixedEvent: return "固定事项的起止时间或重复星期无效。"
        case .fixedConflict(let conflicts):
            let names = Array(Set(conflicts.map(\.title))).sorted().joined(separator: "、")
            return "该事项与已有固定事项冲突：\(names)。"
        }
    }
}

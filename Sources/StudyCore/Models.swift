import Foundation

public enum CourseType: String, Codable, CaseIterable, Sendable {
    case recorded = "录播课程", lessonBasedRecorded = "不定时录播课程", tutoring = "补习回放", other = "其他学习"
}
public enum TaskStatus: String, Codable, Sendable {
    case planned, completed, partial, missed, rescheduled, future
}

public struct ManualLesson: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var durationMinutes: Int
    public init(id: String = UUID().uuidString, name: String, durationMinutes: Int) {
        self.id = id; self.name = name; self.durationMinutes = durationMinutes
    }
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
    public var webCourse: WebCourseSnapshot?
    /// Local progress already represented by the latest website snapshot, by lesson.
    /// Nil retains the reconciliation used by older saved courses.
    public var webCompletionOverlaps: [String: Int]?
    /// Present for courses imported from a netdisk share. Optional for existing saved plans.
    public var netdisk: NetdiskSnapshot?
    public var netdiskLessons: [String: NetdiskLessonMeta]?
    /// Optional for compatibility with courses saved before manual lesson editing existed.
    public var manualLessons: [ManualLesson]?
    /// User-defined study order. Unknown/new lesson IDs follow the source order.
    public var lessonOrder: [String]?
    /// nil marks data saved before website-order tracking; false follows the website on refresh.
    public var lessonOrderCustomized: Bool?
    /// Original courses retained so merging preserves source metadata and progress semantics.
    public var mergedSources: [Course]?
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
    /// Nil means exact time; otherwise the bounds describe a floating window.
    public var floatingDurationMinutes: Int?
    public var isFloating: Bool { floatingDurationMinutes != nil }
    public var occupiedMinutes: Int { floatingDurationMinutes ?? (endMinute - startMinute) }
    public var validDuration: Bool { occupiedMinutes > 0 && occupiedMinutes <= endMinute - startMinute }
    public var color = "orange"
    public var notes = ""
    private enum CodingKeys: String, CodingKey {
        case id, title, startMinute, endMinute, startDate, endDate, weekdays, excludedDates, color, notes, floatingDurationMinutes
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
        self.floatingDurationMinutes = try values.decodeIfPresent(Int.self, forKey: .floatingDurationMinutes)
    }
    public func occurs(on day: Date, calendar: Calendar, includingExcluded: Bool = false) -> Bool {
        let date = calendar.startOfDay(for: day)
        guard date >= calendar.startOfDay(for: startDate), date <= calendar.startOfDay(for: endDate) else { return false }
        guard includingExcluded || !excludedDates.contains(where: { calendar.isDate($0, inSameDayAs: date) }) else { return false }
        return weekdays.isEmpty ? calendar.isDate(date, inSameDayAs: startDate) : weekdays.contains(calendar.component(.weekday, from: date))
    }
}

public struct FixedEventConflict: Identifiable, Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case overlap, floatingCapacity, activeTask }
    public var id: String { "\(eventID.uuidString)-\(date.timeIntervalSince1970)" }
    public var eventID: UUID
    public var title: String
    public var date: Date
    public var startMinute: Int
    public var endMinute: Int
    public var requestedStartMinute: Int
    public var requestedEndMinute: Int
    public var floatingDurationMinutes: Int?
    public var reason: Reason
    public init(eventID: UUID, title: String, date: Date, startMinute: Int = 0, endMinute: Int = 0,
                requestedStartMinute: Int = 0, requestedEndMinute: Int = 0,
                floatingDurationMinutes: Int? = nil, reason: Reason = .overlap) {
        self.eventID = eventID; self.title = title; self.date = date
        self.startMinute = startMinute; self.endMinute = endMinute
        self.requestedStartMinute = requestedStartMinute; self.requestedEndMinute = requestedEndMinute
        self.floatingDurationMinutes = floatingDurationMinutes; self.reason = reason
    }
    private func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    public var timeDescription: String {
        time(startMinute) + "–" + time(endMinute) + (floatingDurationMinutes.map { " · 浮动占用 \($0) 分钟" } ?? "")
    }
    public var explanation: String {
        switch reason {
        case .overlap:
            let start = max(startMinute, requestedStartMinute), end = min(endMinute, requestedEndMinute)
            return "重叠 " + time(start) + "–" + time(end) + "（\(max(0, end - start)) 分钟）"
        case .floatingCapacity:
            return "这些事项的连续时长无法在重叠窗口内排入；请缩短占用时长、调整窗口或跳过此日。"
        case .activeTask:
            return "该学习任务正在进行或处于已开始的浮动窗口，不能自动移动。"
        }
    }
}

public struct ScheduledTask: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var courseID: UUID
    public var lessonID: String?
    public var lessonName: String?
    public var start: Date
    public var durationMinutes: Int
    public var status: TaskStatus = .planned
    public var completedMinutes: Int = 0
    public var confirmedAt: Date?
    public var floatingWindowStart: Date?
    public var floatingWindowEnd: Date?
    public var isFloating: Bool { floatingWindowStart != nil && floatingWindowEnd != nil }
    public var planningStart: Date { floatingWindowStart ?? start }
    public var planningEnd: Date { floatingWindowEnd ?? end }
    public var end: Date { start.addingTimeInterval(Double(durationMinutes) * 60) }
    public var isUnconfirmed: Bool { confirmedAt == nil && (status == .planned || status == .future) }
    /// Retained history reserves time only up to confirmation. An early confirmation
    /// resolves a floating window without changing its recorded display dates.
    var retainedHistoryInterval: DateInterval {
        DateInterval(start: min(planningStart, confirmedAt ?? planningStart),
                     end: min(planningEnd, confirmedAt ?? planningEnd))
    }
    /// Ended tasks may already have been redistributed into the future schedule.
    /// Floating tasks remain reserved until their entire completion window ends.
    public func confirmationRequiresReplan(actualMinutes: Int, now: Date) -> Bool {
        actualMinutes != durationMinutes || planningEnd <= now
    }
    public init(courseID: UUID, start: Date, durationMinutes: Int, status: TaskStatus = .planned,
                lessonID: String? = nil, lessonName: String? = nil) {
        self.courseID = courseID; self.start = start; self.durationMinutes = durationMinutes; self.status = status
        self.lessonID = lessonID; self.lessonName = lessonName
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
    /// A dated override; it expires automatically on the next local day.
    public var actualStudyStart: Date? = nil
    public var dailyTaskOrders: [DailyTaskOrder]? = nil
    public var availability: [DailyAvailability] = (1...7).map { .init(weekday: $0, startMinute: 8 * 60, endMinute: 23 * 60) }
    public init() {}
    public func actualStudyStart(on day: Date, calendar: Calendar = .current) -> Date? {
        guard let start = actualStudyStart, calendar.isDate(start, inSameDayAs: day) else { return nil }
        return start
    }
}

public struct PlannerState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var courses: [Course] = []
    public var fixedEvents: [FixedEvent] = []
    public var tasks: [ScheduledTask] = []
    public var completions: [CompletionRecord] = []
    public var settings = AppSettings()
    /// Archived courses and historical records are still user data.
    public var canLoadExample: Bool {
        courses.isEmpty && fixedEvents.isEmpty && tasks.isEmpty && completions.isEmpty
    }
    public init() {}
    /// Removing a course also removes every planned and completed learning entry.
    public mutating func removeCourse(id: UUID) {
        removeCourses(ids: [id])
    }
    public mutating func removeCourses(ids: Set<UUID>) {
        courses.removeAll { ids.contains($0.id) }
        tasks.removeAll { ids.contains($0.courseID) }
        completions.removeAll { ids.contains($0.courseID) }
    }
    /// Earlier versions represented course deletion by archiving it.
    public mutating func removeArchivedCourses() {
        removeCourses(ids: Set(courses.filter(\.isArchived).map(\.id)))
    }
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
            ($0.planningEnd <= today || (minute >= settings.notificationMinute && $0.planningEnd <= now))
        }.sorted { $0.start < $1.start }
    }

    /// Keep recurring rules for past dates and today's already-started occurrence intact.
    public mutating func updateFixedEvent(_ event: FixedEvent, now: Date, calendar: Calendar = .current, skippingDates: Set<Date> = []) throws {
        guard event.startMinute >= 0, event.endMinute <= 1440, event.startMinute < event.endMinute,
              event.validDuration, event.weekdays.allSatisfy({ (1...7).contains($0) }) else { throw PlannerError.invalidFixedEvent }
        let today = calendar.startOfDay(for: now)
        guard event.endDate <= calendar.date(byAdding: .year, value: 10, to: today)! else { throw PlannerError.invalidFixedEvent }
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
        updated.excludedDates.formUnion(skipped)
        var candidate = updated.startDate
        var conflicts: [FixedEventConflict] = []
        while candidate <= updated.endDate {
            if updated.occurs(on: candidate, calendar: calendar) {
                let others = fixedEvents.filter { $0.id != event.id && $0.occurs(on: candidate, calendar: calendar) }
                let exactConflicts = others.filter { !updated.isFloating && !$0.isFloating && $0.startMinute < updated.endMinute && $0.endMinute > updated.startMinute }
                // Only inspect the connected window component; unrelated conflicts must not block this edit.
                var lower = updated.startMinute, upper = updated.endMinute
                var component: [FixedEvent] = []
                var changed = true
                while changed {
                    component = others.filter { $0.startMinute < upper && $0.endMinute > lower }
                    let nextLower = min(lower, component.map(\.startMinute).min() ?? lower)
                    let nextUpper = max(upper, component.map(\.endMinute).max() ?? upper)
                    changed = nextLower != lower || nextUpper != upper
                    lower = nextLower; upper = nextUpper
                }
                let capacityConflict = FloatingPlacement.reserve(component + [updated]) == nil
                let involved = capacityConflict ? component : exactConflicts
                for other in involved {
                    conflicts.append(.init(eventID: other.id, title: other.title, date: candidate,
                        startMinute: other.startMinute, endMinute: other.endMinute,
                        requestedStartMinute: updated.startMinute, requestedEndMinute: updated.endMinute,
                        floatingDurationMinutes: other.floatingDurationMinutes,
                        reason: exactConflicts.contains(where: { $0.id == other.id }) ? .overlap : .floatingCapacity))
                }
                if capacityConflict && involved.isEmpty { throw PlannerError.invalidFixedEvent }
            }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
        }
        if !conflicts.isEmpty {
            throw PlannerError.fixedConflict(conflicts.sorted { $0.date != $1.date ? $0.date < $1.date : ($0.startMinute != $1.startMinute ? $0.startMinute < $1.startMinute : $0.id < $1.id) })
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

    /// Change only one occurrence, including an already-started occurrence today.
    /// Unlike editing a recurring rule, this preserves its ID and date bounds.
    public mutating func setFixedEventSkipped(id: UUID, on day: Date, skipped: Bool, now: Date, calendar: Calendar = .current) throws {
        let date = calendar.startOfDay(for: day)
        guard date >= calendar.startOfDay(for: now) else { throw PlannerError.pastFixedOccurrence }
        guard let index = fixedEvents.firstIndex(where: { $0.id == id }),
              fixedEvents[index].occurs(on: date, calendar: calendar, includingExcluded: true) else {
            throw PlannerError.invalidFixedOccurrence
        }
        var event = fixedEvents[index]
        let wasSkipped = !event.occurs(on: date, calendar: calendar)
        guard wasSkipped != skipped else { return }
        event.excludedDates = Set(event.excludedDates.map { calendar.startOfDay(for: $0) })
        if skipped {
            event.excludedDates.insert(date)
        } else {
            event.excludedDates.remove(date)
            // Validate just the restored date on a copy, without splitting the rule
            // or mutating the real state when another fixed item occupies its slot.
            var validation = self
            var occurrence = event
            occurrence.startDate = date
            occurrence.endDate = date
            occurrence.weekdays = []
            try validation.updateFixedEvent(occurrence, now: calendar.startOfDay(for: now), calendar: calendar)
        }
        fixedEvents[index] = event
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
        if let courseIndex = courses.firstIndex(where: { $0.id == tasks[index].courseID }) {
            courses[courseIndex] = reconcilingWebsiteBaseline(for: courses[courseIndex])
        }
    }
    /// Saving new daily windows replaces today's draft, just like entering an
    /// actual start. Keep that dated anchor so later replans cannot accumulate
    /// ended copies of the same lessons. Confirmations and prior days are retained.
    public mutating func updateStudySettings(_ updated: AppSettings, now: Date, calendar: Calendar = .current) {
        func windows(_ settings: AppSettings) -> [String] {
            settings.availability.map { "\($0.weekday)|\($0.startMinute)|\($0.endMinute)" }.sorted()
        }
        let changedWindows = windows(settings) != windows(updated)
        let actualStart = settings.actualStudyStart
        settings = updated
        // The settings editor may have been opened before today's start changed.
        settings.actualStudyStart = actualStart
        if changedWindows && settings.actualStudyStart(on: now, calendar: calendar) == nil {
            settings.actualStudyStart = now
        }
    }
    public mutating func recordActualStudyStart(minute: Int, now: Date, calendar: Calendar = .current) throws {
        guard (0..<1440).contains(minute) else { throw PlannerError.invalidStudyStart }
        settings.actualStudyStart = ScheduleEngine(calendar: calendar).instant(day: now, minute: minute)
        // The explicit homepage action invalidates the old draft immediately,
        // including ended duplicate rows left by an earlier replan.
        tasks.removeAll { $0.isUnconfirmed && calendar.isDate($0.start, inSameDayAs: now) }
    }
    public mutating func replan(now: Date, calendar: Calendar = .current) -> ScheduleResult {
        let result = ScheduleEngine(calendar: calendar).generate(state: self, now: now)
        // Keep ended and confirmed history; all unfinished plans, including today, are replaceable.
        let hasActualStart = settings.actualStudyStart(on: now, calendar: calendar) != nil
        tasks.removeAll {
            $0.isUnconfirmed && ($0.planningEnd > now ||
                (hasActualStart && calendar.isDate($0.start, inSameDayAs: now)))
        }
        tasks.append(contentsOf: result.tasks)
        tasks.sort { $0.start < $1.start }
        return result
    }
}

public enum PlannerError: Error, LocalizedError {
    case alreadyConfirmed, notConfirmed, invalidCompletion, activeConflict, pastFixedEvent, invalidFixedEvent, invalidStudyStart
    case pastFixedOccurrence, invalidFixedOccurrence
    case fixedConflict([FixedEventConflict])
    public var errorDescription: String? {
        switch self {
        case .invalidStudyStart: return "实际开课时间须为当天的 00:00–23:59。"
        case .pastFixedOccurrence: return "只能临时移除或恢复今天及未来的固定事项，往日记录保留。"
        case .invalidFixedOccurrence: return "该事项在所选日期没有安排，请刷新日程后重试。"
        case .alreadyConfirmed: return "这项任务已确认或课程已删除，请刷新后重试。"
        case .notConfirmed: return "这项任务尚未确认，无需撤销。"
        case .invalidCompletion: return "实际学习时长必须在 0 与计划时长之间。"
        case .activeConflict: return "该固定事项与正在进行的学习任务冲突。请先确认该任务的实际完成量，或调整固定事项时间。"
        case .pastFixedEvent: return "该事项已经开始或结束，历史课表不能修改。请添加未来日期的事项。"
        case .invalidFixedEvent: return "请检查事项时间、重复星期和占用时长；占用时长须大于 0 且不超过所在时段。"
        case .fixedConflict(let conflicts):
            return conflicts.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)) · 「\($0.title)」\($0.timeDescription)；\($0.explanation)" }.joined(separator: "\n")
        }
    }
}

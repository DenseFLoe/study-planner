import Foundation

/// Business data only: machine credentials and supervision bindings never enter this format.
public struct PlannerBackup: Codable, Sendable {
    public var format = 1
    public var id = UUID()
    public var createdAt: Date
    public var reason: String
    public var deletedCourseID: UUID?
    public var state: PlannerState

    public init(state: PlannerState, reason: String, deletedCourseID: UUID? = nil, now: Date = Date()) {
        self.state = state; self.reason = reason; self.deletedCourseID = deletedCourseID; createdAt = now
    }

    public func validated() throws -> PlannerBackup {
        func unique<T: Identifiable>(_ values: [T]) -> Bool { Set(values.map(\.id)).count == values.count }
        func validCourse(_ course: Course, depth: Int = 0) -> Bool {
            guard depth < 32, course.totalMinutes >= 0, course.totalMinutes <= 10_000_000,
                  course.initialCompletedMinutes >= 0, course.initialCompletedMinutes <= course.totalMinutes,
                  (0...1440).contains(course.minimumBlockMinutes),
                  course.startDate.timeIntervalSince1970.isFinite, course.deadline.timeIntervalSince1970.isFinite else { return false }
            if let lessons = course.manualLessons {
                guard lessons.count <= 100_000, unique(lessons),
                      lessons.allSatisfy({ !$0.id.isEmpty && (1...10_000_000).contains($0.durationMinutes) }) else { return false }
            }
            if let lessons = course.webCourse?.lessons {
                guard lessons.count <= 100_000, Set(lessons.map(\.id)).count == lessons.count,
                      lessons.allSatisfy({ lesson in
                          (lesson.durationSeconds.map { $0.isFinite && $0 > 0 && $0 <= 36_000_000 } ?? true) &&
                          (lesson.watchedPercent.map { $0.isFinite && (0...100).contains($0) } ?? true)
                      }) else { return false }
            }
            return course.mergedSources?.allSatisfy { validCourse($0, depth: depth + 1) } ?? true
        }
        guard format == 1, state.schemaVersion == 1,
              state.courses.count + state.tasks.count + state.completions.count + state.fixedEvents.count <= 200_000,
              unique(state.courses), unique(state.tasks), unique(state.fixedEvents), unique(state.completions),
              (1...1440).contains(state.settings.minimumScheduleUnit),
              (0..<1440).contains(state.settings.notificationMinute),
              state.settings.availability.allSatisfy({ (1...7).contains($0.weekday) && $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.startMinute < $0.endMinute }),
              state.courses.allSatisfy({ validCourse($0) }),
              state.fixedEvents.allSatisfy({ $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.startMinute < $0.endMinute && $0.validDuration && $0.weekdays.allSatisfy { (1...7).contains($0) } }),
              state.tasks.allSatisfy({ (1...1440).contains($0.durationMinutes) && (0...$0.durationMinutes).contains($0.completedMinutes) }),
              state.completions.allSatisfy({ (0...1440).contains($0.minutes) }) else { throw SyncFailure.invalidData }
        var ledger = SyncLedger()
        try ledger.capture(state)
        _ = try ledger.materialize()
        return self
    }
}

public extension Course {
    /// Whitelist display fields; future scheduling fields conservatively require a replan.
    func hasSameSchedulingInputs(as other: Course) -> Bool {
        var value = self
        value.name = other.name; value.notes = other.notes; value.color = other.color
        return value == other
    }
}

public extension PlannerState {
    mutating func restoreDeletedCourse(from backup: PlannerBackup) throws {
        guard let id = backup.deletedCourseID, let course = backup.state.courses.first(where: { $0.id == id }),
              !courses.contains(where: { $0.id == id }) else { throw SyncFailure.invalidData }
        let restoredTasks = backup.state.tasks.filter { $0.courseID == id }
        let restoredCompletions = backup.state.completions.filter { $0.courseID == id }
        guard Set(tasks.map(\.id)).isDisjoint(with: restoredTasks.map(\.id)),
              Set(completions.map(\.id)).isDisjoint(with: restoredCompletions.map(\.id)) else { throw SyncFailure.invalidData }
        courses.append(course)
        tasks.append(contentsOf: restoredTasks)
        completions.append(contentsOf: restoredCompletions)
    }
}

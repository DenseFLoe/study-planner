import Foundation

extension PlannerState {
    /// Reparent offline confirmations before source-course tombstones remove their records.
    /// A replaced draft can be recovered as confirmed history from its tombstone payload.
    mutating func reconcileMergedCourseProgress(deletedIDs: Set<UUID>, deletedTasks: [ScheduledTask]) throws {
        struct Destination: Equatable {
            var courseID: UUID
            var prefix: String
        }
        var destinations: [UUID: Destination] = [:]
        func collect(_ sources: [Course], destination: UUID, prefix: String) throws {
            for source in sources {
                let path = prefix + source.id.uuidString + "/"
                let value = Destination(courseID: destination, prefix: path)
                if let old = destinations[source.id], old != value { throw SyncFailure.invalidData }
                destinations[source.id] = value
                try collect(source.mergedSources ?? [], destination: destination, prefix: path)
            }
        }
        for course in courses where !course.isArchived && !deletedIDs.contains(course.id) {
            try collect(course.mergedSources ?? [], destination: course.id, prefix: "")
        }
        func redirect(_ task: ScheduledTask) -> ScheduledTask {
            var task = task
            if deletedIDs.contains(task.courseID), let target = destinations[task.courseID] {
                task.lessonID = target.prefix + (task.lessonID ?? "whole")
                task.courseID = target.courseID
            }
            return task
        }
        tasks = tasks.map(redirect)
        let mergedIDs = Set(destinations.values.map(\.courseID))
        for index in completions.indices {
            if deletedIDs.contains(completions[index].courseID), let target = destinations[completions[index].courseID] {
                completions[index].courseID = target.courseID
            }
            let record = completions[index]
            guard mergedIDs.contains(record.courseID) else { continue }
            if !tasks.contains(where: { $0.id == record.taskID }),
               let old = deletedTasks.first(where: { $0.id == record.taskID }) {
                let recovered = redirect(old)
                if recovered.courseID == record.courseID { tasks.append(recovered) }
            }
            if let taskIndex = tasks.firstIndex(where: { $0.id == record.taskID && $0.courseID == record.courseID }) {
                guard record.minutes >= 0, record.minutes <= tasks[taskIndex].durationMinutes else { throw SyncFailure.invalidData }
                if tasks[taskIndex].confirmedAt == record.recordedAt && tasks[taskIndex].completedMinutes == record.minutes { continue }
                tasks[taskIndex].completedMinutes = record.minutes
                tasks[taskIndex].confirmedAt = record.recordedAt
                tasks[taskIndex].status = record.minutes == 0 ? .missed : (record.minutes == tasks[taskIndex].durationMinutes ? .completed : .partial)
            }
        }
    }

    public mutating func mergeCourses(ids: Set<UUID>, name: String) throws -> Course {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = courses.filter { ids.contains($0.id) && !$0.isArchived }.sorted {
            let comparison = NetdiskTitles.naturalCompare($0.name, $1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
        guard sources.count >= 2, sources.count == ids.count, !title.isEmpty else {
            throw WebCourseImportError.invalid("请选择至少两门现有课程，并填写合并后的名称。")
        }
        let taskIDs = Set(tasks.filter { ids.contains($0.courseID) }.map(\.id))
        guard completions.filter({ ids.contains($0.courseID) }).allSatisfy({ taskIDs.contains($0.taskID) }) else {
            throw WebCourseImportError.invalid("部分完成记录缺少关联任务，暂不能安全合并这些课程。")
        }
        let total = sources.reduce(0) { $0 + $1.totalMinutes }
        guard total > 0, total <= 600_000 else {
            throw WebCourseImportError.invalid("合并后的总时长须在 10,000 小时以内。")
        }
        var merged = Course(name: title, totalMinutes: total,
                            startDate: sources.map(\.startDate).min()!, deadline: sources.map(\.deadline).min()!)
        merged.type = .lessonBasedRecorded
        merged.mergedSources = sources
        merged.initialCompletedMinutes = sources.reduce(0) { $0 + $1.initialCompletedMinutes }
        merged.priority = sources.map(\.priority).max()!
        merged.color = sources[0].color
        merged.autoScheduleEnabled = sources.contains { $0.autoScheduleEnabled }
        for index in tasks.indices where ids.contains(tasks[index].courseID) {
            tasks[index].lessonID = tasks[index].courseID.uuidString + "/" + (tasks[index].lessonID ?? "whole")
            tasks[index].courseID = merged.id
        }
        for index in completions.indices where ids.contains(completions[index].courseID) {
            completions[index].courseID = merged.id
        }
        for index in courses.indices where ids.contains(courses[index].id) { courses[index].isArchived = true }
        merged.lessonOrder = mergedWorkItems(for: merged, sources: sources).map(\.id)
        courses.append(merged)
        return merged
    }

    func mergedWorkItems(for course: Course, sources: [Course]) -> [LessonWorkItem] {
        var items: [LessonWorkItem] = []
        for source in sources {
            let prefix = source.id.uuidString + "/"
            let sourceState = mergedSourceState(for: source, in: course)
            var lessons = sourceState.lessonWorkItems(for: source)
            if lessons.isEmpty {
                lessons = [.init(id: "whole", name: source.name, subject: source.name, stage: "", chapter: "",
                                 durationMinutes: source.totalMinutes, remainingMinutes: sourceState.remainingMinutes(for: source))]
            }
            items += lessons.map {
                var lesson = $0; lesson.id = prefix + lesson.id
                if lesson.subject.isEmpty { lesson.subject = source.name }
                return lesson
            }
        }
        return LessonOrdering.intelligent(items)
    }

    func mergedSourceState(for source: Course, in course: Course) -> PlannerState {
        let prefix = source.id.uuidString + "/"
        var subset = self
        subset.tasks = tasks.filter { $0.courseID == course.id && ($0.lessonID?.hasPrefix(prefix) ?? false) }.map {
            var task = $0
            task.courseID = source.id
            task.lessonID = String(task.lessonID!.dropFirst(prefix.count))
            return task
        }
        let taskIDs = Set(subset.tasks.map(\.id))
        subset.completions = completions.filter { $0.courseID == course.id && taskIDs.contains($0.taskID) }.map {
            var record = $0; record.courseID = source.id; return record
        }
        return subset
    }
}

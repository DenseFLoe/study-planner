import Foundation

extension PlannerState {
    /// Save an editor draft together with any manual-lesson deletion tombstones.
    /// The draft's baseline is already adjusted by removeLessons before display.
    public mutating func updateCourse(_ edited: Course) throws {
        var saved = edited
        if let original = courses.first(where: { $0.id == saved.id }),
           original.type == .lessonBasedRecorded, original.webCourse == nil, original.mergedSources == nil,
           saved.type == .lessonBasedRecorded, saved.webCourse == nil, saved.mergedSources == nil,
           let previous = original.manualLessons, let lessons = saved.manualLessons {
            let removed = Set(previous.map(\.id)).subtracting(lessons.map(\.id))
            if !removed.isEmpty {
                guard !lessons.isEmpty else {
                    throw WebCourseImportError.invalid("请至少保留一节课；删除整门课程请使用「删除课程」。")
                }
                try validateLessonRecords(for: original, known: Set(lessonWorkItems(for: original).map(\.id)))
            }
            let deleted = Set(original.deletedLessonIDs ?? []).union(saved.deletedLessonIDs ?? []).union(removed)
            guard deleted.isDisjoint(with: lessons.map(\.id)) else {
                throw WebCourseImportError.invalid("部分课节已删除，请重新打开课程后编辑。")
            }
            saved.deletedLessonIDs = deleted.isEmpty ? nil : deleted.sorted()
            saved.lessonOrder = saved.lessonOrder?.filter { !deleted.contains($0) }
            saved.netdiskLessons = saved.netdiskLessons?.filter { !deleted.contains($0.key) }
        }
        var next = self
        let index: Int
        if let existing = next.courses.firstIndex(where: { $0.id == saved.id }) {
            index = existing
            next.courses[index] = saved
        } else {
            index = next.courses.count
            next.courses.append(saved)
        }
        next.purgeDeletedLessonRecords()
        if saved.type == .lessonBasedRecorded, saved.lessonOrder == nil {
            if let website = saved.webCourse {
                next.courses[index].lessonOrder = website.lessons.map(\.id)
                next.courses[index].lessonOrderCustomized = false
            } else {
                next.courses[index].lessonOrder = LessonOrdering.intelligent(next.lessonWorkItems(for: saved)).map(\.id)
            }
        }
        self = next
    }

    /// Atomically delete a subset of a course, including the selected lessons' history.
    public mutating func removeLessons(courseID: UUID, ids: Set<String>) throws {
        guard let index = courses.firstIndex(where: { $0.id == courseID && !$0.isArchived }) else {
            throw WebCourseImportError.invalid("课程已不存在，请重新打开。")
        }
        let course = courses[index]
        let known = Set(lessonWorkItems(for: course).map(\.id))
        guard !ids.isEmpty, ids.isSubset(of: known) else {
            throw WebCourseImportError.invalid("请选择现有课节后重试。")
        }
        guard ids != known else {
            throw WebCourseImportError.invalid("请至少保留一节课；删除整门课程请使用「删除课程」。")
        }
        try validateLessonRecords(for: course, known: known)
        courses[index] = try removingLessons(ids, from: course)
        purgeDeletedLessonRecords()
    }

    private func validateLessonRecords(for course: Course, known: Set<String>) throws {
        let taskByID = Dictionary(tasks.filter { $0.courseID == course.id }.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        guard completions.filter({ $0.courseID == course.id }).allSatisfy({
            taskByID[$0.taskID]?.lessonID.map(known.contains) == true
        }) else {
            throw WebCourseImportError.invalid("部分旧完成记录没有课节标识，暂不能安全删除部分课节。")
        }
    }

    private func removingLessons(_ ids: Set<String>, from course: Course) throws -> Course {
        var updated = course
        if let sources = course.mergedSources {
            var retained: [Course] = []
            for source in sources {
                let prefix = source.id.uuidString + "/"
                let selected = Set(ids.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
                if selected.isEmpty { retained.append(source); continue }
                let subset = mergedSourceState(for: source, in: course)
                var known = Set(subset.lessonWorkItems(for: source).map(\.id))
                if known.isEmpty { known = ["whole"] }
                if selected == known { continue }
                retained.append(try subset.removingLessons(selected, from: source))
            }
            updated.mergedSources = retained
            updated.totalMinutes = retained.reduce(0) { $0 + $1.totalMinutes }
            updated.initialCompletedMinutes = retained.reduce(0) { $0 + $1.initialCompletedMinutes }
        } else if var snapshot = course.webCourse {
            snapshot.lessons.removeAll { ids.contains($0.id) }
            var subset = self
            let removed = Set(tasks.filter { $0.courseID == course.id && ids.contains($0.lessonID ?? "") }.map(\.id))
            subset.tasks.removeAll { removed.contains($0.id) }
            subset.completions.removeAll { removed.contains($0.taskID) }
            subset.courses = [course]
            // Reuse the import's per-lesson reconciliation with the original snapshot time.
            let now = Date()
            try subset.importWebCourses([snapshot], deadline: max(now, course.deadline), now: now)
            updated = subset.courses[0]
        } else if let lessons = course.manualLessons {
            var baseline = max(0, course.initialCompletedMinutes)
            var removedBaseline = 0
            for lesson in lessons {
                let credit = min(baseline, lesson.durationMinutes)
                if ids.contains(lesson.id) { removedBaseline += credit }
                baseline -= credit
            }
            updated.manualLessons = lessons.filter { !ids.contains($0.id) }
            updated.totalMinutes = updated.manualLessons!.reduce(0) { $0 + $1.durationMinutes }
            updated.initialCompletedMinutes = max(0, course.initialCompletedMinutes - removedBaseline)
        } else {
            throw WebCourseImportError.invalid("这门课程没有可删除的独立课节。")
        }
        updated.deletedLessonIDs = Set(course.deletedLessonIDs ?? []).union(ids).sorted()
        updated.lessonOrder = updated.lessonOrder?.filter { !ids.contains($0) }
        updated.netdiskLessons = updated.netdiskLessons?.filter { !ids.contains($0.key) }
        updated.webCompletionOverlaps = updated.webCompletionOverlaps?.filter { !ids.contains($0.key) }
        return updated
    }

    /// A peer may confirm deleted lessons while offline. Tombstone task payloads still identify them.
    mutating func purgeDeletedLessonRecords(additionalTasks: [ScheduledTask] = []) {
        func deletions(in course: Course, prefix: String = "") -> Set<String> {
            var ids = Set((course.deletedLessonIDs ?? []).map { prefix + $0 })
            for source in course.mergedSources ?? [] {
                ids.formUnion(deletions(in: source, prefix: prefix + source.id.uuidString + "/"))
            }
            return ids
        }
        let deleted = Dictionary(courses.map { ($0.id, deletions(in: $0)) },
                                 uniquingKeysWith: { first, _ in first })
        let removed = Set((tasks + additionalTasks).filter {
            deleted[$0.courseID]?.contains($0.lessonID ?? "") == true
        }.map(\.id))
        tasks.removeAll { removed.contains($0.id) }
        completions.removeAll { removed.contains($0.taskID) }
    }
}

import Foundation

extension PlannerState {
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
        let taskByID = Dictionary(tasks.filter { $0.courseID == courseID }.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        guard completions.filter({ $0.courseID == courseID }).allSatisfy({
            taskByID[$0.taskID]?.lessonID.map(known.contains) == true
        }) else {
            throw WebCourseImportError.invalid("部分旧完成记录没有课节标识，暂不能安全删除部分课节。")
        }
        courses[index] = try removingLessons(ids, from: course)
        purgeDeletedLessonRecords()
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

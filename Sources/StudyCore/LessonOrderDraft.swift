import Foundation

public enum LessonOrderEditError: LocalizedError, Equatable {
    case removed, orderChanged, lessonsChanged, progressChanged, invalidOrder

    public var errorDescription: String? {
        switch self {
        case .removed: "这门课程已被删除，不能保存旧排序草稿。请关闭窗口查看最新课程。"
        case .orderChanged: "课节顺序在编辑期间已被修改。最新顺序和当前草稿均已保留，请重新载入后再调整。"
        case .lessonsChanged: "课节列表、名称或时长在编辑期间已变化。当前草稿已保留，请重新载入后再调整。"
        case .progressChanged: "待删除课节的学习记录或进度已有变化，未执行删除。当前草稿已保留，请重新载入后确认。"
        case .invalidOrder: "排序草稿与待保留课节不一致，请重新载入后再调整。"
        }
    }
}

/// An editor's stable baseline and intent, reapplied to the latest state at commit.
/// Never writes the snapshot's course or completion rows back over newer data.
public struct LessonOrderDraft: Sendable {
    private let baseline: PlannerState
    public let course: Course
    public let originalOrder: [String]
    public var order: [String]
    public private(set) var deleted = Set<String>()

    public init(course: Course, state: PlannerState) {
        baseline = state
        self.course = state.courses.first { $0.id == course.id } ?? course
        originalOrder = state.lessonWorkItems(for: self.course).map(\.id)
        order = originalOrder
    }

    public var hasChanges: Bool { order != originalOrder || !deleted.isEmpty }
    public var websiteOrder: [String]? {
        guard let website = course.webCourse else { return nil }
        return LessonOrdering.resolved(ids: originalOrder, preferred: website.lessons.map(\.id))
            .filter { !deleted.contains($0) }
    }

    public func preview() throws -> PlannerState {
        var value = baseline
        try apply(to: &value)
        return value
    }

    public mutating func removeLessons(_ ids: Set<String>) throws {
        var next = self
        next.deleted.formUnion(ids)
        next.order.removeAll { ids.contains($0) }
        _ = try next.preview()
        self = next
    }

    public func apply(to state: inout PlannerState) throws {
        guard let current = state.courses.first(where: { $0.id == course.id && !$0.isArchived }) else {
            throw LessonOrderEditError.removed
        }
        guard hasChanges else { return }
        let known = Set(originalOrder)
        guard deleted.isSubset(of: known), !order.isEmpty,
              order.count == Set(order).count, Set(order) == known.subtracting(deleted) else {
            throw LessonOrderEditError.invalidOrder
        }
        guard Self.catalog(course) == Self.catalog(current),
              Self.descriptions(in: baseline, course: course) == Self.descriptions(in: state, course: current) else {
            throw LessonOrderEditError.lessonsChanged
        }
        let currentOrder = state.lessonWorkItems(for: current).map(\.id)
        let customized = websiteOrder != order
        guard currentOrder == originalOrder || (deleted.isEmpty && currentOrder == order),
              current.lessonOrderCustomized == course.lessonOrderCustomized || current.lessonOrderCustomized == customized else {
            throw LessonOrderEditError.orderChanged
        }
        if !deleted.isEmpty {
            guard deletionHistory(in: baseline, course: course) == deletionHistory(in: state, course: current) else {
                throw LessonOrderEditError.progressChanged
            }
        }
        var next = state
        if !deleted.isEmpty { try next.removeLessons(courseID: course.id, ids: deleted) }
        let index = next.courses.firstIndex { $0.id == course.id }!
        next.courses[index].lessonOrder = order
        next.courses[index].lessonOrderCustomized = customized
        state = next
    }

    private struct Catalog: Equatable {
        var id: UUID
        var type: CourseType
        var manual: [ManualLesson]?
        var websiteID: String?
        var website: [WebCourseLesson]?
        var deleted: [String]
        var sources: [Catalog]?
    }

    private static func catalog(_ course: Course) -> Catalog {
        Catalog(id: course.id, type: course.type, manual: course.manualLessons, websiteID: course.webCourse?.packageID,
                website: course.webCourse?.lessons.map { lesson in
                    var metadata = lesson
                    metadata.watchedPercent = nil; metadata.markedFinished = false
                    return metadata
                }, deleted: (course.deletedLessonIDs ?? []).sorted(), sources: course.mergedSources?.map(catalog))
    }

    private static func descriptions(in state: PlannerState, course: Course) -> [LessonWorkItem] {
        state.lessonWorkItems(for: course).map { item in
            var metadata = item; metadata.remainingMinutes = 0
            return metadata
        }.sorted { $0.id < $1.id }
    }

    private struct DeletionHistory: Equatable {
        var remaining: [String: Int]
        var tasks: [UUID: ScheduledTask]
        var completions: [UUID: CompletionRecord]
    }

    private func deletionHistory(in state: PlannerState, course: Course) -> DeletionHistory {
        let tasks = state.tasks.filter { $0.courseID == course.id && deleted.contains($0.lessonID ?? "") }
        let taskIDs = Set(tasks.map(\.id))
        let records = state.completions.filter { $0.courseID == course.id && taskIDs.contains($0.taskID) }
        let confirmedIDs = Set(records.map(\.taskID))
        return DeletionHistory(
            remaining: Dictionary(uniqueKeysWithValues: state.lessonWorkItems(for: course)
                .filter { deleted.contains($0.id) }.map { ($0.id, $0.remainingMinutes) }),
            tasks: Dictionary(uniqueKeysWithValues: tasks.filter { !$0.isUnconfirmed || confirmedIDs.contains($0.id) }.map { ($0.id, $0) }),
            completions: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }))
    }
}

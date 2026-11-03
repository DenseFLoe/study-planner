import Foundation

public enum CourseEditError: LocalizedError {
    case removed
    case conflictingChanges

    public var errorDescription: String? {
        switch self {
        case .removed: "这门课程已被删除，旧编辑窗口不能重新创建它。请关闭窗口后查看最新课程。"
        case .conflictingChanges: "这门课程在编辑期间已有其他修改，与当前草稿冲突。请重新打开课程后编辑，最新数据已保留。"
        }
    }
}

public extension Course {
    /// The baseline belongs to the editor's draft, not the later save transaction.
    func mergingDraft(from baseline: Course, into current: Course) throws -> Course {
        guard id == baseline.id, id == current.id else { throw CourseEditError.conflictingChanges }
        guard !current.isArchived else { throw CourseEditError.removed }
        var merged: Course
        if hasSameSchedulingInputs(as: baseline) {
            merged = current
        } else if current.hasSameSchedulingInputs(as: baseline) || hasSameSchedulingInputs(as: current) {
            merged = self
        } else {
            // Lesson lists, totals, progress and deletion markers must remain a
            // coherent set; independently combining these fields can lose work.
            throw CourseEditError.conflictingChanges
        }
        func displayField(_ edited: String, _ old: String, _ latest: String) throws -> String {
            if edited == old { return latest }
            guard latest == old || latest == edited else { throw CourseEditError.conflictingChanges }
            return edited
        }
        merged.name = try displayField(name, baseline.name, current.name)
        merged.notes = try displayField(notes, baseline.notes, current.notes)
        merged.color = try displayField(color, baseline.color, current.color)
        return merged
    }
}

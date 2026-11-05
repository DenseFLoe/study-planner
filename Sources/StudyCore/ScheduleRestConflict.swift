import Foundation

/// A necessary rest budget inside the current study windows, not a claim about
/// how many study minutes must be removed. Moving a window can change the bound.
public struct ScheduleRestConflict: Codable, Equatable, Sendable {
    public var requiredStudyMinutes: Int
    public var minimumRestMinutes: Int
    public var availableMinutes: Int

    static func diagnose(studyMinutes: Int, blockCount: Int,
                         availableMinutes: Int, windowCount: Int) -> Self? {
        // Each disjoint free span can host one block without an internal break.
        // All additional blocks need a break within a span. Grant every span
        // this exemption even if it is too short for a block, and grant every
        // external gap a full break even if it is under 15 minutes. These
        // optimistic assumptions can miss conflicts, never prove a false one.
        let rest = max(0, blockCount - windowCount) * ScheduleEngine.breakMinutes
        guard studyMinutes > 0, studyMinutes <= availableMinutes,
              rest > availableMinutes - studyMinutes else { return nil }
        return .init(requiredStudyMinutes: studyMinutes, minimumRestMinutes: rest,
                     availableMinutes: availableMinutes)
    }

    public var explanation: String {
        "剩余学习需要 \(requiredStudyMinutes) 分钟；按现有空档，学习之间至少还需预留 \(minimumRestMinutes) 分钟休息，但最多只有 \(availableMinutes) 分钟可用。即使暂不扣除浮动事项，也无法同时容纳学习和休息。"
    }

    public var recovery: String {
        "可增加截止日前的可学习时段，或调整固定事项，把完整学习块移到有足够间隔的其他空档。调整后重新排程核对；未排入的学习量与截止日期仍保留。"
    }
}

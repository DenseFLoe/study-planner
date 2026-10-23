import SwiftUI
import StudyCore

struct ScheduleExplanationPanel: View {
    let state: PlannerState
    let result: ScheduleResult
    let hasUnsavedChanges: Bool

    var body: some View {
        Section("当前为什么这样排课") {
            ForEach(Array(ScheduleExplanation.lines(state: state, result: result).enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout)
            }
            Text(hasUnsavedChanges ? "以上解释对应已保存的设置。保存并重新排程后更新原因。" : "依据已保存的设置与最近一次排程结果。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

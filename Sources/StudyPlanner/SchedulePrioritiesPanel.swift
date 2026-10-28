import SwiftUI
import StudyCore

struct SchedulePrioritiesPanel: View {
    @Binding var settings: AppSettings

    var body: some View {
        Section("排课逻辑权重") {
            Text("数字越小越优先。先满足 0 级时间约束，再满足立即学习要求，最后按等级考虑已有偏好；同级按下方默认顺序处理。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("0 级 · 必须遵守", systemImage: "lock.fill").font(.headline)
                Text("规定日期与固定课表").fontWeight(.medium)
                Text("遵守课程开始日、截止日、可学习时段和实际开课时间；避开固定事项，浮动事项在规定窗口内完成。空间不足时提示，不能靠降低等级突破时间限制。")
                Text("保留往日及已确认记录；保持整节课与课节顺序，以及 15 分钟课间休息。普通课程遵守最小时间块，最后余量可更短。")
            }
            .font(.callout).padding(.vertical, 6)
            Text("Mac 主页的“立即学习”仅次于上述时间约束，高于以下所有偏好和拖动顺序；重排必须保留各课程截止日前已排入的学习量。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(ScheduleRule.allCases) { rule in
                VStack(alignment: .leading, spacing: 6) {
                    Picker(rule.title, selection: Binding(
                        get: { settings.schedulePriorities.level(rule) },
                        set: { level in
                            var priorities = settings.schedulePriorities
                            priorities.levels[rule.rawValue] = level
                            settings.schedulePriorities = priorities
                        }
                    )) {
                        Text("1 级 · 首要偏好").tag(1)
                        Text("2 级 · 次要偏好").tag(2)
                        Text("3 级 · 更次要").tag(3)
                        Text("4 级 · 最后考虑").tag(4)
                    }
                    Text(rule.explanation).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            Text("这些是尽量满足的偏好。截止日期或连续空档紧张时会让步；默认顺序下（包括同级仍按默认顺序时），3 倍加量先于混排比较；改变规则先后顺序后取消此例外。手动调整的当天顺序在仍可排入时保留。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("恢复默认权重") { settings.schedulePriorities = SchedulePriorities() }
                Spacer()
                Text("点击“保存并重新排程”生效").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

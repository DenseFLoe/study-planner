import SwiftUI
import StudyCore

struct RiskView: View {
    @Bindable var store: PlannerStore
    var adjustSettings: () -> Void
    var editCourse: (Course) -> Void
    var reviewEvents: (Date) -> Void
    @AppStorage("dailyStudyLoadWarningMinutes") private var dailyLoadWarningMinutes = 480
    @Environment(\.dismiss) private var dismiss
    @State private var section = Section.courses
    @State private var showAllDays = false

    private enum Section: String, CaseIterable {
        case courses = "课程安排", load = "每日负担", recovery = "补回安排"
    }

    var body: some View {
        let health = ScheduleHealthAnalyzer().assess(state: store.state, result: store.result,
                                                    now: Date(), heavyDayMinutes: dailyLoadWarningMinutes)
        let presentation = health.map { ScheduleHealthPresentation(health: $0, warningMinutes: dailyLoadWarningMinutes) }
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(presentation?.title ?? "学习安排检查").font(.title2.bold())
                Text(presentation?.overview ?? "当前没有待排课程，可在下方检查事项安排。")
                    .font(.body).fixedSize(horizontal: false, vertical: true)
            }
            Picker("查看内容", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch section {
            case .courses:
                courseDetails(presentation: presentation)
            case .load:
                if let presentation { dailyLoad(presentation) } else { emptyMessage("目前没有已排入的学习任务。") }
            case .recovery:
                if let presentation { recovery(presentation) } else { emptyMessage("目前没有需要补回的学习安排。") }
            }
            Divider()
            HStack {
                Button("调整可学习时间", action: adjustSettings)
                Spacer()
                Button("知道了") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 760, height: 700)
    }

    private func courseDetails(presentation: ScheduleHealthPresentation?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let presentation {
                    Text(presentation.guidance).fixedSize(horizontal: false, vertical: true)
                }
                let courses = CourseScheduleAttention.items(state: store.state, result: store.result)
                if !courses.isEmpty {
                    Text("需要检查的课程").font(.headline)
                    ForEach(courses) { item in courseCard(item) }
                }
                if !store.result.conflicts.isEmpty {
                    Text("已确认的时间冲突").font(.headline)
                    ForEach(Array(store.result.conflicts.enumerated()), id: \.offset) { _, conflict in
                        conflictCard(conflict)
                    }
                }
                ForEach(store.result.floatingIssues.prefix(20)) { issue in
                    FloatingScheduleIssueCard(issue: issue, reviewEvents: reviewEvents)
                }
                if store.result.floatingIssues.count > 20 {
                    Text("另有 \(store.result.floatingIssues.count - 20) 天需要核对；先调整重复规则，再查看更新后的结果。")
                }
                let diagnostics = store.result.diagnostics.filter {
                    store.result.floatingIssues.isEmpty || !$0.hasPrefix("浮动事项的连续时长")
                }
                if !diagnostics.isEmpty {
                    Text("其他需要检查的情况").font(.headline)
                    ForEach(diagnostics, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                }
                if !store.result.adjustments.isEmpty {
                    DisclosureGroup("本次排程做了哪些调整") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(store.result.adjustments, id: \.self) { Text($0) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
                Text("截止日期保持不变。每张课程卡片只统计该课程，不重复累计其他课程的时间。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
        }.frame(maxHeight: .infinity)
    }

    private func courseCard(_ item: CourseScheduleAttention) -> some View {
        let tint = courseColor(item.course.color)
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(tint).frame(width: 4)
            VStack(alignment: .leading, spacing: 10) {
                Text(item.course.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("截止日期：\(studyDate(item.course.deadline))").font(.callout).foregroundStyle(.secondary)
                if item.course.autoScheduleEnabled {
                    Text("还需学习 \(studyDuration(item.remainingMinutes))，其中 \(studyDuration(item.plannedMinutes))已安排，\(studyDuration(item.unplacedMinutes))尚未安排。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.course.type == .lessonBasedRecorded
                         ? "这门课按整节安排。请先检查课节时长和顺序，并为整节课留出连续学习时段。"
                         : "请检查课程设置及截止日期前的可学习时段，必要时增加学习时间。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("剩余 \(studyDuration(item.remainingMinutes))尚未安排，因为这门课已暂停自动排程。恢复自动排程后再核对课表。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("查看课程与课节") { editCourse(item.course) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25)))
    }

    private func conflictCard(_ conflict: ScheduleConstraintConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("截至 \(studyDate(conflict.deadline))", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.red)
            if let rest = conflict.restConflict {
                Text("核对范围：\(studyDate(conflict.windowStart))起。\(rest.explanation)")
                Text(rest.recovery)
                Button("查看此日事项与空档") { reviewEvents(conflict.windowStart) }
            } else if let continuous = conflict.minimumContinuousMinutes {
                Text("有一块内容需要连续 \(studyDuration(continuous))，现有最长连续空档只有 \(studyDuration(conflict.availableMinutes))。")
            } else {
                Text("从 \(studyDate(conflict.windowStart))起需要 \(studyDuration(conflict.requiredMinutes))，即使暂不扣除浮动事项和课间休息，最多也只有 \(studyDuration(conflict.availableMinutes))，至少缺少 \(studyDuration(conflict.provenDeficit ?? 0))。")
            }
            Text("涉及课程：" + conflict.courseNames.joined(separator: "、")).font(.callout).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func dailyLoad(_ presentation: ScheduleHealthPresentation) -> some View {
        let days = showAllDays || presentation.heavyDays.isEmpty ? presentation.health.dayPlans : presentation.heavyDays
        return VStack(alignment: .leading, spacing: 12) {
            Text(presentation.loadSummary).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text("下表是已排进课表的学习时间，不含课间休息和未排入的内容。橙色表示超过提醒线，并不表示当天排不下。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("每日提醒线：\(studyDuration(presentation.warningMinutes))").font(.callout)
                Spacer()
                if !presentation.heavyDays.isEmpty {
                    Toggle("显示全部 \(presentation.health.dayPlans.count) 天", isOn: $showAllDays).toggleStyle(.checkbox)
                }
            }
            HStack {
                Text("日期").frame(maxWidth: .infinity, alignment: .leading)
                Text("已安排学习").frame(width: 160, alignment: .trailing)
                Text("与提醒线相比").frame(width: 170, alignment: .trailing)
            }.font(.callout.weight(.semibold)).padding(.horizontal, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(days) { day in
                        let excess = day.plannedMinutes - presentation.warningMinutes
                        HStack {
                            Text(studyDate(day.date)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(studyDuration(day.plannedMinutes)).monospacedDigit().frame(width: 160, alignment: .trailing)
                            Text(excess > 0 ? "超出 \(studyDuration(excess))" : "提醒线内")
                                .foregroundStyle(excess > 0 ? Color.orange : Color.secondary)
                                .frame(width: 170, alignment: .trailing)
                        }
                        .font(.callout).padding(12)
                        .background(excess > 0 ? Color.orange.opacity(0.07) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxHeight: .infinity)
            Text("调高提醒线只会减少提醒，不会增加可用时间；课间仍保留 \(ScheduleEngine.breakMinutes) 分钟休息。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func recovery(_ presentation: ScheduleHealthPresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(presentation.recoverySummary).fixedSize(horizontal: false, vertical: true)
            if presentation.health.reviewedMinutes > 0 {
                Text("今天确认过的任务：原计划 \(studyDuration(presentation.health.reviewedMinutes))，实际完成 \(studyDuration(presentation.health.creditedMinutes))。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(presentation.health.recovery) { day in
                        HStack {
                            Text(studyDate(day.date))
                            Spacer()
                            Text("补回 \(studyDuration(day.plannedMinutes))").monospacedDigit()
                        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.frame(maxWidth: .infinity)
            }.frame(maxHeight: .infinity)
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

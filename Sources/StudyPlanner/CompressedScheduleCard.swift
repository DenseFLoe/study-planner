import SwiftUI
import StudyCore

struct CompressedScheduleCard: View {
    @Bindable var controller: CompressedScheduleController
    @State private var expanded = false
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var month = Date()

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 18) {
                Text("按所有未完成课程计算，保留完整课节和课节顺序；固定课表、每日学习时段保持不变。此极限方案不预留额外课间休息，不受原开始日、截止日、每日加量和自动排程开关限制。")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.calculating {
                    Label("正在后台搜索最早完成方案，其他页面可以照常使用。", systemImage: "cpu")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let message = controller.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                } else if let plan = controller.plan {
                    if plan.courses.isEmpty {
                        Text("添加课程后，会自动计算极限压缩方案。")
                            .foregroundStyle(.secondary)
                    } else {
                        deadlines(plan)
                        if !plan.tasks.isEmpty { preview(plan) }
                    }
                }
                Text("独立方案预览 · 不修改当前日程 · 课程、进度、固定课表或学习时段变化后自动重新计算")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 16)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.title2).foregroundStyle(PlannerTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("极限压缩方案").font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.calculating { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("compressedScheduleCard")
        .padding(18)
        .plannerSurface(radius: 18, material: .thinMaterial, shadow: false)
        .onChange(of: controller.plan?.capturedAt) { _, value in
            if let value { selectedDay = Calendar.current.startOfDay(for: value); month = selectedDay }
        }
    }

    private var summary: String {
        if controller.calculating { return "正在后台计算 · 保留完整课节" }
        if controller.message != nil { return "暂时无法生成方案 · 展开查看原因" }
        if let finish = controller.plan?.finish { return "全部最早于 \(finish.formatted(date: .abbreviated, time: .shortened)) 完成" }
        return controller.plan?.courses.isEmpty == false ? "所有课程均已完成" : "等待课程数据"
    }

    private func deadlines(_ plan: CompressedSchedule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PlannerSectionTitle(title: "方案中的课程截止时间", detail: "\(plan.courses.count) 门 · 点击日期预览当天")
            ForEach(plan.courses) { item in
                Button {
                    if let finish = item.finish { selectedDay = Calendar.current.startOfDay(for: finish.addingTimeInterval(-1)); month = selectedDay }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "book.closed.fill")
                            .foregroundStyle(courseColor(item.course.color))
                            .frame(width: 36, height: 40)
                            .background(courseColor(item.course.color).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.course.name).font(.headline).foregroundStyle(.primary)
                            Text(item.remainingMinutes > 0 ? "剩余 \(hours(item.remainingMinutes))" : "已完成")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(item.finish?.formatted(date: .abbreviated, time: .shortened) ?? "已完成")
                                .font(.callout.weight(.semibold)).foregroundStyle(.primary)
                            if item.finish != nil && item.finish == plan.finish {
                                Text("最晚完成的课程").font(.caption2).foregroundStyle(PlannerTheme.accent)
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func preview(_ plan: CompressedSchedule) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PlannerSectionTitle(title: "方案日历与课表", detail: "计算基于 \(plan.capturedAt.formatted(date: .abbreviated, time: .shortened)) 的进度")
            MonthCalendar(selectedDay: $selectedDay, month: $month, tasks: plan.tasks,
                          fixed: calendarEvents(plan), select: {})
                .frame(maxWidth: 440)
            Text(selectedDay.formatted(.dateTime.year().month().day().weekday(.wide))).font(.headline)
            let rows = previewRows(plan)
            if rows.isEmpty {
                Text("当天没有方案安排。").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(row.start.formatted(date: .omitted, time: .shortened))–\(row.end.formatted(date: .omitted, time: .shortened))")
                            .font(.callout.monospacedDigit()).frame(width: 130, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2).fill(courseColor(row.color)).frame(width: 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.callout.weight(.semibold))
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private struct Row: Identifiable {
        var id: String
        var start: Date
        var end: Date
        var title: String
        var detail: String
        var color: String
    }
    private func calendarEvents(_ plan: CompressedSchedule) -> [FixedEvent] {
        plan.fixed.map { occurrence in
            var event = occurrence.event
            event.startDate = Calendar.current.startOfDay(for: occurrence.start)
            event.endDate = event.startDate
            event.weekdays = []; event.excludedDates = []
            return event
        }
    }
    private func previewRows(_ plan: CompressedSchedule) -> [Row] {
        let courses = Dictionary(uniqueKeysWithValues: plan.courses.map { ($0.id, $0.course) })
        let tasks = plan.tasks.filter { Calendar.current.isDate($0.start, inSameDayAs: selectedDay) }.map { task in
            let course = courses[task.courseID]
            return Row(id: task.id.uuidString, start: task.start, end: task.end,
                       title: task.lessonName ?? course?.name ?? "课程",
                       detail: "\(course?.name ?? "课程") · \(hours(task.durationMinutes)) · 完整学习块", color: course?.color ?? "blue")
        }
        let fixed = plan.fixed.filter { Calendar.current.isDate($0.start, inSameDayAs: selectedDay) }.map { occurrence in
            Row(id: occurrence.id, start: occurrence.start, end: occurrence.end, title: occurrence.event.title,
                detail: occurrence.event.isFloating ? "浮动固定事项 · 本方案预览位置" : "固定事项", color: occurrence.event.color)
        }
        return (tasks + fixed).sorted { $0.start < $1.start }
    }
}

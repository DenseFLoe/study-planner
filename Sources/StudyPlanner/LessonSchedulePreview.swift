import SwiftUI
import StudyCore

/// The same engine used for saved plans drives this review, including unscheduled lessons.
struct LessonSchedulePreview: View {
    let state: PlannerState
    let course: Course
    @State private var scheduled: [String: ScheduledTask] = [:]
    @State private var risks: [ScheduleRisk] = []
    @State private var calculated = false

    private var lessons: [LessonWorkItem] { state.lessonWorkItems(for: course) }
    private struct PreviewInput: Equatable {
        let state: PlannerState
        let course: Course
    }

    var body: some View {
        let items = lessons
        let pending = items.filter { $0.remainingMinutes > 0 }
        let missing = pending.filter { scheduled[$0.id] == nil }
        VStack(alignment: .leading, spacing: 8) {
            Text("每节按当前剩余时长安排；若没有足够长的连续空档，会显示为未排入。")
                .font(.caption).foregroundStyle(.secondary)
            if calculated {
                Text("已排入 \(pending.count - missing.count) / \(pending.count) 节 · 截止 \(course.deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption.weight(.medium))
                if !missing.isEmpty {
                    if course.isArchived {
                        Text("此课程已归档，当前不会自动排程。")
                    } else if !course.autoScheduleEnabled {
                        Text("此课程已暂停自动排程。")
                    } else if let risk = risks.first(where: { $0.courseNames.contains(course.name) }) {
                        Text(risk.capacityDeficit > 0
                             ? "截止日前可用时间不足，请调整学习时段或截止日。"
                             : "总时长可能够用，但连续空档不足；请调整时段或课节编排。")
                    }
                }
            } else {
                ProgressView("正在试排课节…").controlSize(.small)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, lesson in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                Text(lesson.name).font(.callout.weight(.medium)).lineLimit(2)
                            }
                            let location = [lesson.subject, lesson.stage, lesson.chapter].filter { !$0.isEmpty }.joined(separator: " / ")
                            if !location.isEmpty { Text(location).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                            HStack(spacing: 8) {
                                Text(lesson.remainingMinutes == 0 ? "已看完 · 共 \(hours(lesson.durationMinutes))" : "剩余 \(hours(lesson.remainingMinutes)) / 共 \(hours(lesson.durationMinutes))")
                                    .font(.caption)
                                Spacer(minLength: 4)
                                if lesson.remainingMinutes > 0 && calculated {
                                    Text(scheduled[lesson.id].map { $0.start.formatted(date: .abbreviated, time: .shortened) } ?? "未排入")
                                        .font(.caption2)
                                        .foregroundStyle(scheduled[lesson.id] == nil ? .orange : .secondary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        if index < items.count - 1 { Divider() }
                    }
                }
            }
            .frame(height: min(CGFloat(max(items.count, 1)) * 75, 290))
        }
        .task(id: PreviewInput(state: state, course: course)) {
            calculated = false
            let snapshot = state
            let selectedCourse = course
            let now = Date()
            let result = await Task.detached(priority: .userInitiated) {
                ScheduleEngine().generate(state: snapshot, now: now)
            }.value
            guard !Task.isCancelled else { return }
            scheduled = Dictionary(result.tasks.filter { $0.courseID == selectedCourse.id }.compactMap { task in
                task.lessonID.map { ($0, task) }
            }, uniquingKeysWith: { _, latest in latest })
            risks = result.risks
            calculated = true
        }
    }
}

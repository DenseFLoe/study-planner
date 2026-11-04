import SwiftUI
import StudyCore

/// The same engine used for saved plans drives this review, including unscheduled lessons.
struct LessonSchedulePreview: View {
    let state: PlannerState
    let course: Course
    @State private var summary: LessonSchedulePreviewSummary?

    private var lessons: [LessonWorkItem] { state.lessonWorkItems(for: course) }
    private struct PreviewInput: Equatable {
        let state: PlannerState
        let course: Course
    }

    var body: some View {
        LessonSchedulePreviewContent(items: lessons, course: course, summary: summary)
            .task(id: PreviewInput(state: state, course: course)) {
                summary = nil
                let snapshot = state
                let selectedCourse = course
                let now = Date()
                let result = await Task.detached(priority: .userInitiated) {
                    ScheduleEngine().generate(state: snapshot, now: now)
                }.value
                guard !Task.isCancelled else { return }
                summary = .init(lessons: snapshot.lessonWorkItems(for: selectedCourse),
                                course: selectedCourse, result: result)
            }
    }
}

/// Separate rendering from calculation so synthetic plans can verify the same UI.
struct LessonSchedulePreviewContent: View {
    let items: [LessonWorkItem]
    let course: Course
    let summary: LessonSchedulePreviewSummary?
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按每节剩余时长试排；分段安排会合计时长，并显示首段开始至末段结束的范围。")
                .font(.caption).foregroundStyle(.secondary)
            if let summary {
                Text(summary.countText)
                    .font(.caption.weight(.medium))
                Text("截止 \(course.deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = summary.warning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
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
                            Text(lesson.remainingMinutes == 0 ? "已看完 · 共 \(hours(lesson.durationMinutes))" : "剩余 \(hours(lesson.remainingMinutes)) / 共 \(hours(lesson.durationMinutes))")
                                .font(.caption)
                            if lesson.remainingMinutes > 0, let entry = summary?.entries[lesson.id] {
                                Text(entry.coverageText)
                                    .font(.caption)
                                    .foregroundStyle(entry.missingMinutes > 0 ? .orange : .secondary)
                                if let timing = entry.timingText(calendar: calendar, locale: locale) {
                                    Text(timing).font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        if index < items.count - 1 { Divider() }
                    }
                }
            }
            .frame(height: min(CGFloat(max(items.count, 1)) * 120, 290))
        }
    }
}

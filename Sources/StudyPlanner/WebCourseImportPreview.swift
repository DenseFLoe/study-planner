import SwiftUI
import StudyCore

/// Preparing an import preview is read-only and only runs while its disclosure is open.
struct WebCourseImportPreview: View {
    let state: PlannerState
    let snapshot: WebCourseSnapshot
    let deadline: Date
    @State private var prepared: Prepared?

    private struct Input: Equatable, Sendable {
        var state: PlannerState
        var snapshot: WebCourseSnapshot
        var deadline: Date
    }
    private enum Prepared: Sendable {
        case ready(PlannerState, Course)
        case unavailable(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch prepared {
            case .ready(let preview, let course):
                LessonSchedulePreview(state: preview, course: course)
            case .unavailable(let reason):
                Text("暂不能试排：\(reason)").font(.caption).foregroundStyle(.orange)
                Text("课程目录共 \(snapshot.lessons.count) 节，可滚动查看。")
                    .font(.caption2).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.lessons) { lesson in
                            Text("\(lesson.name) · \(lesson.durationSeconds.map(WebLessonTiming.clock) ?? "时长待定")")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: min(CGFloat(max(snapshot.lessons.count, 1)) * 36, 240))
            case nil:
                ProgressView("正在准备导入预览…").controlSize(.small)
            }
        }
        .task(id: Input(state: state, snapshot: snapshot, deadline: deadline)) {
            prepared = nil
            let input = Input(state: state, snapshot: snapshot, deadline: deadline)
            let now = Date()
            let value = await Task.detached(priority: .userInitiated) { Self.prepare(input, now: now) }.value
            guard !Task.isCancelled else { return }
            prepared = value
        }
    }

    nonisolated private static func prepare(_ input: Input, now: Date) -> Prepared {
        do {
            var preview = input.state
            try preview.importWebCourses([input.snapshot], deadline: input.deadline, now: now)
            guard let course = preview.courses.first(where: { $0.webCourse?.matchesIdentity(of: input.snapshot) == true }) else {
                return .unavailable("未能找到对应课程，请重新读取后核对。")
            }
            return .ready(preview, course)
        } catch { return .unavailable(error.localizedDescription) }
    }
}

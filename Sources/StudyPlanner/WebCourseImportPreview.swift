import SwiftUI
import StudyCore

/// Preparing an import preview is read-only and only runs while its disclosure is open.
struct WebCourseImportPreview: View {
    let state: PlannerState
    let snapshot: WebCourseSnapshot
    let deadline: Date
    @State private var prepared: Prepared?
    @State private var reviewOnly = false

    private struct Input: Equatable, Sendable {
        var state: PlannerState
        var snapshot: WebCourseSnapshot
        var deadline: Date
    }
    private enum Prepared: Sendable {
        case ready(PlannerState, Course)
        case unavailable(String, [WebCourseLessonReview])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch prepared {
            case .ready(let preview, let course):
                LessonSchedulePreview(state: preview, course: course)
            case .unavailable(let reason, let rows):
                let problemRows = rows.filter { $0.problem != nil }
                let shownRows = reviewOnly && !problemRows.isEmpty ? problemRows : rows
                Text("暂不能试排：\(reason)").font(.caption).foregroundStyle(.orange)
                Text("课程目录共 \(rows.count) 节 · \(problemRows.count) 节需核对")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("只看需核对的课节", isOn: Binding(get: { reviewOnly && !problemRows.isEmpty }, set: { reviewOnly = $0 }))
                    .toggleStyle(.checkbox).font(.caption).disabled(problemRows.isEmpty)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(shownRows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).font(.caption.weight(.medium))
                                if !row.location.isEmpty { Text(row.location).font(.caption2).foregroundStyle(.secondary) }
                                Text(row.details).font(.caption2).foregroundStyle(.secondary)
                                if let problem = row.problem { Text(problem).font(.caption2).foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: min(CGFloat(max(shownRows.count, 1)) * 100, 260))
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
                return .unavailable("未能找到对应课程，请重新读取后核对。", WebCourseLessonReview.rows(input.snapshot.lessons))
            }
            return .ready(preview, course)
        } catch { return .unavailable(error.localizedDescription, WebCourseLessonReview.rows(input.snapshot.lessons)) }
    }
}

import SwiftUI
import StudyCore

struct CourseMergeEditor: View {
    @Bindable var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var name = ""
    @State private var message = ""

    private var sources: [Course] {
        store.courses.sorted { NetdiskTitles.naturalCompare($0.name, $1.name) == .orderedAscending }
    }
    private var preview: Course? {
        var state = store.state
        return try? state.mergeCourses(ids: selected, name: name)
    }
    private var lessons: [LessonWorkItem] {
        var state = store.state
        guard let course = try? state.mergeCourses(ids: selected, name: name) else { return [] }
        return state.lessonWorkItems(for: course)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("合并已添加的课程").font(.title2.bold())
            TextField("合并后的课程名称", text: $name).textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading) {
                    Text("选择课程（已选 \(selected.count) 门）").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(sources) { course in
                                Toggle(isOn: Binding(get: { selected.contains(course.id) }, set: { value in
                                    if value { selected.insert(course.id) } else { selected.remove(course.id) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(course.name)
                                        Text(hours(course.totalMinutes)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(width: 270)
                Divider()
                VStack(alignment: .leading) {
                    Text("课节顺序预览 · 智能排序").font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                                Text("\(index + 1). \(lesson.name)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity)
            }
            if let preview {
                Text("合计 \(hours(preview.totalMinutes)) · 截止 \(preview.deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout)
            }
            Text("原课程将归档，进度与完成记录保留。采用最早的截止日期；未分课节的课程作为一节。合并后可在“调整课节顺序”中自定义，并在编辑课程中修改日期。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("合并并重新排程") {
                    if store.change({ state in _ = try state.mergeCourses(ids: selected, name: name) }) { dismiss() }
                    else { message = store.errorMessage ?? "合并失败" }
                }.buttonStyle(.borderedProminent).disabled(preview == nil)
            }
        }.padding(24).frame(width: 800, height: 590)
    }
}

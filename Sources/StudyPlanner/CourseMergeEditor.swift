import SwiftUI
import StudyCore

struct CourseMergeEditor: View {
    @Bindable var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var name = ""
    @State private var message = ""
    @State private var preview: CourseMergePreview?
    @State private var displayedInput: PreviewInput?
    @State private var previewError = ""
    @State private var saving = false

    private struct PreviewInput: Equatable, Sendable {
        let state: PlannerState
        let selected: Set<UUID>
        let name: String
        var canPreview: Bool { selected.count >= 2 && !name.isEmpty }
    }

    private var sources: [Course] {
        store.courses.sorted { NetdiskTitles.naturalCompare($0.name, $1.name) == .orderedAscending }
    }
    var body: some View {
        let input = PreviewInput(state: store.state, selected: selected,
                                 name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        let current = displayedInput == input ? preview : nil
        VStack(alignment: .leading, spacing: 16) {
            Text("合并已添加的课程").font(.title2.bold())
            TextField("合并后的课程名称", text: $name).textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading) {
                    Text("选择课程（已选 \(selected.count) 门）").font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
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
                    if !input.canPreview {
                        Text("填写合并名称并选择至少两门课程。").font(.caption).foregroundStyle(.secondary)
                    } else if displayedInput != input {
                        ProgressView("正在计算合并预览…").controlSize(.small)
                    } else if !previewError.isEmpty {
                        Text(previewError).font(.caption).foregroundStyle(.red)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array((current?.lessons ?? []).enumerated()), id: \.element.id) { index, lesson in
                                Text("\(index + 1). \(lesson.name)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity)
            }
            if let current {
                Text("合计 \(hours(current.course.totalMinutes)) · 截止 \(current.course.deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout)
            }
            Text("原课程将归档，进度与完成记录保留。采用最早的截止日期；未分课节的课程作为一节。合并后可在“调整课节顺序”中自定义，并在编辑课程中修改日期。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("合并并重新排程") {
                    guard let current else { return }
                    saving = true; message = ""
                    Task {
                        defer { saving = false }
                        if await store.mergeCourses(current.draft) { dismiss() }
                        else { message = store.errorMessage ?? "合并失败" }
                    }
                }.buttonStyle(.borderedProminent).disabled(current == nil)
            }
        }.padding(24).frame(width: 800, height: 590).disabled(saving)
            .task(id: input) {
                preview = nil; previewError = ""; displayedInput = nil
                guard input.canPreview else { displayedInput = input; return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                let result = await Task.detached(priority: .userInitiated) { () -> (CourseMergePreview?, String) in
                    do { return (try CourseMergePreview(state: input.state, selected: input.selected, name: input.name), "") }
                    catch { return (nil, error.localizedDescription) }
                }.value
                guard !Task.isCancelled else { return }
                preview = result.0; previewError = result.1; displayedInput = input
            }
    }
}

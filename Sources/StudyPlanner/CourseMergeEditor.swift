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
    @State private var query = ""
    @State private var selectedOnly = false
    @State private var matchedSources: [Course] = []
    @State private var displayedSourcesInput: SourcesInput?
    @State private var selectionNotice = ""

    private struct SourcesInput: Equatable, Sendable {
        let courses: [Course]
        let query: String
        let includedIDs: Set<UUID>?
    }

    private struct PreviewInput: Equatable, Sendable {
        let state: PlannerState
        let selected: Set<UUID>
        let name: String
        var canPreview: Bool { selected.count >= 2 && !name.isEmpty }
    }

    private var availableIDs: Set<UUID> {
        Set(store.state.courses.lazy.filter { !$0.isArchived }.map(\.id))
    }
    var body: some View {
        let input = PreviewInput(state: store.state, selected: selected,
                                 name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        let current = displayedInput == input ? preview : nil
        let sourcesInput = SourcesInput(courses: store.state.courses, query: query,
                                        includedIDs: selectedOnly ? selected : nil)
        let sources = displayedSourcesInput == sourcesInput ? matchedSources : []
        VStack(alignment: .leading, spacing: 16) {
            Text("合并已添加的课程").font(.title2.bold())
            TextField("合并后的课程名称", text: $name).textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading) {
                    Text("选择课程（已选 \(selected.count) 门）").font(.headline)
                    TextField("搜索名称、备注或截止日期", text: $query).textFieldStyle(.roundedBorder)
                    Toggle("只看已选课程", isOn: $selectedOnly).toggleStyle(.checkbox)
                    HStack {
                        Button("清除筛选") { query = ""; selectedOnly = false }
                        Button("取消全部选择") { selected.removeAll() }.disabled(selected.isEmpty)
                    }.controlSize(.small)
                    if displayedSourcesInput != sourcesInput {
                        ProgressView("正在筛选课程…").controlSize(.small)
                    } else {
                        Text(sources.isEmpty ? "当前筛选没有课程" : "匹配 \(sources.count) 门 · 按截止日期排列")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(sources) { course in
                                Toggle(isOn: Binding(get: { selected.contains(course.id) }, set: { value in
                                    if value { selected.insert(course.id) } else { selected.remove(course.id) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(course.name)
                                        Text("总量 \(hours(course.totalMinutes)) · 截止 \(course.deadline.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption).foregroundStyle(.secondary)
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
            Text("筛选不取消选择，合并全部已选课程；可用“只看已选课程”核对。")
                .font(.caption).foregroundStyle(.secondary)
            if !selectionNotice.isEmpty { Text(selectionNotice).font(.caption).foregroundStyle(.secondary) }
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
        }.padding(24).frame(width: 800, height: 650).disabled(saving)
            .onChange(of: availableIDs, initial: true) { _, latest in
                let removed = selected.subtracting(latest).count
                guard removed > 0 else { return }
                selected.formIntersection(latest)
                selectionNotice = "\(removed) 门课程已删除或归档，已取消选择；其他选择和合并名称仍保留。"
            }
            .task(id: sourcesInput) {
                displayedSourcesInput = nil
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                let result = await Task.detached(priority: .userInitiated) {
                    CourseCatalogSearch.matches(query: sourcesInput.query, courses: sourcesInput.courses,
                                                includedIDs: sourcesInput.includedIDs)
                }.value
                guard !Task.isCancelled else { return }
                matchedSources = result; displayedSourcesInput = sourcesInput
            }
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

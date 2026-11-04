import SwiftUI
import StudyCore

struct LessonOrderEditor: View {
    @Bindable var store: PlannerStore
    let course: Course
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LessonOrderDraft
    @State private var selected = Set<String>()
    @State private var destination = 1
    @State private var message = ""
    @State private var deletePrompt = false
    @State private var reloadPrompt = false

    init(store: PlannerStore, course: Course) {
        self.store = store
        self.course = course
        _draft = State(initialValue: LessonOrderDraft(course: course, state: store.state))
    }

    private var editedCourse: Course { previewState.courses.first { $0.id == course.id } ?? course }
    private var previewState: PlannerState { (try? draft.preview()) ?? store.state }
    private var lessons: [LessonWorkItem] { previewState.lessonWorkItems(for: editedCourse) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("调整课节顺序与删除").font(.title2.bold())
                    Text(draft.course.name).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 11) {
                    Text("选择要移动或删除的课节").font(.headline)
                    Text("可多选课节调整顺序或删除。删除会清除所选课节的安排和完成记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                                lessonRow(lesson, number: index + 1)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Divider()
                    HStack {
                        if let websiteOrder = draft.websiteOrder {
                            Button("按网站顺序") { draft.order = websiteOrder }
                        }
                        Button("智能排序") { draft.order = LessonOrdering.intelligent(lessons).map(\.id) }
                        Button("按名称排序") {
                            draft.order = lessons.sorted {
                                let comparison = NetdiskTitles.naturalCompare($0.name, $1.name)
                                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
                            }.map(\.id)
                        }
                    }
                    Text("智能排序：课程 → 阶段 → 章节 → 课节编号；支持中文序号和上、中、下。")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Text("已选 \(selected.count) 节")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("删除所选课节", role: .destructive) { deletePrompt = true }.disabled(selected.isEmpty)
                        Button("移到最前") { move(before: 0) }.disabled(selected.isEmpty)
                        Button("移到最后") { move(before: draft.order.count) }.disabled(selected.isEmpty)
                    }
                    HStack {
                        Text("插入到第")
                        TextField("序号", value: $destination, format: .number)
                            .frame(width: 55)
                            .textFieldStyle(.roundedBorder)
                        Text("位前")
                        Button("移动所选课节") { move(before: destination - 1) }
                            .disabled(selected.isEmpty || !(1...draft.order.count + 1).contains(destination))
                        Spacer()
                    }
                    Text("1 表示最前；\(draft.order.count + 1) 表示末尾。多选课节会按当前相对顺序一起移动。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    Text("重新编排预览").font(.headline)
                    LessonSchedulePreview(state: previewState, course: editedCourse)
                    Spacer(minLength: 0)
                }
                .frame(width: 330)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Text(draft.deleted.isEmpty ? "保存后会重新安排未确认任务。" : "待删除 \(draft.deleted.count) 节；保存后生效，并重新排程。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新载入最新课节") { reloadPrompt = true }
                    .disabled(store.orderSaveBusy)
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并重新排程") {
                    Task {
                        let saving = draft
                        if await store.saveLessonOrder(saving) { dismiss() }
                        else { message = store.errorMessage ?? "保存失败" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.hasChanges || store.orderSaveBusy)
            }
        }
        .confirmationDialog("删除所选的 \(selected.count) 节课？", isPresented: $deletePrompt, titleVisibility: .visible) {
            Button("删除所选课节", role: .destructive) {
                do {
                    try draft.removeLessons(selected)
                    selected.removeAll()
                    message = ""
                } catch { message = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存后将删除这些课节的全部安排和完成记录，重算总学习量，并保留其他课节。取消或关闭窗口不会保存删除。请至少保留一节。")
        }
        .confirmationDialog("重新载入最新课节并放弃当前草稿？", isPresented: $reloadPrompt, titleVisibility: .visible) {
            Button("放弃草稿并重新载入", role: .destructive) {
                guard let current = store.course(course.id), !current.isArchived else {
                    message = LessonOrderEditError.removed.localizedDescription
                    return
                }
                draft = LessonOrderDraft(course: current, state: store.state)
                selected.removeAll()
                destination = 1
                message = ""
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("将丢弃尚未保存的排序和待删除选择，使用最新课程重新开始。")
        }
        .disabled(store.orderSaveBusy)
        .padding(22)
        .frame(width: 940, height: 690)
        .onAppear { store.websiteUpdater.beginEditing(course.id) }
        .onDisappear { store.websiteUpdater.endEditing(course.id) }
    }

    private func lessonRow(_ lesson: LessonWorkItem, number: Int) -> some View {
        return Button {
            if selected.contains(lesson.id) { selected.remove(lesson.id) }
            else { selected.insert(lesson.id) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected.contains(lesson.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                Text("\(number).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.name).lineLimit(2)
                    if !lesson.subject.isEmpty {
                        Text(lesson.subject).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(lesson.remainingMinutes == 0 ? "已看完" : hours(lesson.remainingMinutes))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected.contains(lesson.id) ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func move(before index: Int) {
        draft.order = LessonOrdering.move(draft.order, selected: selected, before: index)
        destination = min(max(1, destination), draft.order.count + 1)
    }
}

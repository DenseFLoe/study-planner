import SwiftUI
import StudyCore

struct LessonOrderEditor: View {
    @Bindable var store: PlannerStore
    let course: Course
    @Environment(\.dismiss) private var dismiss
    @State private var order: [String]
    @State private var selected = Set<String>()
    @State private var destination = 1
    @State private var message = ""

    init(store: PlannerStore, course: Course) {
        self.store = store
        self.course = course
        _order = State(initialValue: store.state.lessonWorkItems(for: course).map(\.id))
    }

    private var originalOrder: [String] { store.state.lessonWorkItems(for: course).map(\.id) }
    private var websiteOrder: [String]? {
        guard let website = course.webCourse else { return nil }
        return LessonOrdering.resolved(ids: originalOrder, preferred: website.lessons.map(\.id))
    }
    private var editedCourse: Course {
        var copy = store.course(course.id) ?? course
        copy.lessonOrder = order
        return copy
    }
    private var previewState: PlannerState {
        var copy = store.state
        if let index = copy.courses.firstIndex(where: { $0.id == course.id }) { copy.courses[index] = editedCourse }
        return copy
    }
    private var lessons: [LessonWorkItem] { previewState.lessonWorkItems(for: editedCourse) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("调整课节学习顺序").font(.title2.bold())
                    Text(course.name).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 11) {
                    Text("选择要一起移动的课节").font(.headline)
                    Text("按左侧顺序学习。已看完和正在进行的课节保留原记录。")
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
                        if let websiteOrder {
                            Button("按网站顺序") { order = websiteOrder }
                        }
                        Button("智能排序") { order = LessonOrdering.intelligent(lessons).map(\.id) }
                        Button("按名称排序") {
                            order = lessons.sorted {
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
                        Button("移到最前") { move(before: 0) }.disabled(selected.isEmpty)
                        Button("移到最后") { move(before: order.count) }.disabled(selected.isEmpty)
                    }
                    HStack {
                        Text("插入到第")
                        TextField("序号", value: $destination, format: .number)
                            .frame(width: 55)
                            .textFieldStyle(.roundedBorder)
                        Text("位前")
                        Button("移动所选课节") { move(before: destination - 1) }
                            .disabled(selected.isEmpty || !(1...order.count + 1).contains(destination))
                        Spacer()
                    }
                    Text("1 表示最前；\(order.count + 1) 表示末尾。多选课节会按当前相对顺序一起移动。")
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
                Text("保存后会重新安排尚未开始的任务。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存顺序并重新排程") {
                    let updatedOrder = order
                    let followsWebsite = websiteOrder == updatedOrder
                    if store.change({ state in
                        guard let index = state.courses.firstIndex(where: { $0.id == course.id && !$0.isArchived }) else {
                            throw WebCourseImportError.invalid("课程已不存在，请重新打开。")
                        }
                        state.courses[index].lessonOrder = updatedOrder
                        state.courses[index].lessonOrderCustomized = !followsWebsite
                    }) { dismiss() }
                    else { message = store.errorMessage ?? "保存失败" }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(order == originalOrder)
            }
        }
        .padding(22)
        .frame(width: 940, height: 690)
    }

    private func lessonRow(_ lesson: LessonWorkItem, number: Int) -> some View {
        let movable = lesson.remainingMinutes > 0
        return Button {
            if selected.contains(lesson.id) { selected.remove(lesson.id) }
            else { selected.insert(lesson.id) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: movable ? (selected.contains(lesson.id) ? "checkmark.square.fill" : "square") : "lock.fill")
                    .foregroundStyle(movable ? Color.accentColor : .secondary)
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
        .disabled(!movable)
    }

    private func move(before index: Int) {
        order = LessonOrdering.move(order, selected: selected, before: index)
        destination = min(max(1, destination), order.count + 1)
    }
}

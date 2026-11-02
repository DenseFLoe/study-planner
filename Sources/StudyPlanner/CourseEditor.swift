import SwiftUI
import AppKit
import StudyCore

struct CourseEditor: View {
    @Bindable var store: PlannerStore
    @State var course: Course
    @Environment(\.dismiss) private var dismiss
    @State private var deletePrompt = false
    @State private var message = ""
    @State private var supervisedApplication: SupervisedApplication?
    @State private var page = CourseEditorPage.overview
    @State private var backHistory: [CourseEditorPage] = []
    @State private var forwardHistory: [CourseEditorPage] = []
    @State private var saving = false
    @State private var importSheet: CourseContentImport?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var existing: Bool { store.course(course.id) != nil }
    private var logged: Int { previewState.completions.filter { $0.courseID == course.id }.reduce(0) { $0 + $1.minutes } }
    private var isManualLessonCourse: Bool { course.type == .lessonBasedRecorded && course.webCourse == nil && course.mergedSources == nil }
    private func setManualLessons(_ lessons: [ManualLesson]) {
        course.manualLessons = lessons
        course.totalMinutes = lessons.reduce(0) { $0 + $1.durationMinutes }
    }
    private func updateManualLesson(_ id: String, _ edit: (inout ManualLesson) -> Void) {
        var lessons = course.manualLessons ?? []
        guard let index = lessons.firstIndex(where: { $0.id == id }) else { return }
        edit(&lessons[index])
        setManualLessons(lessons)
    }
    private var previewState: PlannerState {
        var state = store.state
        try? state.updateCourse(course)
        return state
    }
    private func removeManualLesson(_ id: String) {
        if store.course(course.id)?.manualLessons?.contains(where: { $0.id == id }) != true {
            setManualLessons((course.manualLessons ?? []).filter { $0.id != id })
            message = ""
            return
        }
        var state = previewState
        do {
            try state.removeLessons(courseID: course.id, ids: [id])
            if let updated = state.courses.first(where: { $0.id == course.id }) { course = updated }
            message = ""
        } catch { message = error.localizedDescription }
    }
    private var validation: String? {
        if course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写课程名称。" }
        if isManualLessonCourse {
            guard let lessons = course.manualLessons, !lessons.isEmpty,
                  lessons.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.durationMinutes > 0 && $0.durationMinutes <= 1440 }) else {
                return "请至少添加一节课，并填写名称及 1–1440 分钟的时长。"
            }
            if lessons.reduce(0, { $0 + $1.durationMinutes }) != course.totalMinutes { return "课节时长与总学习量不一致。" }
        }
        if course.totalMinutes <= 0 || course.totalMinutes > 600_000 { return "总时长须大于 0，且不超过 10,000 小时。" }
        do {
            var state = store.state
            try state.updateCourse(course)
        } catch { return error.localizedDescription }
        if course.initialCompletedMinutes < 0 || course.initialCompletedMinutes + logged > course.totalMinutes { return "已完成时长不能超过总学习时长。" }
        if Calendar.current.startOfDay(for: course.deadline) < Calendar.current.startOfDay(for: course.startDate) { return "截止日期不能早于开始日期。" }
        if course.deadline > Calendar.current.date(byAdding: .year, value: 10, to: Date())! { return "截止日期须在未来十年以内。" }
        if course.minimumBlockMinutes < 0 || course.minimumBlockMinutes > 1440 { return "最小时间块须为 1–1440 分钟，或设为 0 跟随全局设置。" }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            VStack(spacing: 0) {
                pageHeading
                ZStack {
                    // Keep editable forms alive across navigation, including incomplete field input.
                    ForEach(CourseEditorPage.editingPages) { destination in
                        Form { fields(for: destination) }
                            .formStyle(.grouped)
                            .opacity(page == destination ? 1 : 0)
                            .offset(x: pageOffset(for: destination))
                            .allowsHitTesting(page == destination)
                            .disabled(page != destination)
                            .accessibilityHidden(page != destination)
                    }
                    if page == .overview {
                        overview.transition(pageTransition(offset: -18))
                    } else if page == .review {
                        review.transition(pageTransition(offset: 18))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                // Animate only the content, keeping the navigation and footer steady.
                .animation(pageAnimation, value: page)
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: appeared)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 10)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear {
            supervisedApplication = store.playbackSupervisor.application(for: course.id)
            appeared = true
        }
        .sheet(item: $importSheet) { source in
            Group {
                switch source {
                case .website: WebCourseImportSheet(store: store)
                case .netdisk: NetdiskImportSheet(store: store)
                }
            }
            .disabled(store.orderSaveBusy)
            .interactiveDismissDisabled(store.orderSaveBusy)
        }
        .onChange(of: course.type) { _, newType in
            if newType == .lessonBasedRecorded && course.webCourse == nil && course.manualLessons == nil {
                setManualLessons([])
            } else if isManualLessonCourse {
                // Returning to a previously entered lesson list restores its derived total.
                setManualLessons(course.manualLessons ?? [])
            }
        }
        .confirmationDialog("删除这门课程？所有安排和完成记录都会删除，可从自动备份撤销。", isPresented: $deletePrompt) {
            Button("删除课程", role: .destructive) {
                Task {
                    saving = true
                    defer { saving = false }
                    if await store.deleteCourse(course) {
                        _ = store.playbackSupervisor.setApplication(nil, for: course.id)
                        dismiss()
                    } else { message = store.errorMessage ?? "删除失败" }
                }
            }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button { goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(backHistory.isEmpty)
                .help("返回上一页（⌘[）")
                .accessibilityLabel("返回上一页")
                .keyboardShortcut("[", modifiers: .command)
            Button { goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(forwardHistory.isEmpty)
                .help("前进（⌘]）")
                .accessibilityLabel("前进到下一页")
                .keyboardShortcut("]", modifiers: .command)
            Divider().frame(height: 18)
            Button("设置总览") { navigate(to: .overview) }
                .disabled(page == .overview)
            Spacer()
            Text(existing ? "编辑学习课程" : "添加学习课程")
                .font(.headline).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var pageHeading: some View {
        HStack(spacing: 14) {
            Image(systemName: page.icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(page == .overview ? (existing ? "调整这门课程" : "设置一门新课程") : page.title)
                    .font(.title2.bold())
                Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let step = page.step {
                Text("\(step) / 5").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)
    }

    private var overview: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed.fill")
                        .foregroundStyle(courseColor(course.color)).font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名课程" : course.name)
                            .font(.headline).lineLimit(2)
                        Text("\(course.type.rawValue) · \(hours(course.totalMinutes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("未保存").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            Section("点击任意一项开始") {
                ForEach(CourseEditorPage.editingPages) { destination in
                    settingsRow(destination, detail: summary(for: destination))
                }
            }
            Section {
                settingsRow(.review, detail: "核对全部设置，再保存课程")
            } footer: {
                Text("可以按顺序填写，也可以自由跳转。返回和前进都会保留本次输入；确认保存后才会生效。")
            }
        }.formStyle(.grouped)
    }

    private func settingsRow(_ destination: CourseEditorPage, detail: String) -> some View {
        Button { navigate(to: destination) } label: {
            HStack(spacing: 12) {
                Image(systemName: destination.icon)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(destination.tint.gradient, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(destination.title)
        .accessibilityValue(detail)
        .accessibilityHint("打开设置，保留当前输入")
    }

    private func summary(for destination: CourseEditorPage) -> String {
        switch destination {
        case .basics:
            course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "名称、类型、颜色与备注" : "\(course.name) · \(course.type.rawValue)"
        case .workload:
            isManualLessonCourse
                ? "\((course.manualLessons ?? []).count) 节课 · 共 \(hours(course.totalMinutes))"
                : "共 \(hours(course.totalMinutes)) · 基础已完成 \(hours(course.initialCompletedMinutes))"
        case .schedule:
            "\(course.startDate.formatted(date: .abbreviated, time: .omitted)) 至 \(course.deadline.formatted(date: .abbreviated, time: .omitted)) · \(course.autoScheduleEnabled ? "自动调度" : "暂停调度")"
        case .supervision:
            supervisedApplication?.name ?? "可选 · 暂不绑定观看软件"
        case .overview, .review:
            ""
        }
    }

    @ViewBuilder private func fields(for destination: CourseEditorPage) -> some View {
        switch destination {
        case .basics: basicFields
        case .workload: workloadFields
        case .schedule: scheduleFields
        case .supervision:
            Section("对应软件 · 可选") {
                CourseSupervisionPicker(selection: $supervisedApplication)
            }
            Section {
                Label("不需要监督时，直接继续即可。", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .overview, .review: EmptyView()
        }
    }

    @ViewBuilder private var basicFields: some View {
        Section("课程信息") {
            TextField("课程名称", text: $course.name)
            Picker("课程类型", selection: $course.type) { ForEach(CourseType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.disabled(course.mergedSources != nil)
            ColorPickerRow(selection: $course.color)
            TextField("备注", text: $course.notes, axis: .vertical).lineLimit(2...3)
        }
        Section {
            Text(isManualLessonCourse
                 ? "按课节安排：下一页逐节填写名称与时长，每节生成一项学习任务。"
                 : course.type == .lessonBasedRecorded
                    ? "按已导入的课节安排，每节生成一项学习任务。下一页可查看学习量与来源。"
                    : "按总时长安排：下一页填写总学习量，系统会按时间块分配学习任务。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var workloadFields: some View {
        Section("导入学习内容") {
            Button("从网站导入课程", systemImage: "globe") { openImport(.website) }
                .focusEffectDisabled()
            Button("从夸克网盘导入", systemImage: "externaldrive") { openImport(.netdisk) }
                .focusEffectDisabled()
            Text("导入窗口可单独添加或更新来源课程；关闭后会保留这里尚未保存的填写内容。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if isManualLessonCourse {
            Section("逐节录入") {
                ForEach(Array((course.manualLessons ?? []).enumerated()), id: \.element.id) { index, lesson in
                    HStack {
                        TextField("第 \(index + 1) 节名称", text: Binding(get: {
                            course.manualLessons?.first(where: { $0.id == lesson.id })?.name ?? ""
                        }, set: { value in updateManualLesson(lesson.id) { $0.name = value } }))
                        TextField("分钟", value: Binding(get: {
                            course.manualLessons?.first(where: { $0.id == lesson.id })?.durationMinutes ?? 60
                        }, set: { value in updateManualLesson(lesson.id) { $0.durationMinutes = value } }), format: .number)
                        .frame(width: 65)
                        Button(role: .destructive) {
                            removeManualLesson(lesson.id)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除第 \(index + 1) 节课")
                    }
                }
                Button("添加一节课", systemImage: "plus") {
                    var lessons = course.manualLessons ?? []
                    lessons.append(.init(name: "", durationMinutes: 60))
                    setManualLessons(lessons)
                }
                Text("每节课程会生成一项独立任务；总时长由课节相加。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("删除课节会在保存时清除其安排和完成记录；请至少保留一节。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("学习量") {
            if course.type == .lessonBasedRecorded {
                LabeledContent("总学习时长", value: hours(course.totalMinutes))
            } else { HoursField(title: "总学习时长（小时）", minutes: $course.totalMinutes) }
            if let netdisk = course.netdisk {
                Text("夸克网盘导入：\(netdisk.videoCount) 节 · \(netdisk.fetchedAt.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
                Text("来源：\(netdisk.shareTitle)\(netdisk.folderPath.isEmpty ? "" : " / " + netdisk.folderPath)")
                    .font(.caption2).foregroundStyle(.secondary)
                if let duplicates = netdisk.duplicates, !duplicates.isEmpty {
                    Text("查重：已去掉 \(duplicates.removedVideos) 个明确副本，\(duplicates.requiresReview.count) 项需核对")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else if let snapshot = course.webCourse {
                Text("网站导入：\(snapshot.lessons.count) 节 · \(snapshot.fetchedAt.formatted())").font(.caption).foregroundStyle(.secondary)
            }
            HoursField(title: "已完成基础量（小时）", minutes: $course.initialCompletedMinutes)
                .disabled(course.mergedSources != nil)
            if let sources = course.mergedSources {
                Text("合并来源：" + sources.map(\.name).joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if logged > 0 { LabeledContent("应用内已确认", value: hours(logged)) }
            Text("基础量用于导入已有进度；应用内确认的学习量会额外累计。").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var scheduleFields: some View {
        Section("排程规则") {
            DatePicker("开始日期", selection: $course.startDate, displayedComponents: .date)
            DatePicker("截止日期（含当天）", selection: $course.deadline, displayedComponents: .date)
            DailyStudyWeightPicker(weight: Binding(get: { course.dailyWeight }, set: { course.dailyStudyWeight = $0 }))
            Text("1.5 倍多学 50%，2 倍多学一倍，3 倍多学两倍；优先安排到前面的日期，受可用时间与完整课节限制。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("记录原始发布时间", isOn: Binding(get: { course.publishedDate != nil }, set: { course.publishedDate = $0 ? course.startDate : nil }))
            if course.publishedDate != nil { DatePicker("发布时间", selection: Binding(get: { course.publishedDate ?? Date() }, set: { course.publishedDate = $0 }), displayedComponents: .date) }
            Picker("优先级", selection: $course.priority) { Text("高").tag(3); Text("中").tag(2); Text("低").tag(1) }
            if course.type == .lessonBasedRecorded {
                Text("按每节课的剩余时长排程，一节对应一项任务；需要足够长的连续空档。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("最小时间块（分钟；0 跟随设置）", value: $course.minimumBlockMinutes, format: .number)
                Text("常用 30 或 60 分钟。最后不足一个时间块的余量，允许单独安排。").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("允许自动调度", isOn: $course.autoScheduleEnabled)
        }
    }

    private var review: some View {
        Form {
            Section("点击条目可返回修改") {
                ForEach(CourseEditorPage.editingPages) { destination in
                    settingsRow(destination, detail: summary(for: destination))
                }
            }
            Section {
                if let validation {
                    Label(validation, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("信息已齐全，可以保存。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(course.autoScheduleEnabled
                     ? "保存后，系统会按剩余学习量和截止日期更新学习安排。"
                     : "自动调度已关闭；课程会保存，暂不生成新的学习安排。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if validation == nil {
                if course.type == .lessonBasedRecorded && (course.mergedSources != nil || course.webCourse != nil || !(course.manualLessons ?? []).isEmpty) {
                    Section("课程编排预览") {
                        LessonSchedulePreview(state: previewState, course: course)
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if existing && page == .overview {
                Button("删除课程", role: .destructive) { deletePrompt = true }
            } else if page != .overview {
                Button("返回") { goBack() }.disabled(backHistory.isEmpty)
            }
            if saving { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            if page == .review {
                Button(existing ? "保存更改" : "添加课程") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil)
            } else {
                if page != .overview {
                    Button("检查设置") { navigate(to: .review) }
                }
                Button(page.continueTitle) { navigate(to: page.next) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func finishEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func openImport(_ source: CourseContentImport) {
        finishEditing()
        importSheet = source
    }

    private var pageAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: 0.24)
    }

    private func pageOffset(for destination: CourseEditorPage) -> CGFloat {
        guard !reduceMotion, page != destination else { return 0 }
        return destination.rawValue < page.rawValue ? -18 : 18
    }

    private func pageTransition(offset: CGFloat) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: offset))
    }

    private func navigate(to destination: CourseEditorPage) {
        guard page != destination else { return }
        finishEditing()
        backHistory.append(page)
        forwardHistory.removeAll()
        page = destination
    }

    private func goBack() {
        guard let destination = backHistory.popLast() else { return }
        finishEditing()
        forwardHistory.append(page)
        page = destination
    }

    private func goForward() {
        guard let destination = forwardHistory.popLast() else { return }
        finishEditing()
        backHistory.append(page)
        page = destination
    }

    private func save() {
        finishEditing()
        guard validation == nil, !saving else { return }
        saving = true
        message = ""
        Task {
            defer { saving = false }
            course.name = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if await store.saveCourse(course) {
                let supervisor = store.playbackSupervisor
                let previous = supervisor.application(for: course.id)
                if supervisor.setApplication(supervisedApplication, for: course.id) {
                    dismiss()
                    if let app = supervisedApplication, app != previous {
                        Task { await supervisor.authorize(app) }
                    }
                } else { message = supervisor.storageMessage ?? "软件绑定保存失败" }
            } else { message = store.errorMessage ?? "保存失败" }
        }
    }
}

private enum CourseContentImport: String, Identifiable {
    case website, netdisk
    var id: Self { self }
}

private enum CourseEditorPage: Int, Identifiable {
    case overview, basics, workload, schedule, supervision, review

    static let editingPages: [Self] = [.basics, .workload, .schedule, .supervision]
    var id: Self { self }
    var step: Int? { self == .overview ? nil : rawValue }
    var next: Self { Self(rawValue: rawValue + 1) ?? .review }
    var continueTitle: String {
        switch self {
        case .overview: "开始设置"
        case .supervision: "核对并保存"
        default: "继续"
        }
    }
    var title: String {
        switch self {
        case .overview: "设置总览"
        case .basics: "课程信息"
        case .workload: "学习内容"
        case .schedule: "排程规则"
        case .supervision: "学习监督"
        case .review: "确认课程"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: "分项设置，随时返回修改。"
        case .basics: "先给课程一个名字，选择适合的学习方式。"
        case .workload: "填写需要学习的内容，以及已经完成的进度。"
        case .schedule: "设定学习日期和节奏，交给系统安排。"
        case .supervision: "选择上课使用的软件，在学习时段提醒你。"
        case .review: "最后核对一次，任何一项都可以继续修改。"
        }
    }
    var icon: String {
        switch self {
        case .overview: "book.closed"
        case .basics: "text.book.closed"
        case .workload: "list.bullet.rectangle"
        case .schedule: "calendar"
        case .supervision: "play.rectangle"
        case .review: "checkmark.circle"
        }
    }
    var tint: Color {
        switch self {
        case .overview, .basics: .blue
        case .workload: .orange
        case .schedule: .red
        case .supervision: .purple
        case .review: .teal
        }
    }
}

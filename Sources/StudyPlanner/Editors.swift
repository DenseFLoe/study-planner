import SwiftUI
import StudyCore
import StudySync

struct CourseEditor: View {
    @Bindable var store: PlannerStore
    @State var course: Course
    @Environment(\.dismiss) private var dismiss
    @State private var deletePrompt = false
    @State private var message = ""
    private var existing: Bool { store.course(course.id) != nil }
    private var logged: Int { store.state.completions.filter { $0.courseID == course.id }.reduce(0) { $0 + $1.minutes } }
    private var validation: String? {
        if course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写课程名称。" }
        if course.totalMinutes <= 0 || course.totalMinutes > 600_000 { return "总时长须大于 0，且不超过 10,000 小时。" }
        if course.initialCompletedMinutes < 0 || course.initialCompletedMinutes + logged > course.totalMinutes { return "已完成时长不能超过总学习时长。" }
        if Calendar.current.startOfDay(for: course.deadline) < Calendar.current.startOfDay(for: course.startDate) { return "截止日期不能早于开始日期。" }
        if course.deadline > Calendar.current.date(byAdding: .year, value: 10, to: Date())! { return "截止日期须在未来十年以内。" }
        if course.minimumBlockMinutes < 0 || course.minimumBlockMinutes > 1440 { return "最小时间块须为 1–1440 分钟，或设为 0 跟随全局设置。" }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: existing ? "编辑学习课程" : "添加学习课程", subtitle: "按剩余学习量和截止日期，自动分配到空闲时间。")
            Form {
                Section("课程信息") {
                    TextField("课程名称", text: $course.name)
                    Picker("课程类型", selection: $course.type) { ForEach(CourseType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    ColorPickerRow(selection: $course.color)
                    TextField("备注", text: $course.notes, axis: .vertical).lineLimit(2...3)
                }
                Section("学习量") {
                    HoursField(title: "总学习时长（小时）", minutes: $course.totalMinutes)
                    HoursField(title: "已完成基础量（小时）", minutes: $course.initialCompletedMinutes)
                    if logged > 0 { LabeledContent("应用内已确认", value: hours(logged)) }
                    Text("基础量用于导入已有进度；应用内确认的学习量会额外累计。").font(.caption).foregroundStyle(.secondary)
                }
                Section("排程规则") {
                    DatePicker("开始日期", selection: $course.startDate, displayedComponents: .date)
                    DatePicker("截止日期（含当天）", selection: $course.deadline, displayedComponents: .date)
                    Toggle("记录原始发布时间", isOn: Binding(get: { course.publishedDate != nil }, set: { course.publishedDate = $0 ? course.startDate : nil }))
                    if course.publishedDate != nil { DatePicker("发布时间", selection: Binding(get: { course.publishedDate ?? Date() }, set: { course.publishedDate = $0 }), displayedComponents: .date) }
                    Picker("优先级", selection: $course.priority) { Text("高").tag(3); Text("中").tag(2); Text("低").tag(1) }
                    TextField("最小时间块（分钟；0 跟随设置）", value: $course.minimumBlockMinutes, format: .number)
                    Text("常用 30 或 60 分钟。最后不足一个时间块的余量，允许单独安排。").font(.caption).foregroundStyle(.secondary)
                    Toggle("允许自动调度", isOn: $course.autoScheduleEnabled)
                }
            }.formStyle(.grouped)
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            HStack {
                if existing { Button("删除课程", role: .destructive) { deletePrompt = true } }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并重新排程") {
                    course.name = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if store.saveCourse(course) { dismiss() } else { message = store.errorMessage ?? "保存失败" }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }.padding(20)
        }.frame(width: 570, height: 740)
        .confirmationDialog("删除这门课程？未来安排会移除，历史学习记录会保留。", isPresented: $deletePrompt) {
            Button("删除课程", role: .destructive) { store.deleteCourse(course); dismiss() }
        }
    }
}
struct FixedEventEditor: View {
    @Bindable var store: PlannerStore
    @State var event: FixedEvent
    @Environment(\.dismiss) private var dismiss
    @State private var deletePrompt = false
    @State private var conflictPrompt = false
    @State private var semesterWeeks = 16
    @State private var message = ""
    private var existing: Bool { store.state.fixedEvents.contains { $0.id == event.id } }
    private var conflicts: [FixedEventConflict] { store.pendingEventConflicts ?? [] }
    private var conflictSummary: String {
        let grouped = Dictionary(grouping: conflicts, by: \.title)
        let lines = grouped.keys.sorted().map { title in
            let allDates = (grouped[title] ?? []).map { $0.date.formatted(date: .abbreviated, time: .omitted) }
            let dates = allDates.prefix(12).joined(separator: "、")
            let suffix = allDates.count > 12 ? "等 \(allDates.count) 天" : ""
            return "「\(title)」：\(dates)\(suffix)"
        }
        return lines.joined(separator: "\n")
    }
    private var validation: String? {
        if event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写事项名称。" }
        if event.endMinute <= event.startMinute { return "结束时间必须晚于开始时间；跨午夜事项请分成两条。" }
        if !event.weekdays.isEmpty && Calendar.current.startOfDay(for: event.endDate) < Calendar.current.startOfDay(for: event.startDate) { return "结束日期不能早于开始日期。" }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: existing ? "编辑固定事项" : "添加固定事项", subtitle: "固定课程、补习班、考试、吃饭等不能移动的安排。")
            Form {
                Section("事项信息") {
                    TextField("名称", text: $event.title)
                    TimeField(title: "开始时间", minute: $event.startMinute)
                    TimeField(title: "结束时间", minute: $event.endMinute)
                    ColorPickerRow(selection: $event.color)
                    TextField("备注", text: $event.notes, axis: .vertical).lineLimit(2...3)
                }
                Section("重复规则") {
                    Toggle("每周重复", isOn: Binding(get: { !event.weekdays.isEmpty }, set: { event.weekdays = $0 ? [Calendar.current.component(.weekday, from: event.startDate)] : [] }))
                    if !event.weekdays.isEmpty {
                        HStack {
                            ForEach([2,3,4,5,6,7,1], id: \.self) { day in
                                Toggle(weekdayNames[day]!, isOn: Binding(get: { event.weekdays.contains(day) }, set: { if $0 { event.weekdays.insert(day) } else if event.weekdays.count > 1 { event.weekdays.remove(day) } }))
                                    .toggleStyle(.button)
                            }
                        }
                    }
                    DatePicker(event.weekdays.isEmpty ? "事项日期" : "开始日期 / 第一周起点", selection: $event.startDate, displayedComponents: .date)
                    if !event.weekdays.isEmpty {
                        DatePicker("结束日期（含当天）", selection: $event.endDate, displayedComponents: .date)
                        HStack {
                            Stepper("持续 \(semesterWeeks) 周", value: $semesterWeeks, in: 1...52)
                            Button("按周数设置结束日期") { event.endDate = Calendar.current.date(byAdding: .day, value: semesterWeeks * 7 - 1, to: event.startDate)! }
                        }
                        Text("例如第 1–16 周：选择第一周起点，再设置持续 16 周。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if existing { Text("已过去的课表会保留，修改仅应用于尚未开始的日期。").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                if existing { Button("删除事项", role: .destructive) { deletePrompt = true } }
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并重新排程") {
                    if event.weekdays.isEmpty { event.endDate = event.startDate }
                    if store.saveEvent(event) { dismiss() }
                    else if !conflicts.isEmpty && !event.weekdays.isEmpty { conflictPrompt = true }
                    else if !conflicts.isEmpty { message = PlannerError.fixedConflict(conflicts).localizedDescription }
                    else { message = store.errorMessage ?? "保存失败" }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }.padding(20)
        }.frame(width: 600, height: 640)
        .confirmationDialog("移除未来的固定事项？过去的课表会保留。", isPresented: $deletePrompt) {
            Button("移除事项", role: .destructive) { store.deleteEvent(event); dismiss() }
        }
        .confirmationDialog("长期事项存在日期冲突", isPresented: $conflictPrompt, titleVisibility: .visible) {
            Button("跳过冲突日期并保存") {
                let dates = Set(conflicts.map(\.date))
                if store.saveEvent(event, skippingDates: dates) { dismiss() }
                else { message = store.errorMessage ?? "保存失败" }
            }
            Button("返回修改", role: .cancel) { store.pendingEventConflicts = nil }
        } message: {
            Text("以下日期与已有固定事项冲突：\n\(conflictSummary)\n\n是否让长期事项跳过这些日期？")
        }
        .onDisappear { store.pendingEventConflicts = nil }
    }
}
struct SettingsView: View {
    @Bindable var store: PlannerStore
    @State private var settings = AppSettings()
    @State private var saved = false
    @State private var syncHost = ""
    @State private var pairingText = ""
    private var valid: Bool {
        (1...1440).contains(settings.minimumScheduleUnit) && settings.availability.allSatisfy { $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.startMinute < $0.endMinute }
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("每日可学习时间") {
                    Text("可以为每天添加多段时间。不启用的日期不会分配学习任务。").font(.callout).foregroundStyle(.secondary)
                    ForEach([2,3,4,5,6,7,1], id: \.self) { day in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(weekdayNames[day]!).fontWeight(.semibold)
                                Spacer()
                                if !settings.availability.contains(where: { $0.weekday == day }) { Text("休息日").foregroundStyle(.secondary) }
                                Button("添加时段", systemImage: "plus") { settings.availability.append(.init(weekday: day, startMinute: 480, endMinute: 1380)); saved = false }
                            }
                            ForEach($settings.availability) { $window in
                                if window.weekday == day {
                                    HStack {
                                        TimeField(title: "从", minute: $window.startMinute)
                                        TimeField(title: "至", minute: $window.endMinute)
                                        Button(role: .destructive) { settings.availability.removeAll { $0.id == window.id }; saved = false } label: { Image(systemName: "minus.circle") }.help("移除此时段")
                                    }
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                }
                Section("默认规则") {
                    TextField("默认最小时间块（分钟）", value: $settings.minimumScheduleUnit, format: .number)
                    TimeField(title: "每日完成确认时间", minute: $settings.notificationMinute)
                    Text("软件打开时，在此时间之后提示确认当天已结束的任务；下次启动也会补查未确认的历史任务。").font(.caption).foregroundStyle(.secondary)
                }
                Section("热点局域网同步") {
                    Text(store.syncStatus).textSelection(.enabled)
                    Text("今日自动同步：" + (store.syncLedger.lastAutoDate == SyncLedger.day(Date()) ? "已完成" : "尚未完成"))
                    if store.syncLedger.lastSuccess > 0 {
                        Text("最后同步：" + Date(timeIntervalSince1970: store.syncLedger.lastSuccess).formatted())
                    }
                    Text("先在 Android 开启接收窗口，再同步。自动同步在启动或回到前台时检查；完成后当天不再自动联网。").font(.caption).foregroundStyle(.secondary)
                    TextField("手机热点 IP", text: $syncHost)
                    Button("读取当前网关") { Task { syncHost = await SyncClient.gateway() ?? "" } }
                    SecureField("首次配对信息（配对码.证书指纹）", text: $pairingText)
                    HStack {
                        Button("配对并同步") { store.startSync(host: syncHost, pairingText: pairingText) }.disabled(store.syncBusy || pairingText.isEmpty)
                        Button(store.syncBusy ? "立即同步（排队）" : "立即同步") { store.startSync() }
                    }
                    DisclosureGroup("本次运行同步日志") {
                        Text(store.syncLog.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section("数据保存") {
                    Label("所有数据使用 SwiftData 保存在本机", systemImage: "internaldrive")
                    Text("使用独立日历，不连接系统 Calendar。同步只经过手机热点，无云服务、无账号。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                if !valid { Text("请检查各时段的起止时间和最小时间块。").foregroundStyle(.orange) }
                if saved { Label("已保存，未来计划已更新", systemImage: "checkmark.circle.fill").foregroundStyle(.teal) }
                Spacer()
                Button("恢复已保存设置") { settings = store.state.settings; saved = false }
                Button("保存并重新排程") { saved = store.change { $0.settings = settings } }.buttonStyle(.borderedProminent).disabled(!valid)
            }.padding(20)
        }.onAppear { settings = store.state.settings; syncHost = (try? PairingVault.load())?.host ?? "" }
        .onChange(of: settings) { _, _ in saved = false }
        .onChange(of: store.syncLedger.lastSuccess) { _, _ in pairingText = "" }
    }
}
struct CompletionEditor: View {
    @Bindable var store: PlannerStore
    let task: ScheduledTask
    @State private var actual = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(task.start > Date() ? "提前完成学习" : "确认学习完成情况").font(.title2.bold())
            Text(store.course(task.courseID)?.name ?? "课程").font(.headline)
            Text("\(task.start.formatted(date: .abbreviated, time: .shortened)) · 计划 \(hours(task.durationMinutes))").foregroundStyle(.secondary)
            CompletionInput(actual: $actual, planned: task.durationMinutes)
            Text("只有实际完成的学习量会计入进度；其余部分会自动重新分配。").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认并重新排程") { if store.confirm(task, minutes: actual) { dismiss() } }.buttonStyle(.borderedProminent).disabled(actual < 0 || actual > task.durationMinutes)
            }
        }.padding(28).frame(width: 500).onAppear { actual = task.durationMinutes }
    }
}
struct DailyReviewView: View {
    @Bindable var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [ScheduledTask] = []
    @State private var values: [UUID: Int] = [:]
    @State private var reviewed: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "确认学习完成情况", subtitle: "请逐项选择实际完成量，包含昨天及更早的未确认计划。")
            if tasks.isEmpty { ContentUnavailableView("没有待确认的任务", systemImage: "checkmark.circle", description: Text("所有历史计划均已确认。")) }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(tasks) { task in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(store.course(task.courseID)?.name ?? "课程").font(.headline); Spacer(); Text(task.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                            CompletionInput(actual: Binding(get: { values[task.id] ?? 0 }, set: { values[task.id] = $0; reviewed.insert(task.id) }), planned: task.durationMinutes)
                            if !reviewed.contains(task.id) { Text("尚未选择完成情况").font(.caption).foregroundStyle(.orange) }
                        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.horizontal, 24)
            }
            HStack {
                Button("全部标记完成") { for task in tasks { values[task.id] = task.durationMinutes; reviewed.insert(task.id) } }
                Button("全部未完成") { for task in tasks { values[task.id] = 0; reviewed.insert(task.id) } }
                Spacer()
                Button("稍后确认") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并重新排程") {
                    let needsReplan = tasks.contains { values[$0.id] != $0.durationMinutes }
                    let success = store.change(replan: needsReplan) { state in
                        for task in tasks { try state.confirm(taskID: task.id, actualMinutes: values[task.id] ?? 0, now: Date()) }
                    }
                    if success { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(tasks.isEmpty || reviewed.count != tasks.count || tasks.contains { !(0...$0.durationMinutes).contains(values[$0.id] ?? -1) })
            }.padding(24)
        }.frame(width: 740, height: 620)
        .onAppear { tasks = store.reviewTasks }
    }
}
struct CompletionInput: View {
    @Binding var actual: Int
    var planned: Int
    var body: some View {
        HStack {
            Button("完成 \(hours(planned))") { actual = planned }
            Button("未完成") { actual = 0 }
            Spacer()
            Text("实际")
            TextField("分钟", value: $actual, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
            Text("/ \(planned) 分钟").foregroundStyle(.secondary)
        }
    }
}
struct RiskView: View {
    @Bindable var store: PlannerStore
    var adjustSettings: () -> Void
    var editCourse: (Course) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("排程需要调整", systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(.orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.result.diagnostics, id: \.self) { Text($0).foregroundStyle(.orange) }
                    ForEach(store.result.risks) { risk in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("截止 \(risk.deadline.formatted(date: .abbreviated, time: .omitted))").font(.headline)
                            Text(risk.capacityDeficit > 0 ? "按照当前可用时间，无法按期完成这些课程。" : "当前时间块安排仍有学习量未排入，请调整时段或最小时间块。")
                            LabeledContent("此日期前剩余学习量", value: hours(risk.requiredMinutes))
                            LabeledContent("此日期前空闲时间", value: hours(risk.availableMinutes))
                            LabeledContent("尚未排入的学习量", value: hours(risk.unscheduledMinutes)).foregroundStyle(.orange)
                            if risk.capacityDeficit > 0 { LabeledContent("可用时间缺口", value: hours(risk.capacityDeficit)).foregroundStyle(.orange) }
                            Text("涉及：" + risk.courseNames.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text("可延长截止日期、增加可学习时间或缩小最小时间块。降低优先级只会改变分配顺序，不能补足时间缺口。").font(.callout).foregroundStyle(.secondary)
                    ForEach(store.courses.filter { course in store.result.risks.contains { $0.courseNames.contains(course.name) } }) { course in
                        Button("调整「\(course.name)」截止日期 / 时间块") { editCourse(course) }
                    }
                }
            }
            HStack { Button("调整可学习时间") { adjustSettings() }; Spacer(); Button("知道了") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 610, height: 600)
    }
}
struct SheetHeading: View {
    var title: String; var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.title2.bold()); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }
}
struct HoursField: View {
    var title: String
    @Binding var minutes: Int
    var body: some View {
        TextField(title, value: Binding(get: { Double(minutes) / 60 }, set: { minutes = $0.isFinite ? Int((min(100_001, max(-1, $0)) * 60).rounded()) : 0 }), format: .number.precision(.fractionLength(0...2)))
    }
}
struct TimeField: View {
    var title: String
    @Binding var minute: Int
    var body: some View {
        DatePicker(title, selection: Binding(get: { Calendar.current.date(bySettingHour: min(23, minute / 60), minute: minute % 60, second: 0, of: Date())! }, set: { minute = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }), displayedComponents: .hourAndMinute)
    }
}
struct ColorPickerRow: View {
    @Binding var selection: String
    var body: some View {
        Picker("颜色", selection: $selection) {
            Text("蓝色").tag("blue"); Text("青色").tag("green"); Text("紫色").tag("purple"); Text("橙色").tag("orange"); Text("粉色").tag("pink")
        }
    }
}

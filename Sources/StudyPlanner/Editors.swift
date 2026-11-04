import SwiftUI
import StudyCore
import StudySync

struct FixedEventEditor: View {
    @Bindable var store: PlannerStore
    @State var event: FixedEvent
    @State private var baseline: FixedEvent?
    @Environment(\.dismiss) private var dismiss
    @State private var deletePrompt = false
    @State private var conflictPrompt = false
    @State private var semesterWeeks = 16
    @State private var message = ""
    @State private var saving = false
    @State private var reloadPrompt = false
    @State private var formRevision = UUID()
    init(store: PlannerStore, event: FixedEvent) {
        self.store = store
        _event = State(initialValue: event)
        _baseline = State(initialValue: store.state.fixedEvents.contains { $0.id == event.id } ? event : nil)
    }
    private var existing: Bool { baseline != nil }
    private var conflicts: [FixedEventConflict] { store.pendingEventConflicts ?? [] }
    private var validation: String? {
        if event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写事项名称。" }
        if event.endDate > Calendar.current.date(byAdding: .year, value: 10, to: Date())! { return "事项结束日期须在未来十年以内。" }
        if !event.validDuration { return "占用时长须大于 0 且不能超过整个时段。" }
        if event.endMinute <= event.startMinute { return "结束时间必须晚于开始时间；跨午夜事项请分成两条。" }
        if !event.weekdays.isEmpty && Calendar.current.startOfDay(for: event.endDate) < Calendar.current.startOfDay(for: event.startDate) { return "结束日期不能早于开始日期。" }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: existing ? "编辑固定事项" : "添加固定事项", subtitle: "可固定具体时间，也可在指定时段内保留固定时长。")
            Form {
                Section("事项信息") {
                    TextField("名称", text: $event.title)
                    Picker("时间方式", selection: Binding(get: { event.isFloating }, set: { event.floatingDurationMinutes = $0 ? min(60, max(1, event.endMinute - event.startMinute)) : nil })) {
                        Text("固定时间").tag(false)
                        Text("时段内浮动").tag(true)
                    }.pickerStyle(.segmented)
                    TimeField(title: event.isFloating ? "时段开始" : "开始时间", minute: $event.startMinute)
                    TimeField(title: event.isFloating ? "时段结束" : "结束时间", minute: $event.endMinute)
                    if event.isFloating {
                        TextField("固定占用（分钟）", value: Binding(get: { event.floatingDurationMinutes ?? 60 }, set: { event.floatingDurationMinutes = $0 }), format: .number)
                        FloatingWindowIndicator(occupied: event.occupiedMinutes, window: event.endMinute - event.startMinute, tint: courseColor(event.color))
                        Text("只扣除占用时长；同一时段的学习安排也会标记为浮动，具体先后可调整。").font(.caption).foregroundStyle(.secondary)
                    }
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
            }.formStyle(.grouped).id(formRevision)
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            if existing {
                HStack {
                    Button("载入已保存内容") { reloadPrompt = true }
                    Text("用于放弃当前草稿，或在同步冲突后重新编辑。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 20)
            }
            HStack {
                if existing { Button("删除事项", role: .destructive) { deletePrompt = true } }
                if saving { ProgressView().controlSize(.small); Text("正在保存…").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并重新排程") {
                    guard !saving, !store.orderSaveBusy else { return }
                    if event.weekdays.isEmpty { event.endDate = event.startDate }
                    let submitted = event, reviewed = baseline
                    saving = true; message = ""
                    Task {
                        defer { saving = false }
                        if await store.saveEvent(submitted, from: reviewed) { dismiss() }
                        else if !conflicts.isEmpty { message = ""; conflictPrompt = true }
                        else { message = store.errorMessage ?? "保存失败" }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validation != nil || store.orderSaveBusy)
            }.padding(20)
        }.frame(width: 600, height: 740)
        .disabled(saving || store.orderSaveBusy)
        .interactiveDismissDisabled(saving)
        .alert("载入已保存的固定事项？", isPresented: $reloadPrompt) {
            Button("取消", role: .cancel) {}
            Button("放弃草稿并载入", role: .destructive) {
                guard !saving, !store.orderSaveBusy, let baseline else { return }
                guard let latest = store.state.fixedEvents.first(where: { $0.id == baseline.id }) else {
                    message = "此事项已被删除，当前草稿仍保留。请关闭窗口核对最新日程。"
                    return
                }
                event = latest; self.baseline = latest; message = ""
                semesterWeeks = 16; formRevision = UUID(); store.pendingEventConflicts = nil
            }
        } message: {
            Text("将替换本窗口的未保存输入，不修改已保存日程。需要保留的文字请先复制。")
        }
        .confirmationDialog("删除「\(baseline?.title ?? event.title)」？", isPresented: $deletePrompt, titleVisibility: .visible) {
            Button("删除事项", role: .destructive) {
                guard let baseline, !saving, !store.orderSaveBusy else { return }
                saving = true; message = ""
                Task {
                    defer { saving = false }
                    if await store.deleteEvent(baseline) { dismiss() }
                    else { message = store.errorMessage ?? "删除未保存" }
                }
            }
        } message: {
            Text("将移除这条事项的全部过去和未来课表，并重新排程。")
        }
        .sheet(isPresented: $conflictPrompt) {
            EventConflictReview(store: store, event: event, baseline: baseline, onSaved: { dismiss() }, conflicts: conflicts)
        }
        .onDisappear { store.pendingEventConflicts = nil }
    }
}
struct SettingsView: View {
    @Bindable var store: PlannerStore
    @Bindable private var draft: SettingsDraft

    init(store: PlannerStore) {
        self.store = store
        self.draft = store.settingsDraft
    }
    @State private var selectedCategory: SettingsCategory?
    @State private var syncHost = ""
    @State private var pairingRequest: PairingRequest?
    @AppStorage("dailyStudyLoadWarningMinutes") private var dailyLoadWarningMinutes = 480
    @AppStorage("timelineTimeFontSize") private var timelineTimeFontSize = 17.0
    /// Display-only preference: it never travels through `AppSettings`, so
    /// adjusting it neither saves business settings nor triggers rescheduling.
    private var displayTimelineTimeFontSize: Double {
        guard timelineTimeFontSize.isFinite else { return 17 }
        return min(max(timelineTimeFontSize, 14), 24)
    }
    private var valid: Bool {
        draft.settings.hasValidEditableSettings
    }
    var body: some View {
        VStack(spacing: 0) {
            if let selectedCategory {
                HStack(spacing: 12) {
                    Button { self.selectedCategory = nil } label: {
                        Label("全部设置", systemImage: "chevron.left")
                    }
                    Text(selectedCategory.rawValue).font(.title3.bold())
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 14)
                Divider()
            }
            ZStack(alignment: .topLeading) {
                categoryGrid
                    .opacity(selectedCategory == nil ? 1 : 0)
                    .allowsHitTesting(selectedCategory == nil)
                    .disabled(selectedCategory != nil)
                    .accessibilityHidden(selectedCategory != nil)
                // Keep the forms mounted so navigating between cards retains drafts,
                // including the cloud form's in-memory credential fields.
                ForEach(SettingsCategory.allCases) { category in
                    Form { categoryContent(category) }
                        .formStyle(.grouped)
                        .opacity(selectedCategory == category ? 1 : 0)
                        .allowsHitTesting(selectedCategory == category)
                        .disabled(selectedCategory != category || store.orderSaveBusy)
                        .accessibilityHidden(selectedCategory != category)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if selectedCategory?.editsSchedule == true || draft.hasChanges || draft.saved {
                HStack {
                    if draft.hasChanges { Text("有未保存的修改；切换页面会保留，退出前请保存。").font(.caption).foregroundStyle(.secondary) }
                    if !valid { Text("请检查各时段的起止时间和最小时间块。").foregroundStyle(.orange) }
                    if draft.saved { Label("已保存，未来计划已更新", systemImage: "checkmark.circle.fill").foregroundStyle(.teal) }
                    Spacer()
                    Button("恢复已保存设置") { draft.restore(from: store.state.settings) }.disabled(store.orderSaveBusy)
                    Button("保存并重新排程") { Task { await draft.save(using: store) } }.buttonStyle(.borderedProminent).disabled(!valid || !draft.hasChanges || store.orderSaveBusy)
                }.padding(20)
            }
        }.onAppear {
            draft.refresh(from: store.state.settings); syncHost = (try? PairingVault.load())?.host ?? ""
        }
        .onChange(of: store.state.settings) { _, current in draft.refresh(from: current) }
        .onChange(of: store.syncLedger.lastSuccess) { _, _ in pairingRequest = nil }
    }
    private var categoryGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(SettingsCategory.allCases) { category in
                    Button { selectedCategory = category } label: {
                        VStack(spacing: 12) {
                            Image(systemName: category.icon)
                                .font(.system(size: 27, weight: .medium)).foregroundStyle(Color.accentColor)
                            Text(category.rawValue).font(.headline).multilineTextAlignment(.center)
                        }
                        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.16)))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.rawValue + "，点击进入")
                }
            }.padding(24)
        }
    }
    @ViewBuilder private func categoryContent(_ category: SettingsCategory) -> some View {
        switch category {
        case .display:
            Section("显示设置") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("主页时间字号")
                        Spacer()
                        Text("\(Int(displayTimelineTimeFontSize.rounded())) 号").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $timelineTimeFontSize, in: 14...24, step: 1)
                        .accessibilityLabel("主页时间字号")
                        .accessibilityValue("\(Int(displayTimelineTimeFontSize.rounded())) 号")
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("09:00")
                            .font(.system(size: displayTimelineTimeFontSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("10:30")
                            .font(.system(size: displayTimelineTimeFontSize - 2, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    Text("预览：主页时间轴的开始时间与结束时间").font(.caption).foregroundStyle(.secondary)
                }
                Button("恢复默认字号") { timelineTimeFontSize = 17 }
                Text("调整后立即生效并自动保存。").font(.caption).foregroundStyle(.secondary)
            }
        case .availability:
            Section("每日可学习时间") {
                Text("可以为每天添加多段时间。不启用的日期不会分配学习任务。").font(.callout).foregroundStyle(.secondary)
                ForEach([2,3,4,5,6,7,1], id: \.self) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(weekdayNames[day]!).fontWeight(.semibold)
                            Spacer()
                            if !draft.settings.availability.contains(where: { $0.weekday == day }) { Text("休息日").foregroundStyle(.secondary) }
                            Button("添加时段", systemImage: "plus") { draft.settings.availability.append(.init(weekday: day, startMinute: 480, endMinute: 1380)) }
                        }
                        ForEach($draft.settings.availability) { $window in
                            if window.weekday == day {
                                HStack {
                                    TimeField(title: "从", minute: $window.startMinute)
                                    TimeField(title: "至", minute: $window.endMinute)
                                    Button(role: .destructive) { draft.settings.availability.removeAll { $0.id == window.id } } label: { Image(systemName: "minus.circle") }.help("移除此时段")
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                }
            }
        case .load:
            Section("学习负担提醒") {
                Stepper("一天超过 \(hours(dailyLoadWarningMinutes)) 时提醒", value: $dailyLoadWarningMinutes, in: 60...960, step: 30)
                Text("这是负担提醒线，不会减少可学习时间或改动截止日。调整后立即生效，仅保存在本机。").font(.caption).foregroundStyle(.secondary)
            }
        case .supervision:
            PlaybackSupervisionSettings(store: store)
        case .priorities:
            SchedulePrioritiesPanel(settings: $draft.settings)
        case .explanation:
            ScheduleExplanationPanel(state: store.state, result: store.result,
                                     hasUnsavedChanges: draft.hasChanges)
        case .defaults:
            Section("默认规则") {
                TextField("默认最小时间块（分钟）", value: $draft.settings.minimumScheduleUnit, format: .number)
                TimeField(title: "每日完成确认时间", minute: $draft.settings.notificationMinute)
                Text("软件打开时，在此时间之后提示确认当天已结束的任务；下次启动也会补查未确认的历史任务。").font(.caption).foregroundStyle(.secondary)
            }
        case .localSync:
            Section("热点局域网同步") {
                Text(store.syncStatus).textSelection(.enabled)
                Text("今日自动同步：" + (store.syncLedger.lastAutoDate == SyncLedger.day(Date()) ? "已完成" : "尚未完成"))
                if store.syncLedger.lastSuccess > 0 {
                    Text("最后同步：" + Date(timeIntervalSince1970: store.syncLedger.lastSuccess).formatted())
                }
                Text("首次配对：Mac 生成二维码，Android 扫码后开启两分钟接收窗口；以后只需两端点击立即同步。自动同步在启动或回到前台时检查。").font(.caption).foregroundStyle(.secondary)
                TextField("手机热点 IP", text: $syncHost)
                Button("读取当前网关") { Task { syncHost = await SyncClient.gateway() ?? "" } }
                if let pairingRequest {
                    PairingQRCodeView(payload: pairingRequest.payload)
                    Text("在 Android 的热点同步设置中点击“扫描 Mac 配对二维码”。二维码不包含日程内容，将在 (pairingRequest.expiresAt.formatted(date: .omitted, time: .shortened)) 失效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(pairingRequest == nil ? "生成配对二维码" : "重新生成二维码") {
                        do { pairingRequest = try SyncClient.makePairingRequest() }
                        catch { store.errorMessage = error.localizedDescription }
                        if syncHost.isEmpty { Task { syncHost = await SyncClient.gateway() ?? "" } }
                    }
                    if let pairingRequest {
                        Button("扫码后配对并同步") { store.startSync(host: syncHost, pairingText: pairingRequest.payload) }
                            .disabled(store.syncBusy || syncHost.isEmpty)
                    }
                    Button(store.syncBusy ? "立即同步（排队）" : "立即同步") { store.startSync() }
                }
                DisclosureGroup("本次运行同步日志") {
                    Text(store.syncLog.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        case .cloudSync:
            Section("云端同步") {
                CloudConnectionSettings(store: store)
            }
        case .data:
            DataBackupView(store: store)
        }
    }
}

struct CompletionEditor: View {
    @Bindable var store: PlannerStore
    let task: ScheduledTask
    @State private var actual = 0
    @State private var studyDate = Date()
    @State private var message = ""
    @State private var saving = false
    @State private var latestTask: ScheduledTask?
    @State private var unavailable = false
    @State private var initialized = false
    @Environment(\.dismiss) private var dismiss
    private func reloadTask() {
        guard !saving, !store.orderSaveBusy else { return }
        do {
            latestTask = try store.state.pendingConfirmationTask(id: task.id)
            unavailable = false; message = ""
        } catch {
            unavailable = true
            message = error.localizedDescription + " 输入仍保留，请返回日历核对。"
        }
    }

    var body: some View {
        let task = latestTask ?? self.task
        VStack(alignment: .leading, spacing: 20) {
            Text(task.planningStart > Date() ? "提前完成学习" : "确认学习完成情况").font(.title2.bold())
            Text(store.course(task.courseID)?.name ?? "课程").font(.headline)
            if let lessonName = task.lessonName { Text(lessonName).font(.callout).foregroundStyle(.secondary) }
            Text("\(task.planningStart.formatted(date: .abbreviated, time: .shortened))\(task.isFloating ? "–" + task.planningEnd.formatted(date: .omitted, time: .shortened) + " 时段内" : "") · 计划 \(hours(task.durationMinutes))").foregroundStyle(.secondary)
            Button("载入最新安排", action: reloadTask).disabled(saving || store.orderSaveBusy)
                .help("保留填写的分钟数和学习日期，载入当前待确认任务后重新核对")
            if latestTask != nil && !unavailable {
                Text("已载入最新安排，填写的分钟数和学习日期已保留；请核对后确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CompletionInput(actual: $actual, planned: task.durationMinutes).disabled(saving)
            DatePicker("实际学习日期", selection: $studyDate, in: ...Date(), displayedComponents: .date).disabled(saving)
            Text("只有实际完成的学习量会计入进度；其余部分会自动重新分配。").font(.callout).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            if saving { ProgressView("正在保存确认并更新课表…").controlSize(.small) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("确认并重新排程") {
                    guard !saving, !unavailable, !store.orderSaveBusy else { return }
                    let minutes = actual, date = studyDate
                    saving = true; message = ""
                    Task {
                        defer { saving = false }
                        if await store.confirm(task, minutes: minutes, studyDate: date) { dismiss() }
                        else { message = store.errorMessage ?? "确认未保存" }
                    }
                }.buttonStyle(.borderedProminent).disabled(unavailable || saving || actual < 0 || actual > task.durationMinutes || store.orderSaveBusy)
            }
        }.padding(28).frame(width: 500).interactiveDismissDisabled(saving)
        .onAppear {
            guard !initialized else { return }
            actual = task.durationMinutes; studyDate = min(task.start, Date()); initialized = true
        }
    }
}
struct DailyReviewView: View {
    @Bindable var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [ScheduledTask] = []
    @State private var values: [UUID: Int] = [:]
    @State private var reviewed: Set<UUID> = []
    @State private var studyDates: [UUID: Date] = [:]
    @State private var message = ""
    @State private var saving = false
    @State private var changedTasks: Set<UUID> = []
    @State private var refreshNotice = ""

    private func refreshTasks() {
        guard !saving, !store.orderSaveBusy else { return }
        let next = DailyReviewRefresh(previous: tasks, latest: store.reviewTasks, values: values,
                                      studyDates: studyDates, reviewed: reviewed)
        tasks = next.tasks; values = next.values; studyDates = next.studyDates
        reviewed = next.reviewed; changedTasks = next.changedIDs; message = ""
        refreshNotice = "已刷新：新增 \(next.addedCount) 项、变化 \(next.changedIDs.count) 项、退出待确认 \(next.removedCount) 项。仍在列表中的输入已保留。"
    }

    var body: some View {
        let selectedTasks = tasks.filter { reviewed.contains($0.id) }
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "确认学习完成情况", subtitle: "只保存已勾选并核对的项目；未勾选项目不确认，待学日程仍可能随重排更新。")
            HStack(alignment: .top) {
                Button("刷新待确认列表", action: refreshTasks).disabled(saving || store.orderSaveBusy)
                Text("保留仍在列表中的输入；有变化的任务须重新核对。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24)
            if !refreshNotice.isEmpty { Text(refreshNotice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24) }
            if tasks.isEmpty { ContentUnavailableView("没有待确认的任务", systemImage: "checkmark.circle", description: Text("所有历史计划均已确认。")) }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(tasks) { task in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(store.course(task.courseID)?.name ?? "课程").font(.headline); Spacer(); Text(task.planningStart.formatted(date: .abbreviated, time: .shortened) + (task.isFloating ? "–" + task.planningEnd.formatted(date: .omitted, time: .shortened) + " 内浮动" : "")).foregroundStyle(.secondary) }
                            if let lessonName = task.lessonName { Text(lessonName).font(.callout).foregroundStyle(.secondary) }
                            CompletionInput(actual: Binding(get: { values[task.id] ?? 0 }, set: { values[task.id] = $0; reviewed.insert(task.id) }), planned: task.durationMinutes)
                            DatePicker("实际学习日期（补录请核对）", selection: Binding(get: { studyDates[task.id] ?? min(task.start, Date()) }, set: { studyDates[task.id] = $0 }), in: ...Date(), displayedComponents: .date)
                            Toggle("已核对并提交本项（\(values[task.id] ?? 0) 分钟）", isOn: Binding(
                                get: { reviewed.contains(task.id) },
                                set: { selected in
                                    if selected { values[task.id] = values[task.id] ?? 0; reviewed.insert(task.id) }
                                    else { reviewed.remove(task.id) }
                                }
                            )).toggleStyle(.checkbox)
                            if !reviewed.contains(task.id) {
                                Text(changedTasks.contains(task.id) ? "任务已更新，请核对分钟数和学习日期后重新选择完成情况。" : "本项暂不提交，填写分钟数会自动勾选。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.horizontal, 24)
            }.disabled(saving)
            if saving { ProgressView("正在保存本批确认并更新课表…").controlSize(.small).padding(.horizontal, 24) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
            HStack {
                Button("全部标记完成") { for task in tasks { values[task.id] = task.durationMinutes; reviewed.insert(task.id) } }
                Button("全部未完成") { for task in tasks { values[task.id] = 0; reviewed.insert(task.id) } }
                Button("全部暂不提交") { reviewed.removeAll() }
                Spacer()
                Button("稍后确认") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存已核对 \(selectedTasks.count) 项") {
                    guard !saving, !store.orderSaveBusy else { return }
                    let draft: ConfirmationBatchDraft
                    do { draft = try ConfirmationBatchDraft(reviewed: selectedTasks, minutes: values, studyDates: studyDates) }
                    catch { message = error.localizedDescription; return }
                    saving = true; message = ""
                    Task {
                        defer { saving = false }
                        let now = Date()
                        let success = await store.change(replan: draft.requiresReplan(at: now), now: now) { state in
                            try draft.apply(to: &state, now: now)
                        }
                        if success {
                            saving = false; refreshTasks()
                            if tasks.isEmpty { dismiss() }
                            else { refreshNotice = "已保存 \(draft.count) 项。" + refreshNotice }
                        } else { message = store.errorMessage ?? "本批确认未保存" }
                    }
                }.buttonStyle(.borderedProminent).disabled(store.orderSaveBusy || selectedTasks.isEmpty || selectedTasks.contains {
                    let value = values[$0.id] ?? -1
                    return value < 0 || value > $0.durationMinutes
                })
            }.padding(24).disabled(saving)
        }.frame(width: 740, height: 620).interactiveDismissDisabled(saving)
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
    @AppStorage("dailyStudyLoadWarningMinutes") private var dailyLoadWarningMinutes = 480
    @Environment(\.dismiss) private var dismiss
    private var health: ScheduleHealth? {
        ScheduleHealthAnalyzer().assess(state: store.state, result: store.result, now: Date(), heavyDayMinutes: dailyLoadWarningMinutes)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(health?.title ?? "当前没有待排课程").font(.title2.bold())
            Text("截止日期保持不变。先核对补回安排和每天的负担，再决定是否调整可学习时段。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let health {
                        Text(health.explanation).font(.callout)
                        if health.pausedMinutes > 0 { Text("暂停自动排程的学习量：\(hours(health.pausedMinutes))。请在课程中恢复自动排程后重新核对。").foregroundStyle(.orange) }
                    }
                    ForEach(store.result.adjustments, id: \.self) { Text($0).font(.callout) }
                    ForEach(Array(store.result.conflicts.enumerated()), id: \.offset) { _, conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("已确认的约束冲突 · 截止 \(conflict.deadline.formatted(date: .abbreviated, time: .omitted))").font(.headline)
                            if let continuous = conflict.minimumContinuousMinutes {
                                Text("有一块内容需要连续 \(continuous) 分钟，现有最长连续空档只有 \(conflict.availableMinutes) 分钟。")
                            } else {
                                Text("\(conflict.windowStart.formatted(date: .abbreviated, time: .omitted)) 起需要 \(hours(conflict.requiredMinutes))，即使暂不扣除浮动事项和课间休息，最多也只有 \(hours(conflict.availableMinutes))。")
                                Text("至少缺少 \(hours(conflict.provenDeficit ?? 0))。")
                            }
                            Text("涉及：" + conflict.courseNames.joined(separator: "、")).font(.caption)
                        }.foregroundStyle(.red)
                    }
                    ForEach(store.result.diagnostics, id: \.self) { Text($0).foregroundStyle(.orange) }
                    ForEach(store.result.risks) { risk in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("截止 \(risk.deadline.formatted(date: .abbreviated, time: .omitted)) · 暂未排入 \(hours(risk.unscheduledMinutes))").font(.headline)
                            Text("这表示当前排法尚不完整，未排入量不能直接当作真实时间缺口。").font(.callout)
                            Text("涉及：" + risk.courseNames.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !(store.result.risks.isEmpty && store.result.conflicts.isEmpty) {
                        Text("按整节排程的课程需要连续空档；缩小普通课程的最小时间块不会自动拆开课节。可增加或连通学习时段，或核对课节编排。")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(store.courses.filter { course in store.result.risks.contains { $0.courseNames.contains(course.name) } }) { course in
                            Button("查看「\(course.name)」课程与课节") { editCourse(course) }
                        }
                    }
                    if let health {
                        if !health.recovery.isEmpty {
                            GroupBox("今日确认任务中已排入的待补内容") {
                                VStack(spacing: 8) {
                                    ForEach(health.recovery) { day in
                                        LabeledContent(day.date.formatted(date: .abbreviated, time: .omitted), value: hours(day.plannedMinutes))
                                    }
                                }.frame(maxWidth: .infinity)
                            }
                        }
                        if !health.dayPlans.isEmpty {
                            GroupBox("未来每日学习量 · 不含课间休息") {
                                LazyVStack(spacing: 8) {
                                    ForEach(health.dayPlans) { day in
                                        LabeledContent(day.date.formatted(date: .abbreviated, time: .omitted), value: hours(day.plannedMinutes))
                                            .foregroundStyle(day.plannedMinutes > dailyLoadWarningMinutes ? Color.orange : Color.primary)
                                    }
                                }.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Button("调整可学习时间与负担提醒线", action: adjustSettings); Spacer(); Button("知道了") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 650, height: 680)
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

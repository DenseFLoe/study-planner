import SwiftUI
import Charts
import StudyCore

enum Page: String, CaseIterable {
    case calendar = "日程"
    case courses = "课程"
    case fixed = "固定课表"
    case settings = "学习设置"
}
enum EditorSheet: Identifiable {
    case scheduleSearch
    case course(Course), lessonOrder(Course), fixed(FixedEvent), completion(ScheduledTask), review, risks, webImport, netdiskImport, mergeCourses

    var id: String {
        switch self {
        case .scheduleSearch: "scheduleSearch"
        case .course(let course): "course\(course.id)"
        case .lessonOrder(let course): "lessonOrder\(course.id)"
        case .fixed(let event): "fixed\(event.id)"
        case .completion(let task): "task\(task.id)"
        case .review: "review"
        case .risks: "risks"
        case .webImport: "webImport"
        case .netdiskImport: "netdiskImport"
        case .mergeCourses: "mergeCourses"
        }
    }
}

struct MainView: View {
    @Bindable var store: PlannerStore
    @State private var page = Page.calendar
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var month = Date()
    @State private var sheet: EditorSheet?
    @State private var showingAddMenu = false
    @Namespace private var navigationSelection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 232)
            Rectangle().fill(PlannerTheme.hairline).frame(width: 1)
            VStack(spacing: 0) {
                header
                Group {
                    if !store.isReady {
                        ContentUnavailableView(
                            "无法打开数据库",
                            systemImage: "externaldrive.badge.exclamationmark",
                            description: Text("请关闭软件并检查本地数据文件的访问权限。")
                        )
                    } else {
                        pageContent
                            .id(page)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background { PlannerGlassBackdrop() }
        .animation(reduceMotion ? nil : PlannerTheme.spring, value: page)
        .animation(reduceMotion ? nil : PlannerTheme.spring, value: selectedDay)
        .toolbar {
            if store.demo {
                ToolbarItem {
                    Text("示例预览 · 不保存").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $sheet, onDismiss: { store.showDailyReview = false }) { selection in
            switch selection {
            case .scheduleSearch:
                ScheduleSearchView(tasks: store.state.tasks, courses: store.state.courses) { date in
                    selectedDay = Calendar.current.startOfDay(for: date)
                    month = selectedDay
                    page = .calendar
                    sheet = nil
                }
            case .mergeCourses: CourseMergeEditor(store: store)
            case .webImport: WebCourseImportSheet(store: store)
            case .netdiskImport: NetdiskImportSheet(store: store)
            case .course(let course): CourseEditor(store: store, course: course)
            case .lessonOrder(let course): LessonOrderEditor(store: store, course: course)
            case .fixed(let event): FixedEventEditor(store: store, event: event)
            case .completion(let task): CompletionEditor(store: store, task: task)
            case .review: DailyReviewView(store: store)
            case .risks:
                RiskView(
                    store: store,
                    adjustSettings: { sheet = nil; page = .settings },
                    editCourse: { sheet = .course($0) }
                )
            }
        }
        .alert(
            "操作提示",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onAppear {
            store.triggerAutomaticSync()
            if store.showDailyReview { sheet = .review }
        }
        .onChange(of: store.showDailyReview) { _, value in
            if value && sheet == nil { sheet = .review }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active {
                store.checkDay()
                store.triggerAutomaticSync()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                store.checkDay()
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .calendar:
            HStack(spacing: 0) {
                agenda.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(PlannerTheme.hairline).frame(width: 1)
                insightsPanel.frame(width: 330)
            }
        case .courses: courseList
        case .fixed: fixedList
        case .settings: SettingsView(store: store)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                .liquidGlass(
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous),
                    tint: PlannerTheme.accent
                )
                .shadow(color: PlannerTheme.accent.opacity(0.22), radius: 10, y: 4)

                Text("学习日程")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 20)

            VStack(spacing: 5) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button {
                        withAnimation(reduceMotion ? nil : PlannerTheme.spring) { page = item }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(item))
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 20)
                            Text(item.rawValue)
                                .font(.system(size: 14, weight: page == item ? .semibold : .medium))
                            Spacer()
                        }
                        .foregroundStyle(page == item ? Color.white : Color.primary.opacity(0.72))
                        .padding(.horizontal, 13)
                        .frame(height: 42)
                        .background {
                            if page == item {
                                Color.clear
                                    .liquidGlass(
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                        tint: PlannerTheme.accent,
                                        interactive: true,
                                        fallbackMaterial: .thinMaterial
                                    )
                                    .matchedGeometryEffect(id: "navigation", in: navigationSelection)
                                    .shadow(color: PlannerTheme.accent.opacity(0.18), radius: 10, y: 4)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            Rectangle()
                .fill(PlannerTheme.hairline)
                .frame(height: 1)
                .padding(.horizontal, 18)
                .padding(.vertical, 18)

            MonthCalendar(
                selectedDay: $selectedDay,
                month: $month,
                tasks: store.state.tasks,
                fixed: store.state.fixedEvents
            ) {
                withAnimation(reduceMotion ? nil : PlannerTheme.spring) { page = .calendar }
            }
            .padding(.horizontal, 16)

            if !store.reviewTasks.isEmpty {
                Button { sheet = .review } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("学习完成确认").fontWeight(.semibold)
                            Text("\(store.reviewTasks.count) 项计划待确认").font(.caption)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.bold())
                    }
                    .padding(12)
                    .foregroundStyle(.orange)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.top, 16)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 5) {
                Text("持续的努力").font(.caption.weight(.semibold))
                Text("会让平凡的日子发光。").font(.caption)
            }
            .foregroundStyle(.tertiary)
            .padding(18)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [Color.white.opacity(0.48), PlannerTheme.hairline, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(pageTitle)
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if page == .calendar {
                HStack(spacing: 8) {
                    Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(CircularIconButtonStyle())
                        .focusEffectDisabled()
                        .help("前一天")
                    Button { moveDay(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(CircularIconButtonStyle())
                        .focusEffectDisabled()
                        .help("后一天")
                    Button("今天") {
                        withAnimation(reduceMotion ? nil : PlannerTheme.spring) {
                            selectedDay = Calendar.current.startOfDay(for: Date())
                            month = selectedDay
                        }
                    }
                    .buttonStyle(SoftButtonStyle())
                    .focusEffectDisabled()
                }
            }

            if !store.result.risks.isEmpty || !store.result.diagnostics.isEmpty {
                Button { sheet = .risks } label: {
                    Label("排程需要调整", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(SoftButtonStyle())
                .focusEffectDisabled()
                .foregroundStyle(.orange)
            }

            Button { showingAddMenu = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(CircularIconButtonStyle(prominent: true))
            .focusEffectDisabled()
            .disabled(!store.isReady)
            .help("添加")
            .popover(isPresented: $showingAddMenu, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("添加到日程")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)

                    AddMenuActionRow(
                        title: "录播 / 可调度课程",
                        systemImage: "book.closed.fill"
                    ) {
                        showingAddMenu = false
                        newCourse()
                    }

                    AddMenuActionRow(
                        title: "从网站导入课程",
                        systemImage: "globe"
                    ) {
                        showingAddMenu = false
                        sheet = .webImport
                    }

                    AddMenuActionRow(
                        title: "从夸克网盘导入课程",
                        systemImage: "externaldrive"
                    ) {
                        showingAddMenu = false
                        sheet = .netdiskImport
                    }

                    AddMenuActionRow(
                        title: "固定课程 / 其他事项",
                        systemImage: "calendar.badge.clock"
                    ) {
                        showingAddMenu = false
                        newFixed()
                    }
                }
                .padding(12)
                .frame(width: 235)
            }
        }
        .padding(.horizontal, PlannerTheme.pagePadding)
        .padding(.top, 21)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Color.clear, Color.white.opacity(0.42), PlannerTheme.hairline, Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
    }

    private var pageTitle: String {
        page == .calendar
            ? selectedDay.formatted(.dateTime.month(.wide).day().weekday(.wide))
            : page.rawValue
    }

    private var subtitle: String {
        switch page {
        case .calendar: "固定课表优先，学习任务随进度自动调整。"
        case .courses: "管理学习量、截止日期和每门课程的进度。"
        case .fixed: "为课程和事项保留固定时间或时段内的固定时长。"
        case .settings: "设置可学习时段、排程规则与本地同步。"
        }
    }

    private var dayTasks: [ScheduledTask] {
        let start = Calendar.current.startOfDay(for: selectedDay)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return store.state.tasks.filter {
            $0.start >= start && $0.start < end &&
            (store.course($0.courseID)?.isArchived == false || !$0.isUnconfirmed)
        }
    }

    private var dayEvents: [FixedEvent] {
        store.state.fixedEvents.filter { $0.occurs(on: selectedDay, calendar: .current) }
    }

    private var skippedDayEvents: [FixedEvent] {
        store.state.fixedEvents.filter {
            $0.occurs(on: selectedDay, calendar: .current, includingExcluded: true) &&
            !$0.occurs(on: selectedDay, calendar: .current)
        }.sorted { $0.startMinute < $1.startMinute }
    }

    private var canChangeDayEvents: Bool {
        Calendar.current.startOfDay(for: selectedDay) >= Calendar.current.startOfDay(for: Date()) &&
        store.isReady && !store.syncBusy
    }

    private var agenda: some View {
        let items = timelineItems
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ActualStudyStartEntry(store: store) {
                    selectedDay = Calendar.current.startOfDay(for: Date())
                    month = selectedDay
                }
                Button { sheet = .scheduleSearch } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("搜索课程或课时，查找安排日期")
                        Spacer()
                        Text("⌘F").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .plannerSurface(radius: 14, material: .thinMaterial, shadow: false)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                summaryBand
                if dayEvents.contains(where: \.isFloating) {
                    Label("浮动事项已预留 " + hours(dayEvents.filter(\.isFloating).reduce(0) { $0 + $1.occupiedMinutes }) + "；虚线学习卡片在标注时段内完成，先后可调整。", systemImage: "arrow.left.arrow.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PlannerSectionTitle(
                    title: Calendar.current.isDateInToday(selectedDay)
                        ? (store.state.settings.actualStudyStart(on: Date()) == nil ? "今天的安排" : "新课表 · 今天")
                        : "当天的安排",
                    detail: "\(items.count) 项任务 · 长按课程可拖动交换"
                )

                if dayTasks.isEmpty && dayEvents.isEmpty {
                    emptyAgenda
                } else {
                    DailyTaskTimeline(
                        store: store, items: items, canEdit: canChangeDayEvents,
                        editTask: { sheet = .completion($0) },
                        editEvent: { sheet = .fixed($0) },
                        skipEvent: { store.setEventSkipped($0, on: selectedDay, skipped: true) }
                    )
                    .id(selectedDay)

                    if dayTasks.contains(where: { !$0.isUnconfirmed }) {
                        PlannerSectionTitle(title: "完成记录", detail: "不再占用时间")
                            .padding(.top, 2)
                        VStack(spacing: 10) {
                            ForEach(dayTasks.filter { !$0.isUnconfirmed }) { task in
                                CompletedTaskRow(
                                    task: task,
                                    course: store.course(task.courseID),
                                    undo: { _ = store.undoConfirmation(task) }
                                )
                            }
                        }
                    }

                    Text("可提前确认未来任务；未完成的学习量会在剩余日期中重新分配。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 76)
                }
                if !skippedDayEvents.isEmpty {
                    PlannerSectionTitle(title: "本日已临时移除", detail: "仅影响这一天，其他日期照常安排")
                    ForEach(skippedDayEvents) { event in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).font(.headline)
                                Text("\(clockTime(event.startMinute))–\(clockTime(event.endMinute)) · 本日不占用时间")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("恢复本日并重排", systemImage: "arrow.uturn.backward") {
                                store.setEventSkipped(event, on: selectedDay, skipped: false)
                            }
                            .disabled(!canChangeDayEvents)
                        }
                        .padding(14)
                        .plannerSurface(radius: 14, material: .thinMaterial, shadow: false)
                    }
                }
            }
            .padding(.horizontal, PlannerTheme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
    }

    private var summaryBand: some View {
        HStack(spacing: 0) {
            SummaryMetric(
                title: "安排学习",
                value: hours(dayTasks.filter(\.isUnconfirmed).reduce(0) { $0 + $1.durationMinutes }),
                icon: "book.closed.fill",
                color: PlannerTheme.accent
            )
            metricDivider
            SummaryMetric(
                title: "已确认",
                value: hours(store.state.completions.filter {
                    Calendar.current.isDate($0.recordedAt, inSameDayAs: selectedDay)
                }.reduce(0) { $0 + $1.minutes }),
                icon: "checkmark",
                color: .teal
            )
            metricDivider
            SummaryMetric(
                title: "固定事项",
                value: "\(dayEvents.count) 项",
                icon: "calendar",
                color: .purple
            )
        }
        .padding(.vertical, 15)
        .plannerSurface(radius: 18, material: .thinMaterial)
    }

    private var metricDivider: some View {
        Rectangle().fill(PlannerTheme.hairline).frame(width: 1, height: 54)
    }

    private var emptyAgenda: some View {
        VStack(spacing: 15) {
            ZStack {
                Circle().fill(PlannerTheme.accent.opacity(0.10))
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(PlannerTheme.accent)
            }
            .frame(width: 66, height: 66)

            Text(store.courses.isEmpty ? "从第一门课程开始" : "这一天还没有安排")
                .font(.title3.bold())
            Text(store.courses.isEmpty ? "添加课程和截止日期，让学习计划自动生成。" : "可以查看其他日期，或调整可学习时间。")
                .foregroundStyle(.secondary)
            Button("添加学习课程") { newCourse() }
                .buttonStyle(SoftButtonStyle(prominent: true))
            if store.state.canLoadExample {
                Button("载入示例，体验自动排程") { store.loadExample() }.buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }

    private var insightsPanel: some View {
        ScrollView {
            VStack(spacing: 16) {
                WeeklyStudyChart(
                    selectedDay: selectedDay,
                    tasks: store.state.tasks,
                    courses: store.courses
                )

                CourseProgressPanel(
                    courses: store.courses,
                    demands: store.result.demands,
                    studyLoad: store.studyLoad,
                    completedMinutes: { store.state.completedMinutes(for: $0) },
                    edit: { sheet = .course($0) }
                )

                Label("计划会随学习进度动态变化", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(.ultraThinMaterial)
    }

    private var courseList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlannerSectionTitle(title: "可调度课程", detail: "\(store.courses.count) 门")
                HStack {
                    Button("合并课程", systemImage: "arrow.triangle.merge") { sheet = .mergeCourses }
                        .disabled(store.courses.count < 2)
                    Button("从网站抓取全部课程", systemImage: "globe") { sheet = .webImport }
                    Button("从夸克网盘导入", systemImage: "externaldrive") { sheet = .netdiskImport }
                    Button("添加课程", systemImage: "plus") { newCourse() }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                }

                ForEach(store.courses) { course in
                    CourseListRow(
                        course: course,
                        completed: store.state.completedMinutes(for: course),
                        minimumBlock: course.minimumBlockMinutes == 0
                            ? store.state.settings.minimumScheduleUnit
                            : course.minimumBlockMinutes,
                        edit: { sheet = .course(course) },
                        reorder: store.state.lessonWorkItems(for: course).count > 1
                            ? { sheet = .lessonOrder(course) } : nil
                    )
                }

                if store.courses.isEmpty {
                    ContentUnavailableView(
                        "还没有学习课程",
                        systemImage: "books.vertical",
                        description: Text("录入总学习量和截止日期，即可生成计划。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                }
            }
            .padding(PlannerTheme.pagePadding)
        }
        .scrollIndicators(.hidden)
    }

    private var fixedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    PlannerSectionTitle(title: "周期课表与固定事项", detail: "\(store.state.fixedEvents.count) 项")
                    Button("添加固定事项", systemImage: "plus") { newFixed() }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                }

                ForEach(store.state.fixedEvents.sorted { $0.startDate < $1.startDate }) { event in
                    FixedEventListRow(
                        event: event,
                        edit: event.endDate < Calendar.current.startOfDay(for: Date())
                            ? nil
                            : { sheet = .fixed(event) }
                    )
                }

                if store.state.fixedEvents.isEmpty {
                    ContentUnavailableView(
                        "添加你的固定课表",
                        systemImage: "calendar.badge.plus",
                        description: Text("学校课程、补习班、考试或休息时间。支持每周重复和学期起止日期。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                }
            }
            .padding(PlannerTheme.pagePadding)
        }
        .scrollIndicators(.hidden)
    }

    private var timelineItems: [TimelineItem] {
        (dayTasks.filter(\.isUnconfirmed).map {
            TimelineItem(id: $0.id, start: $0.planningStart, end: $0.planningEnd, task: $0)
        } + dayEvents.map {
            TimelineItem(
                id: $0.id,
                start: ScheduleEngine().instant(day: selectedDay, minute: $0.startMinute),
                end: ScheduleEngine().instant(day: selectedDay, minute: $0.endMinute),
                event: $0
            )
        }).sorted {
            let lhs = $0.task?.start ?? $0.start
            let rhs = $1.task?.start ?? $1.start
            return lhs != rhs ? lhs < rhs : $0.id.uuidString < $1.id.uuidString
        }
    }

    private func moveDay(_ step: Int) {
        withAnimation(reduceMotion ? nil : PlannerTheme.spring) {
            selectedDay = Calendar.current.date(byAdding: .day, value: step, to: selectedDay)!
            month = selectedDay
        }
    }

    private func newCourse() {
        sheet = .course(Course(
            name: "",
            totalMinutes: 600,
            startDate: Calendar.current.startOfDay(for: Date()),
            deadline: Calendar.current.date(byAdding: .day, value: 30, to: Date())!,
            minimumBlockMinutes: 0
        ))
    }

    private func newFixed() {
        sheet = .fixed(FixedEvent(
            title: "",
            startMinute: 480,
            endMinute: 580,
            startDate: Calendar.current.startOfDay(for: Date()),
            endDate: Calendar.current.date(byAdding: .day, value: 111, to: Date())!,
            weekdays: [2]
        ))
    }

    private func icon(_ page: Page) -> String {
        switch page {
        case .calendar: "calendar"
        case .courses: "books.vertical"
        case .fixed: "calendar.badge.clock"
        case .settings: "gearshape"
        }
    }
}

private struct AddMenuActionRow: View {
    var title: String
    var systemImage: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { value in
            withAnimation(.easeOut(duration: 0.14)) { hovering = value }
        }
    }
}

private struct TimelineItem: Identifiable {
    var id: UUID
    var start: Date
    var end: Date
    var task: ScheduledTask?
    var event: FixedEvent?
}

private struct SummaryMetric: View {
    var title: String
    var value: String
    var icon: String
    var color: Color

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(color.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}

/// Pointer movement only invalidates this list, not the chart, calendar or summaries.
private struct DailyTaskTimeline: View {
    @Bindable var store: PlannerStore
    let items: [TimelineItem]
    let canEdit: Bool
    let editTask: (ScheduledTask) -> Void
    let editEvent: (FixedEvent) -> Void
    let skipEvent: (FixedEvent) -> Void
    @State private var frames: [UUID: CGRect] = [:]
    /// The drop targets measured when the drag started. Measuring mid-drag would
    /// feed the moving cards' own layout back into hit testing and make the
    /// highlight flicker between candidates, so the set stays frozen until the
    /// settle animation finishes.
    @State private var frozenFrames: [UUID: CGRect]?
    @State private var pendingFrames: [UUID: CGRect]?
    @State private var dragging: UUID?
    @State private var target: UUID?
    /// Holds the releasing card's id until the settle animation completes, so the
    /// card keeps its zIndex instead of dropping behind the cards it swapped with
    /// the instant the pointer is released.
    @State private var settling: UUID?
    /// Identifies the settle in flight. A newer drag clears it, which is what keeps
    /// a stale completion from wiping the new drag's state.
    @State private var settleToken: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hitFrames: [UUID: CGRect] { frozenFrames ?? frames }

    private func target(at point: CGPoint, source: UUID) -> UUID? {
        hitFrames
            .filter { $0.key != source && $0.value.contains(point) }
            .min { $0.value.minY < $1.value.minY }?
            .key
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                TimelineRow(
                    item: item, course: item.task.flatMap { store.course($0.courseID) },
                    isLast: index == items.count - 1,
                    confirm: { _ = store.confirm($0, minutes: $0.durationMinutes) },
                    editTask: editTask, editEvent: editEvent, skipEvent: skipEvent,
                    canSkipEvent: canEdit && !store.orderSaveBusy,
                    canReorder: canEdit && !store.orderSaveBusy && item.task != nil,
                    targeted: target == item.id,
                    dragChanged: { point in dragChanged(item.id, point: point) },
                    dragEnded: { point in dragEnded(item.id, point: point) }
                )
                .zIndex(dragging == item.id || settling == item.id ? 1 : 0)
            }
        }
        .coordinateSpace(name: "dailyTaskTimeline")
        .onPreferenceChange(DailyTaskFrames.self) { next in
            // Everything measured while the set is frozen is only kept aside and
            // applied once the settle finishes.
            guard frozenFrames == nil else {
                pendingFrames = next
                return
            }
            // The dragged card's translated frame is not a drop target.
            let stationary = next.filter { $0.key != dragging }
            let previous = frames.filter { $0.key != dragging }
            if stationary != previous { frames = next }
        }
    }

    private func dragChanged(_ id: UUID, point: CGPoint?) {
        guard let point else {
            cancelDrag(id)
            return
        }
        if dragging != id {
            // Supersede any settle still in flight: its completion must not clear
            // this drag's frozen targets or zIndex.
            settleToken = nil
            dragging = id
            target = nil
            frozenFrames = pendingFrames ?? frames
            pendingFrames = nil
        }
        let next = target(at: point, source: id)
        if target != next { target = next }
    }

    /// A cancelled drag never reaches `dragEnded`, so it releases the frozen set
    /// straight away. A normal release has already cleared `dragging`, which keeps
    /// this from touching the settle that release started.
    private func cancelDrag(_ id: UUID) {
        guard dragging == id else { return }
        dragging = nil
        target = nil
        pendingFrames = nil
        frozenFrames = nil
    }

    private func dragEnded(_ id: UUID, point: CGPoint?) {
        // `onEnded` also fires for a long press that never turned into a drag.
        guard dragging == id else { return }
        let destination = point.flatMap { target(at: $0, source: id) }
        guard !reduceMotion else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let destination { store.swapDailyTasks(id, destination) }
                dragging = nil
                target = nil
                settling = nil
                settleToken = nil
                pendingFrames = nil
                frozenFrames = nil
            }
            return
        }
        let token = UUID()
        settleToken = token
        // The same settle spring as the card's offset, in one transaction: the
        // offset returning to zero and the list reorder interpolate continuously
        // from the release point.
        withAnimation(DailyTaskMotion.settle, completionCriteria: .logicallyComplete) {
            if let destination { store.swapDailyTasks(id, destination) }
            dragging = nil
            target = nil
            settling = id
        } completion: {
            finishSettle(token: token, source: id)
        }
    }

    private func finishSettle(token: UUID, source: UUID) {
        guard settleToken == token else { return }
        settleToken = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if settling == source { settling = nil }
            if let pendingFrames { frames = pendingFrames }
            pendingFrames = nil
            frozenFrames = nil
        }
    }
}

private struct TimelineRow: View {
    var item: TimelineItem
    var course: Course?
    var isLast: Bool
    var confirm: (ScheduledTask) -> Void
    var editTask: (ScheduledTask) -> Void
    var editEvent: (FixedEvent) -> Void
    var skipEvent: (FixedEvent) -> Void
    var canSkipEvent: Bool
    var canReorder: Bool
    var targeted: Bool
    var dragChanged: (CGPoint?) -> Void
    var dragEnded: (CGPoint?) -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var floating: Bool { item.event?.isFloating == true || item.task?.isFloating == true }

    private var tint: Color {
        if item.task != nil { return courseColor(course?.color ?? "blue") }
        return courseColor(item.event?.color ?? "orange")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if floating { Image(systemName: "arrow.up.arrow.down").font(.caption2).foregroundStyle(tint) }
                Text(item.end.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 53, alignment: .trailing)
            .padding(.top, 17)

            VStack(spacing: 0) {
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                    .shadow(color: tint.opacity(0.28), radius: 5)
                    .padding(.top, 21)
                if !isLast {
                    Rectangle()
                        .fill(PlannerTheme.hairline)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint).frame(width: 4)

                ZStack {
                    Circle().fill(tint.opacity(0.11))
                    Image(systemName: floating ? "arrow.left.arrow.right" : (item.task == nil ? "lock.fill" : "book.closed.fill"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.task == nil ? (item.event?.title ?? "固定事项") : (course?.name ?? "已删除课程"))
                        .font(.system(size: 15, weight: .semibold))
                    if let task = item.task {
                        if let lessonName = task.lessonName, !lessonName.isEmpty {
                            Text(lessonName)
                                .font(.system(size: 18, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text([hours(task.durationMinutes), task.isFloating ? "时段内完成 · 顺序可调" : (task.end < Date() ? "待确认" : "可调度学习")].joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.event?.isFloating == true ? "时段内浮动 · 固定占用 " + hours(item.event!.occupiedMinutes) : "固定事项 · 不参与自动移动")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let event = item.event, event.isFloating {
                        FloatingWindowIndicator(occupied: event.occupiedMinutes, window: event.endMinute - event.startMinute, tint: tint)
                            .frame(maxWidth: 280)
                    }
                }

                Spacer(minLength: 8)

                if let task = item.task {
                    Text(hours(task.durationMinutes))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Button { confirm(task) } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                            .foregroundStyle(hovering ? Color.white : tint)
                            .background(hovering ? tint : Color.clear, in: Circle())
                            .overlay(Circle().strokeBorder(tint.opacity(hovering ? 0 : 0.55), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(task.planningStart > Date() ? "提前完成此任务" : "确认全部完成")
                    .accessibilityLabel(task.planningStart > Date() ? "提前完成\(course?.name ?? "任务")" : "完成\(course?.name ?? "任务")")
                    Button { editTask(task) } label: { Image(systemName: "ellipsis") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("部分完成或未完成")
                } else if let event = item.event {
                    Button("仅此日移除并重排", systemImage: "calendar.badge.minus") { skipEvent(event) }
                        .font(.caption)
                        .disabled(!canSkipEvent)
                        .help("临时移除本日这一次固定事项，重排今天及未来未确认任务；其他日期照常安排")
                    Button { editEvent(event) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("编辑固定事项")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 76)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: 17, style: .continuous),
                tint: tint.opacity(item.event == nil ? (hovering ? 0.18 : 0.10) : (hovering ? 0.20 : 0.13)),
                interactive: true,
                fallbackMaterial: .thinMaterial
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.42), tint.opacity(hovering ? 0.24 : 0.12), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .overlay {
                if floating {
                    RoundedRectangle(cornerRadius: 17).strokeBorder(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            .shadow(color: hovering ? tint.opacity(0.10) : .clear, radius: 12, y: 5)
            .scaleEffect(hovering && !reduceMotion ? 1.004 : 1, anchor: .center)
            .onHover { value in
                withAnimation(reduceMotion ? nil : DailyTaskMotion.hover) { hovering = value }
            }
            .modifier(DailyTaskDrag(id: item.id, enabled: canReorder, targeted: targeted,
                                    changed: dragChanged, ended: dragEnded))
            .padding(.bottom, isLast ? 0 : 12)
        }
    }
}

private struct CompletedTaskRow: View {
    var task: ScheduledTask
    var course: Course?
    var undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.status == .missed ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(task.status == .missed ? Color.orange : Color.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text(course?.name ?? "已删除课程").fontWeight(.semibold)
                if let lessonName = task.lessonName, !lessonName.isEmpty {
                    Text(lessonName).font(.system(size: 18, weight: .semibold))
                }
                Text(statusLabel(task)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("撤销", action: undo).buttonStyle(.borderless)
        }
        .padding(14)
        .plannerSurface(radius: 14, material: .thinMaterial, shadow: false)
    }
}

struct WeeklyBarSegment: Identifiable, Equatable {
    let dayIndex: Int
    let dayLabel: String
    let courseName: String
    let minutes: Int
    var id: String { "\(dayIndex)-\(courseName)" }
}

/// Swift Charts traps unless the foreground-style scale domain covers every
/// value present in the data. Truncating the domain to a fixed legend size
/// crashed the app as soon as a fifth course had work in the same week, so the
/// domain is always derived from the full data set.
enum WeeklyChartSeries {
    static func names(in segments: [WeeklyBarSegment]) -> [String] {
        var seen = Set<String>()
        return segments.map(\.courseName).filter { seen.insert($0).inserted }
    }
}

private struct WeeklyStudyChart: View {
    var selectedDay: Date
    var tasks: [ScheduledTask]
    var courses: [Course]
    @State private var appeared = false

    private let calendar = Calendar.current
    private let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    private var weekStart: Date {
        let day = calendar.startOfDay(for: selectedDay)
        let offset = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day)!
    }

    private var segments: [WeeklyBarSegment] {
        let weekStart = self.weekStart
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        var grouped: [String: Int] = [:]
        for task in tasks where task.start >= weekStart && task.start < end {
            guard let course = courses.first(where: { $0.id == task.courseID }) else { continue }
            let distance = calendar.dateComponents(
                [.day],
                from: weekStart,
                to: calendar.startOfDay(for: task.start)
            ).day ?? 0
            guard (0..<7).contains(distance) else { continue }
            grouped["\(distance)|\(course.name)", default: 0] += task.durationMinutes
        }
        return grouped.map { key, value in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let day = Int(parts[0]) ?? 0
            return WeeklyBarSegment(
                dayIndex: day,
                dayLabel: dayNames[day],
                courseName: parts[1],
                minutes: value
            )
        }
        .sorted { $0.dayIndex == $1.dayIndex ? $0.courseName < $1.courseName : $0.dayIndex < $1.dayIndex }
    }

    var body: some View {
        // Each aggregation runs once per render, rather than once per chart/legend property.
        let segments = self.segments
        let seriesNames = WeeklyChartSeries.names(in: segments)
        let seriesColors = seriesNames.map { name in
            courseColor(courses.first { $0.name == name }?.color ?? "blue")
        }
        let names = Set(seriesNames)
        let legendCourses = Array(courses.filter { names.contains($0.name) }.prefix(4))
        let legendOverflow = max(0, seriesNames.count - legendCourses.count)
        let totalMinutes = segments.reduce(0) { $0 + $1.minutes }
        VStack(alignment: .leading, spacing: 16) {
            PlannerSectionTitle(title: "本周学习", detail: "总计 \(hours(totalMinutes))")

            if segments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(PlannerTheme.accent.opacity(0.75))
                    Text("本周还没有学习安排")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart(segments) { segment in
                    BarMark(
                        x: .value("小时", appeared ? Double(segment.minutes) / 60 : 0),
                        y: .value("日期", segment.dayLabel)
                    )
                    .foregroundStyle(by: .value("课程", segment.courseName))
                    .cornerRadius(4)
                }
                .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
                .chartLegend(.hidden)
                .chartYScale(domain: dayNames)
                .chartXAxis {
                    AxisMarks(position: .bottom) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(PlannerTheme.hairline)
                        AxisValueLabel {
                            if let value = value.as(Double.self) {
                                Text(value.formatted(.number.precision(.fractionLength(0...1))) + "h")
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 190)
                .animation(.easeOut(duration: 0.7), value: appeared)

                FlowLegend(courses: legendCourses, overflow: legendOverflow)
            }
        }
        .padding(18)
        .plannerSurface()
        .onAppear { appeared = true }
        .onChange(of: selectedDay) { _, _ in
            appeared = false
            Task { @MainActor in appeared = true }
        }
    }
}

private struct FlowLegend: View {
    var courses: [Course]
    var overflow: Int = 0

    var body: some View {
        HStack(spacing: 12) {
            ForEach(courses) { course in
                HStack(spacing: 5) {
                    Circle().fill(courseColor(course.color)).frame(width: 7, height: 7)
                    Text(course.name).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if overflow > 0 {
                Text("另有 \(overflow) 门").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CourseProgressPanel: View {
    var courses: [Course]
    var demands: [UUID: CourseDemand]
    var studyLoad: StudyLoadAssessment?
    var completedMinutes: (Course) -> Int
    var edit: (Course) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PlannerSectionTitle(title: "课程进度", detail: "\(courses.count) 门")

            if let studyLoad {
                StudyLoadWarning(load: studyLoad)
            }

            if courses.isEmpty {
                Text("添加课程后，可在这里查看进度和每日学习建议。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
            } else {
                ForEach(courses.prefix(5)) { course in
                    Button { edit(course) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(course.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(hours(completedMinutes(course))) / \(hours(course.totalMinutes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.07))
                                    Capsule()
                                        .fill(courseColor(course.color).gradient)
                                        .frame(width: proxy.size.width * progress(course))
                                }
                            }
                            .frame(height: 7)

                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(dailyRecommendation(course))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text("\(Int(progress(course) * 100))%")
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.caption2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .plannerSurface()
    }

    private func progress(_ course: Course) -> Double {
        min(1, Double(completedMinutes(course)) / Double(max(1, course.totalMinutes)))
    }

    private func dailyRecommendation(_ course: Course) -> String {
        guard completedMinutes(course) < course.totalMinutes else { return "已完成学习目标" }
        guard course.autoScheduleEnabled else { return "已暂停自动排程" }
        guard let demand = demands[course.id] else { return "暂无每日学习建议" }
        guard demand.remainingMinutes > 0 else { return "剩余学习量已安排在进行中的任务" }
        guard demand.learnableDays > 0 else { return "无可用学习日，请调整时间或截止日期" }
        return "推荐每日学习 \(hours(Int(ceil(demand.averageMinutesPerDay))))"
    }
}

private struct CourseListRow: View {
    var course: Course
    var completed: Int
    var minimumBlock: Int
    var edit: () -> Void
    var reorder: (() -> Void)?
    @State private var hovering = false

    private var progress: Double { min(1, Double(completed) / Double(max(1, course.totalMinutes))) }

    var body: some View {
        HStack(spacing: 17) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(courseColor(course.color).opacity(0.12))
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(courseColor(course.color))
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 6) {
                Text(course.name).font(.system(size: 18, weight: .bold))
                Text("\(course.type.rawValue) · 截止 \(course.deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("已学 \(hours(completed)) / 共 \(hours(course.totalMinutes)) · \(course.type == .lessonBasedRecorded && (course.mergedSources != nil || course.webCourse != nil || course.manualLessons != nil) ? "按课节排程" : "最小时间块 \(minimumBlock) 分钟")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 8) {
                Text(course.autoScheduleEnabled ? "自动排程" : "已暂停")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(course.autoScheduleEnabled ? Color.teal : Color.secondary)
                ProgressView(value: progress)
                    .tint(courseColor(course.color))
                    .frame(width: 130)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 6) {
                if let reorder { Button("调整课节顺序", action: reorder).buttonStyle(SoftButtonStyle()) }
                Button("编辑", action: edit).buttonStyle(SoftButtonStyle())
            }
        }
        .padding(18)
        .plannerSurface(radius: 18, material: .thinMaterial, shadow: hovering)
        .scaleEffect(hovering ? 1.003 : 1)
        .onHover { value in withAnimation(.easeOut(duration: 0.18)) { hovering = value } }
    }
}

private struct FixedEventListRow: View {
    var event: FixedEvent
    var edit: (() -> Void)?

    var body: some View {
        HStack(spacing: 17) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(courseColor(event.color).opacity(0.12))
                Image(systemName: event.isFloating ? "arrow.left.arrow.right" : "calendar.badge.clock")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(courseColor(event.color))
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 6) {
                Text(event.title).font(.headline)
                if event.isFloating {
                    Label("时段内浮动 · 固定占用 " + hours(event.occupiedMinutes), systemImage: "arrow.left.arrow.right")
                        .font(.caption).foregroundStyle(courseColor(event.color))
                    FloatingWindowIndicator(occupied: event.occupiedMinutes, window: event.endMinute - event.startMinute, tint: courseColor(event.color))
                        .frame(maxWidth: 320)
                }
                Text("\(clockTime(event.startMinute))–\(clockTime(event.endMinute)) · \(repeatLabel(event.weekdays))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(event.startDate.formatted(date: .abbreviated, time: .omitted)) 至 \(event.endDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let edit {
                Button("编辑", action: edit).buttonStyle(SoftButtonStyle())
            } else {
                Text("历史课表").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .plannerSurface(radius: 18, material: .thinMaterial, shadow: false)
    }
}

func statusLabel(_ task: ScheduledTask) -> String {
    switch task.status {
    case .completed: return task.confirmedAt.map { $0 < task.planningStart } == true ? "已提前完成" : "已完成"
    case .partial: return "已完成 \(hours(task.completedMinutes)) · 余量已重排"
    case .missed, .rescheduled: return "未完成 · 已重新排程"
    case .planned: return "已计划"
    case .future: return "未来任务"
    }
}

let weekdayNames = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]

func repeatLabel(_ days: Set<Int>) -> String {
    days.isEmpty
        ? "单次事项"
        : [2, 3, 4, 5, 6, 7, 1]
            .filter { days.contains($0) }
            .map { weekdayNames[$0]! }
            .joined(separator: "、")
}

struct MonthCalendar: View {
    @Binding var selectedDay: Date
    @Binding var month: Date
    var tasks: [ScheduledTask]
    var fixed: [FixedEvent]
    var select: () -> Void
    private let calendar = Calendar.current

    private var cells: [Date?] {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        return Array(repeating: nil, count: offset) + calendar.range(of: .day, in: .month, for: first)!.map {
            calendar.date(byAdding: .day, value: $0 - 1, to: first)
        }
    }

    var body: some View {
        let cells = self.cells
        let interval = calendar.dateInterval(of: .month, for: month)!
        let occupiedDays = Set(tasks.lazy.filter { $0.start >= interval.start && $0.start < interval.end }
            .map { calendar.startOfDay(for: $0.start) })
        VStack(spacing: 12) {
            HStack {
                Text(month.formatted(.dateTime.year().month(.wide)))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    withAnimation(PlannerTheme.spring) {
                        month = calendar.date(byAdding: .month, value: -1, to: month)!
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                Button {
                    withAnimation(PlannerTheme.spring) {
                        month = calendar.date(byAdding: .month, value: 1, to: month)!
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 5) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(height: 19)
                }

                ForEach(cells.indices, id: \.self) { index in
                    if let day = cells[index] {
                        let chosen = calendar.isDate(day, inSameDayAs: selectedDay)
                        let occupied = occupiedDays.contains(day) ||
                            fixed.contains { $0.occurs(on: day, calendar: calendar) }

                        Button {
                            withAnimation(PlannerTheme.spring) {
                                selectedDay = day
                                select()
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(calendar.component(.day, from: day))")
                                    .font(.system(size: 11.5, weight: chosen || calendar.isDateInToday(day) ? .bold : .regular))
                                Circle()
                                    .fill(occupied ? (chosen ? Color.white : PlannerTheme.accent.opacity(0.65)) : .clear)
                                    .frame(width: 3, height: 3)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                chosen ? PlannerTheme.accent : calendar.isDateInToday(day) ? PlannerTheme.accent.opacity(0.09) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .foregroundStyle(chosen ? Color.white : Color.primary.opacity(0.82))
                            .shadow(color: chosen ? PlannerTheme.accent.opacity(0.25) : .clear, radius: 6, y: 3)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    } else {
                        Color.clear.frame(height: 28)
                    }
                }
            }
        }
    }
}

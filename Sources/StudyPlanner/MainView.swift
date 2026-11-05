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
    case websiteSource(UUID)
    case course(Course), lessonOrder(Course), fixed(FixedEvent), completion(ScheduledTask), review, risks, mergeCourses
    case restoreOccurrence(FixedEvent, Date, [FixedEventConflict])

    var id: String {
        switch self {
        case .scheduleSearch: "scheduleSearch"
        case .websiteSource(let id): "websiteSource\(id)"
        case .course(let course): "course\(course.id)"
        case .lessonOrder(let course): "lessonOrder\(course.id)"
        case .fixed(let event): "fixed\(event.id)"
        case .restoreOccurrence(let event, let day, _): "restore\(event.id)-\(day.timeIntervalSince1970)"
        case .completion(let task): "task\(task.id)"
        case .review: "review"
        case .risks: "risks"
        case .mergeCourses: "mergeCourses"
        }
    }
}

struct MainView: View {
    @Bindable var store: PlannerStore
    @State private var layout = PlannerWindowLayout(width: PlannerTheme.referenceWindowWidth)
    @State private var page = Page.calendar
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var month = Date()
    @State private var sheet: EditorSheet?
    @State private var showingAddMenu = false
    @State private var showingNavigation = false
    @State private var showingInsights = false
    @State private var dismissedDeletion: UUID?
    @State private var showingCompletedFixedEvents = false
    @State private var fixedQuery = ""
    @State private var fixedWeekday = 0
    @State private var matchingFixedEvents: [FixedEvent] = []
    @State private var displayedFixedInput: FixedCatalogInput?
    @State private var courseQuery = ""
    @State private var courseScope = CourseCatalogScope.all
    @State private var courseOrder = CourseCatalogOrder.deadline
    @State private var matchingCourses: [Course] = []
    @State private var displayedCourseInput: CourseCatalogInput?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct CourseCatalogInput: Equatable, Sendable {
        var query: String
        var scope: CourseCatalogScope
        var order: CourseCatalogOrder
        var courses: [Course]
        var timeZone: TimeZone
    }
    private struct FixedCatalogInput: Equatable, Sendable {
        var query: String
        var weekday: Int
        var events: [FixedEvent]
        var calendar: Calendar
    }

    var body: some View {
        windowContent(layout)
        // Observe only layout decisions, not every pixel of a live resize. The
        // parent otherwise rebuilds the agenda and both panels on each frame.
        .onGeometryChange(for: PlannerWindowLayout.self) { geometry in
            PlannerWindowLayout(width: geometry.size.width)
        } action: { newLayout in
            layout = newLayout
            if newLayout.showsSidebar { showingNavigation = false }
            if newLayout.showsInsights { showingInsights = false }
        }
        .background { PlannerGlassBackdrop() }
        // One transaction keeps the column slots, agenda and header in step.
        // Geometry still publishes only presentation changes, never animation frames.
        .animation(reduceMotion ? nil : PlannerTheme.columnTransition, value: layout)
        .animation(reduceMotion ? nil : PlannerTheme.spring, value: page)
        .animation(reduceMotion ? nil : PlannerTheme.spring, value: selectedDay)
        .onChange(of: page) { _, _ in showingNavigation = false; showingInsights = false }
        .onChange(of: sheet?.id) { _, value in
            if value != nil { showingNavigation = false; showingInsights = false }
        }
        .toolbar {
            if store.demo {
                ToolbarItem {
                    Text("示例预览 · 不保存").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $sheet, onDismiss: { store.showDailyReview = false }) { selection in
            Group {
                switch selection {
                case .websiteSource(let id): WebsiteCourseSourceSheet(store: store, courseID: id)
                case .scheduleSearch:
                    ScheduleSearchView(tasks: store.state.tasks, courses: store.state.courses) { date in
                        selectedDay = Calendar.current.startOfDay(for: date)
                        month = selectedDay
                        page = .calendar
                        sheet = nil
                    }
                case .mergeCourses: CourseMergeEditor(store: store)
                case .course(let course): CourseEditor(store: store, course: course)
                case .lessonOrder(let course): LessonOrderEditor(store: store, course: course)
                case .fixed(let event): FixedEventEditor(store: store, event: event)
                case .restoreOccurrence(let event, let day, let conflicts):
                    FixedOccurrenceConflictReview(store: store, event: event, day: day, conflicts: conflicts)
                case .completion(let task): CompletionEditor(store: store, task: task)
                case .review: DailyReviewView(store: store)
                case .risks:
                    RiskView(
                        store: store,
                        adjustSettings: { sheet = nil; page = .settings },
                        editCourse: { sheet = .course($0) },
                        reviewEvents: { day in
                            selectedDay = day; month = day; page = .calendar; sheet = nil
                        }
                    )
                }
            }.disabled(store.orderSaveBusy)
                .overlay(alignment: .bottom) {
                    if store.orderSaveBusy { Text(store.saveStatus).padding(10).background(.regularMaterial, in: Capsule()).padding(8) }
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
            store.startCloudMonitoring()
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
                store.pollCloudIfDue()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .plannerDidCommit).receive(on: RunLoop.main)) { _ in
            store.requestCloudSync()
        }
    }

    private func windowContent(_ layout: PlannerWindowLayout) -> some View {
        HStack(spacing: 0) {
            PlannerCollapsibleColumn(isExpanded: layout.showsSidebar,
                                     width: PlannerWindowLayout.sidebarWidth, edge: .leading) { sidebar }
            VStack(spacing: 0) {
                header(layout)
                if store.orderSaveBusy {
                    HStack { ProgressView().controlSize(.small); Text(store.saveStatus); Spacer() }
                        .padding(.horizontal, 24).padding(.vertical, 8)
                        .accessibilityIdentifier("localSaveProgress")
                }
                if let deleted = store.latestDeletedCourse, deleted.id != dismissedDeletion {
                    HStack {
                        Text("已删除「\(deleted.deletedCourseName ?? "课程")」")
                        Button("撤销删除") { Task { _ = await store.undoCourseDeletion(deleted.id) } }
                            .disabled(store.orderSaveBusy)
                        Spacer()
                        Button("收起", systemImage: "xmark") { dismissedDeletion = deleted.id }
                            .labelStyle(.iconOnly).help("仍可在“数据与备份”中恢复")
                    }.padding(.horizontal, 24).padding(.vertical, 8)
                }
                if store.syncBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text("正在后台同步，可继续修改")
                            .font(.callout.weight(.medium))
                        Spacer()
                    }
                    .foregroundStyle(PlannerTheme.accent)
                    .padding(.horizontal, PlannerTheme.pagePadding)
                    .padding(.vertical, 10)
                    .background(PlannerTheme.accent.opacity(0.07))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("syncProgress")
                }
                Group {
                    if !store.isReady {
                        ContentUnavailableView(
                            "无法打开数据库",
                            systemImage: "externaldrive.badge.exclamationmark",
                            description: Text("请关闭软件并检查本地数据文件的访问权限。")
                        )
                    } else {
                        pageContent(layout)
                            .environment(\.plannerCompactContent, layout.compactContent)
                            .id(page)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func pageContent(_ layout: PlannerWindowLayout) -> some View {
        switch page {
        case .calendar:
            HStack(spacing: 0) {
                agenda.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.plannerCompactContent, layout.compactAgenda)
                PlannerCollapsibleColumn(isExpanded: layout.showsInsights,
                                         width: PlannerWindowLayout.insightsWidth, edge: .trailing) { insightsPanel }
            }
        case .courses: courseList
        case .fixed: fixedList
        case .settings: SettingsView(store: store)
        }
    }

    private var sidebar: some View {
        CalendarNavigationView(store: store, page: $page, selectedDay: $selectedDay,
                               month: $month, sheet: $sheet, showingNavigation: $showingNavigation)
    }

    private func header(_ layout: PlannerWindowLayout) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                headerTitle.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                headerActions(layout)
            }
            VStack(alignment: .leading, spacing: 14) {
                headerTitle
                headerActions(layout)
            }
        }
        .padding(.horizontal, PlannerTheme.pagePadding)
        .padding(.top, 21)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PlannerTheme.hairline).frame(height: 1)
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pageTitle)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headerActions(_ layout: PlannerWindowLayout) -> some View {
        HStack(spacing: 10) {
            if !layout.showsSidebar {
                Button { showingNavigation.toggle() } label: {
                    Label("导航与月历", systemImage: "sidebar.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(CircularIconButtonStyle())
                .help("展开导航与月历")
                .accessibilityIdentifier("showNavigation")
                .popover(isPresented: $showingNavigation, arrowEdge: .bottom) {
                    sidebar.frame(width: 264, height: 620)
                }
            }
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
                    CalendarDateJumpButton(selectedDay: $selectedDay, month: $month)
                    Button("今天") {
                        withAnimation(reduceMotion ? nil : PlannerTheme.spring) {
                            selectedDay = Calendar.current.startOfDay(for: Date())
                            month = selectedDay
                        }
                    }
                    .buttonStyle(SoftButtonStyle())
                    .focusEffectDisabled()
                }
                .fixedSize()
            }

            Spacer(minLength: 0)

            if !store.result.risks.isEmpty || !store.result.diagnostics.isEmpty {
                Button { sheet = .risks } label: {
                    Label("查看排程情况", systemImage: "exclamationmark.triangle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SoftButtonStyle())
                .focusEffectDisabled()
                .foregroundStyle(.orange)
                .help("查看排程情况")
            }

            if page == .calendar && !layout.showsInsights {
                Button { showingInsights.toggle() } label: {
                    Label("学习概览", systemImage: "sidebar.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(CircularIconButtonStyle())
                .help("展开学习概览、继续上课与周统计")
                .accessibilityIdentifier("showInsights")
                .popover(isPresented: $showingInsights, arrowEdge: .bottom) {
                    insightsPanel.frame(width: PlannerWindowLayout.insightsWidth, height: 600)
                }
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
                        title: "可调度课程",
                        systemImage: "book.closed.fill"
                    ) {
                        showingAddMenu = false
                        newCourse()
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

    private var agenda: some View {
        CalendarAgendaView(store: store, selectedDay: $selectedDay, month: $month, sheet: $sheet)
    }

    private var insightsPanel: some View {
        CalendarInsightsView(store: store, selectedDay: $selectedDay, month: $month, sheet: $sheet)
    }

    private var courseList: some View {
        let input = CourseCatalogInput(query: courseQuery, scope: courseScope, order: courseOrder, courses: store.state.courses, timeZone: .current)
        let total = input.courses.filter { !$0.isArchived }.count
        let ready = displayedCourseInput == input
        let visible = ready ? matchingCourses : []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                CompressedScheduleCard(controller: store.compressedPlan) {
                    store.compressedPlan.recalculate(state: store.state)
                }
                PlannerSectionTitle(title: "可调度课程", detail: ready ? "显示 \(visible.count) / \(total) 门" : "\(total) 门")
                HStack {
                    Button("合并课程", systemImage: "arrow.triangle.merge") { sheet = .mergeCourses }
                        .disabled(total < 2 || store.orderSaveBusy)
                    Button("添加课程", systemImage: "plus") { newCourse() }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                        .disabled(store.orderSaveBusy)
                }

                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索名称、备注或截止日期（YYYY-MM-DD）", text: $courseQuery)
                            .textFieldStyle(.plain).accessibilityIdentifier("courseCatalogSearch")
                    }.padding(10).plannerSurface(radius: 10, shadow: false)
                    Picker("排程状态", selection: $courseScope) {
                        ForEach(CourseCatalogScope.allCases) { value in Text(value.rawValue).tag(value) }
                    }.frame(width: 150)
                    Picker("列表排序", selection: $courseOrder) {
                        ForEach(CourseCatalogOrder.allCases) { value in Text(value.rawValue).tag(value) }
                    }.frame(width: 170)
                    if !courseQuery.isEmpty || courseScope != .all {
                        Button("清除筛选") { courseQuery = ""; courseScope = .all }
                    }
                }
                Text("可用空格组合关键词；优先级按高到低，同级按截止日期。筛选和排序不会修改课程或日程。")
                    .font(.caption).foregroundStyle(.secondary)
                if !ready { ProgressView("正在查找课程…") }

                Label("赶进度？直接调整下方「每日加量」，可分别设置多门课。1.5 倍多学 50%，2 倍多学一倍；选择后自动重排。", systemImage: "bolt.fill")
                    .font(.callout).foregroundStyle(.secondary)

                ForEach(visible) { course in
                    CourseListRow(
                        course: course,
                        completed: store.state.completedMinutes(for: course),
                        minimumBlock: course.minimumBlockMinutes == 0
                            ? store.state.settings.minimumScheduleUnit
                            : course.minimumBlockMinutes,
                        dailyMinutes: store.result.demands[course.id]?.averageMinutesPerDay,
                        setDailyWeight: { weight in Task { await store.setDailyWeight(weight, for: course.id) } },
                        edit: { sheet = .course(course) },
                        reorder: store.state.lessonWorkItems(for: course).count > 1
                            ? { sheet = .lessonOrder(course) } : nil,
                        websiteSource: CourseWebsite.identify(course.webCourse) != nil && course.mergedSources == nil
                            ? { sheet = .websiteSource(course.id) } : nil,
                        websiteStatus: store.websiteUpdater.sources[course.id].map { $0.needsAttention ? "网站更新待处理" : ($0.enabled ? "网站自动更新已开启" : "") }
                    ).disabled(store.orderSaveBusy)
                }

                if total == 0 {
                    ContentUnavailableView(
                        "还没有学习课程",
                        systemImage: "books.vertical",
                        description: Text("录入总学习量和截止日期，即可生成计划。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else if ready && visible.isEmpty {
                    ContentUnavailableView("没有匹配的课程", systemImage: "magnifyingglass",
                                           description: Text("试试其他关键词或排程状态，也可清除筛选查看全部课程。"))
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(PlannerTheme.pagePadding)
        }
        .scrollIndicators(.hidden)
        .environment(\.plannerScrollingContent, true)
        .task(id: input) {
            guard displayedCourseInput != input else { return }
            displayedCourseInput = nil; matchingCourses = []
            if !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                CourseCatalogSearch.matches(query: input.query, courses: input.courses,
                                            scope: input.scope, order: input.order, timeZone: input.timeZone)
            }.value
            guard !Task.isCancelled else { return }
            matchingCourses = result; displayedCourseInput = input
        }
    }

    private var fixedList: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            fixedList(at: context.date)
        }
    }

    private func fixedList(at now: Date) -> some View {
        let input = FixedCatalogInput(query: fixedQuery, weekday: fixedWeekday, events: store.state.fixedEvents, calendar: .current)
        let ready = displayedFixedInput == input
        let filtering = !fixedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fixedWeekday != 0
        let events = ready ? matchingFixedEvents : []
        let completed = events.filter { $0.hasEnded(at: now) }
        let completedIDs = Set(completed.map(\.id))
        let active = events.filter { !completedIDs.contains($0.id) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    PlannerSectionTitle(title: "周期课表与固定事项", detail: ready ? "\(filtering ? "匹配：" : "")未完成 \(active.count) 项 · 已完成 \(completed.count) 项" : "正在筛选事项…")
                    Button("添加固定事项", systemImage: "plus") { newFixed() }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                }

                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索名称、备注或起止日期", text: $fixedQuery)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("fixedEventSearch")
                    }
                    .padding(10).plannerSurface(radius: 10, shadow: false)
                    Picker("星期", selection: $fixedWeekday) {
                        Text("全部星期").tag(0)
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                            Text(weekdayNames[day] ?? "").tag(day)
                        }
                    }.frame(width: 150)
                    if filtering {
                        Button("清除筛选") { fixedQuery = ""; fixedWeekday = 0 }
                    }
                }
                Text("可组合名称、备注和日期（YYYY-MM-DD）关键词。星期按原定规则筛选；单次事项按发生日期，包含临时跳过的日期。")
                    .font(.caption).foregroundStyle(.secondary)

                FixedEventRecognitionCard { event in
                    sheet = .fixed(event)
                }
                if !ready { ProgressView("正在读取固定事项…").controlSize(.small) }

                ForEach(active) { event in
                    FixedEventListRow(
                        event: event,
                        referenceDate: now,
                        showCalendar: showFixedDay,
                        edit: { sheet = .fixed(event) },
                        duplicate: { duplicateFixed(event) },
                        delete: { reviewed in Task { await store.deleteEvent(reviewed) } }
                    )
                }

                if !completed.isEmpty {
                    DisclosureGroup(isExpanded: $showingCompletedFixedEvents) {
                        VStack(spacing: 12) {
                            ForEach(completed.reversed()) { event in
                                FixedEventListRow(
                                    event: event,
                                    referenceDate: now,
                                    showCalendar: showFixedDay,
                                    edit: nil,
                                    duplicate: { duplicateFixed(event) },
                                    delete: { reviewed in Task { await store.deleteEvent(reviewed) } }
                                )
                            }
                        }.padding(.top, 12)
                    } label: {
                        Label("已完成（\(completed.count)）", systemImage: "checkmark.circle")
                            .font(.headline)
                    }
                    .padding(18)
                    .plannerSurface(radius: 18, material: .thinMaterial, shadow: false)
                    .accessibilityIdentifier("completedFixedEvents")
                }

                if store.state.fixedEvents.isEmpty {
                    ContentUnavailableView(
                        "添加你的固定课表",
                        systemImage: "calendar.badge.plus",
                        description: Text("学校课程、补习班、考试或休息时间。支持每周重复和学期起止日期。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else if ready && events.isEmpty {
                    ContentUnavailableView("没有匹配的固定事项", systemImage: "magnifyingglass",
                                           description: Text("试试其他关键词或星期，或清除筛选查看全部事项。"))
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(PlannerTheme.pagePadding)
        }
        .scrollIndicators(.hidden)
        .disabled(store.orderSaveBusy)
        .onChange(of: fixedQuery) { _, _ in
            if filtering { showingCompletedFixedEvents = true }
        }
        .onChange(of: fixedWeekday) { _, _ in
            if filtering { showingCompletedFixedEvents = true }
        }
        .task(id: input) {
            guard displayedFixedInput != input else { return }
            displayedFixedInput = nil; matchingFixedEvents = []
            if !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                let ordered = input.events.sorted {
                    $0.startDate == $1.startDate ? $0.id.uuidString < $1.id.uuidString : $0.startDate < $1.startDate
                }
                return FixedEventFilter.matching(ordered, query: input.query, weekday: input.weekday, calendar: input.calendar)
            }.value
            guard !Task.isCancelled else { return }
            matchingFixedEvents = result; displayedFixedInput = input
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

    private func duplicateFixed(_ event: FixedEvent) {
        do { sheet = .fixed(try event.duplicate(startingOn: selectedDay)) }
        catch { store.errorMessage = error.localizedDescription }
    }

    private func showFixedDay(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        month = selectedDay
        page = .calendar
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
}

private struct CalendarNavigationView: View {
    @Bindable var store: PlannerStore
    @Binding var page: Page
    @Binding var selectedDay: Date
    @Binding var month: Date
    @Binding var sheet: EditorSheet?
    @Binding var showingNavigation: Bool
    @Namespace private var navigationSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reviewTasks = store.reviewTasks
        return VStack(alignment: .leading, spacing: 0) {
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
                        showingNavigation = false
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
                courses: store.state.courses,
                fixed: store.state.fixedEvents
            ) {
                showingNavigation = false
                withAnimation(reduceMotion ? nil : PlannerTheme.spring) { page = .calendar }
            }
            .padding(.horizontal, 16)

            if !reviewTasks.isEmpty {
                Button { sheet = .review } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("学习完成确认").fontWeight(.semibold)
                            Text("\(reviewTasks.count) 项计划待确认").font(.caption)
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

    private func icon(_ page: Page) -> String {
        switch page {
        case .calendar: "calendar"
        case .courses: "books.vertical"
        case .fixed: "calendar.badge.clock"
        case .settings: "gearshape"
        }
    }
}

// Keep data-dependent work below a View boundary. Opening or dismissing a
// secondary panel must not rebuild the selected day's task snapshot.
private struct CalendarAgendaView: View {
    @Bindable var store: PlannerStore
    @Binding var selectedDay: Date
    @Binding var month: Date
    @Binding var sheet: EditorSheet?

    private var canChangeDayEvents: Bool {
        Calendar.current.startOfDay(for: selectedDay) >= Calendar.current.startOfDay(for: Date()) &&
        store.isReady
    }

    var body: some View {
        let snapshot = CalendarDaySnapshot(state: store.state, day: selectedDay)
        let dayTasks = snapshot.tasks, dayEvents = snapshot.events, skippedDayEvents = snapshot.skipped
        let items = timelineItems(for: snapshot)
        let floatingDuration = snapshot.floatingMinutes.map(hours) ?? "合计超出范围"
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Spacer()
                        Text("⌘F").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .plannerSurface(radius: 14, material: .thinMaterial, shadow: false)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                summaryBand(snapshot)
                if dayEvents.contains(where: \.isFloating) {
                    Label("浮动事项已预留 " + floatingDuration + "；虚线学习卡片显示按当前顺序预估的起止时间，调整顺序后更新。", systemImage: "arrow.left.arrow.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Calendar.current.isDateInToday(selectedDay)
                             ? (store.state.settings.actualStudyStart(on: Date()) == nil ? "今天的安排" : "新课表 · 今天")
                             : "当天的安排")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text("\(items.count) 项任务 · 长按课程可拖动交换")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    DayAgendaCopyButton(day: selectedDay, state: store.state)
                        .fixedSize()
                }

                if dayTasks.isEmpty && dayEvents.isEmpty {
                    emptyAgenda
                } else {
                    DailyTaskTimeline(
                        store: store, items: items, canEdit: canChangeDayEvents,
                        editTask: { sheet = .completion($0) },
                        editEvent: { sheet = .fixed($0) },
                        skipEvent: { event in Task { await store.setEventSkipped(event, on: selectedDay, skipped: true) } }
                    )
                    .id(selectedDay)

                    if dayTasks.contains(where: { !$0.isUnconfirmed }) {
                        PlannerSectionTitle(title: "完成记录", detail: "不再占用时间")
                            .padding(.top, 2)
                        VStack(spacing: 10) {
                            ForEach(dayTasks.filter { !$0.isUnconfirmed }) { task in
                                CompletedTaskRow(
                                    task: task,
                                    course: snapshot.course(task.courseID),
                                    undo: { Task { _ = await store.undoConfirmation(task) } }
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
                                let day = selectedDay
                                Task {
                                    if !(await store.restoreEventOccurrence(event, on: day)),
                                       let conflicts = store.pendingEventConflicts, !conflicts.isEmpty {
                                        sheet = .restoreOccurrence(event, day, conflicts)
                                    }
                                }
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
        .environment(\.plannerScrollingContent, true)
    }

    private func summaryBand(_ snapshot: CalendarDaySnapshot) -> some View {
        let confirmed = ConfirmedStudySummary(state: store.state, day: selectedDay)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                SummaryMetric(
                    title: "待学计划",
                    value: snapshot.plannedMinutes.map(studyDuration) ?? "合计超出范围",
                    icon: "book.closed.fill",
                    color: PlannerTheme.accent
                )
                metricDivider
                SummaryMetric(
                    title: "实际已学",
                    value: confirmed.value,
                    icon: "checkmark",
                    color: .teal
                )
                metricDivider
                SummaryMetric(
                    title: "固定事项",
                    value: "\(snapshot.events.count) 项",
                    icon: "calendar",
                    color: .purple
                )
            }
            .padding(.vertical, 15)
            .plannerSurface(radius: 18, material: .thinMaterial)
            Text(confirmed.note)
                .font(.caption)
                .foregroundStyle(confirmed.ambiguousRecordCount > 0 || confirmed.minutes == nil ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                Button("载入示例，体验自动排程") { Task { await store.loadExample() } }.buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }

    private func timelineItems(for snapshot: CalendarDaySnapshot) -> [TimelineItem] {
        (snapshot.tasks.filter(\.isUnconfirmed).map {
            TimelineItem(id: $0.id, start: $0.start, end: $0.end, task: $0)
        } + snapshot.events.map {
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

    private func newCourse() {
        sheet = .course(Course(
            name: "",
            totalMinutes: 600,
            startDate: Calendar.current.startOfDay(for: Date()),
            deadline: Calendar.current.date(byAdding: .day, value: 30, to: Date())!,
            minimumBlockMinutes: 0
        ))
    }
}

private struct CalendarInsightsView: View {
    @Bindable var store: PlannerStore
    @Binding var selectedDay: Date
    @Binding var month: Date
    @Binding var sheet: EditorSheet?
    @AppStorage("dailyStudyLoadWarningMinutes") private var dailyLoadWarningMinutes = 480

    var body: some View {
        let courses = store.courses
        let firstTask = store.state.firstUnconfirmedTask(on: selectedDay)
        return ScrollView {
            // Keep the daily forecast's task mounted even below the viewport;
            // it captures today's baseline, so it must not wait for scrolling.
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    if let task = firstTask {
                        Text(task.lessonName ?? store.course(task.courseID)?.name ?? "待学习课程")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("当前所选日期的首项未确认课程 · \(studyDuration(task.durationMinutes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            if await store.continueStudying(on: selectedDay) {
                                selectedDay = Calendar.current.startOfDay(for: Date())
                                month = selectedDay
                            }
                        }
                    } label: {
                        Label("继续上课", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.isReady || store.orderSaveBusy ||
                        Calendar.current.startOfDay(for: selectedDay) < Calendar.current.startOfDay(for: Date()) ||
                        firstTask == nil)
                    .help("把当前查看课表中最上方的未确认课程移到现在（向上取整到分钟），保留该板块时长并重排后续课程；固定事项和已确认进度保留，空档不足时保留原课表")
                    ImmediateStudyMenu(store: store) {
                        selectedDay = Calendar.current.startOfDay(for: Date())
                        month = selectedDay
                    }
                }
                .padding(14).plannerSurface()

                if let health = ScheduleHealthAnalyzer().assess(state: store.state, result: store.result, now: Date(), heavyDayMinutes: dailyLoadWarningMinutes) {
                    ScheduleHealthWarning(health: health, adjustments: store.result.adjustments, showDetails: { sheet = .risks })
                }

                CourseProgressPanel(
                    courses: courses,
                    demands: store.result.demands,
                    completedMinutes: { store.state.completedMinutes(for: $0) },
                    edit: { sheet = .course($0) }
                )

                WeeklyStudyChart(
                    selectedDay: $selectedDay,
                    month: $month,
                    state: store.state,
                    tasks: store.state.tasks,
                    courses: courses
                )

                if !courses.isEmpty { DailyConsequencesView(store: store) }

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
        .environment(\.plannerScrollingContent, true)
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
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            .font(.caption)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    isSupervising: item.task.map { store.playbackSupervisor.isSupervising($0) } ?? false,
                    isLast: index == items.count - 1,
                    confirm: { task in
                        if Calendar.current.startOfDay(for: task.start) < Calendar.current.startOfDay(for: Date()) {
                            editTask(task)
                        } else { Task { _ = await store.confirm(task, minutes: task.durationMinutes) } }
                    },
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
    var isSupervising: Bool
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
    @AppStorage("timelineTimeFontSize") private var timelineTimeFontSize = 17.0
    @Environment(\.plannerCompactContent) private var compact

    private var floating: Bool { item.event?.isFloating == true || item.task?.isFloating == true }

    /// The stored preference can come from an older build or a hand-edited plist,
    /// so an unusable value falls back to the default instead of shrinking the
    /// timeline row to nothing.
    private var effectiveTimeFontSize: Double {
        guard timelineTimeFontSize.isFinite else { return 17 }
        return min(max(timelineTimeFontSize, 14), 24)
    }

    private var tint: Color {
        if item.task != nil { return courseColor(course?.color ?? "blue") }
        return courseColor(item.event?.color ?? "orange")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 3) {
                if item.task?.isFloating == true {
                    Text("预估")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: effectiveTimeFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                if floating { Image(systemName: "arrow.up.arrow.down").font(.caption2).foregroundStyle(tint) }
                Text(item.end.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: effectiveTimeFontSize - 2, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 72, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
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

                if !compact {
                    ZStack {
                        Circle().fill(tint.opacity(0.11))
                        Image(systemName: floating ? "arrow.left.arrow.right" : (item.task == nil ? "lock.fill" : "book.closed.fill"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 38, height: 38)
                }

                let contentLayout = compact
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 13))
                contentLayout {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.task == nil ? (item.event?.title ?? "固定事项") : (course?.name ?? "已删除课程"))
                            .font(.system(size: 15, weight: .semibold))
                        if let task = item.task {
                            if isSupervising {
                                Label("正在监督中…", systemImage: "eye.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            if let lessonName = task.lessonName, !lessonName.isEmpty {
                                Text(lessonName)
                                    .font(.system(size: 18, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text([studyDuration(task.durationMinutes), task.isFloating ? "按当前顺序预估 · 顺序可调" : (task.end < Date() ? "待确认" : "可调度学习")].joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help(
                                    task.isFloating
                                        ? "完成窗口：" + task.planningStart.formatted(date: .omitted, time: .shortened) + "–" + task.planningEnd.formatted(date: .omitted, time: .shortened) + "；预估起止时间随卡片顺序更新"
                                        : "在可调度时段内学习，拖动卡片可调整先后"
                                )
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

                    if !compact { Spacer(minLength: 8) }
                    HStack(spacing: 13) {
                        if let task = item.task {
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
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            // Scrolling under a stationary pointer should only change the tint,
            // not animate the whole card's scale and shadow on every crossing.
            .onHover { hovering = $0 }
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

private struct WeeklyStudyChart: View {
    @Binding var selectedDay: Date
    @Binding var month: Date
    var state: PlannerState
    var tasks: [ScheduledTask]
    var courses: [Course]
    @State private var showingActual = false

    private let calendar = Calendar.current
    private let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    private var weekStart: Date {
        let day = calendar.startOfDay(for: selectedDay)
        let offset = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day)!
    }

    private func select(_ day: Date) {
        selectedDay = calendar.startOfDay(for: day); month = selectedDay
    }
    private func moveWeek(_ offset: Int) {
        if let date = calendar.date(byAdding: .day, value: offset * 7, to: selectedDay) { select(date) }
    }

    private var summary: WeeklyChartSeries.Summary {
        WeeklyChartSeries.summary(tasks: tasks, courses: courses, weekStart: weekStart, calendar: calendar)
    }

    var body: some View {
        // Each aggregation runs once per render, rather than once per chart/legend property.
        let actual = showingActual ? WeeklyActualStudySeries.summary(state: state, weekStart: weekStart, calendar: calendar) : nil
        let summary = actual?.chart ?? self.summary, segments = summary.segments
        let seriesIDs = WeeklyChartSeries.ids(in: segments)
        let coursesByID = Dictionary(state.courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let seriesColors = seriesIDs.map { id in courseColor(coursesByID[id]?.color ?? "blue") }
        let seriesNames = Dictionary(segments.map { ($0.courseID, $0.courseName) }, uniquingKeysWith: { first, _ in first })
        let legend = seriesIDs.map { WeeklyChartLegendEntry(id: $0, name: seriesNames[$0] ?? "已删除课程", color: coursesByID[$0]?.color ?? "blue") }
        let metric = showingActual ? "已学" : "计划"
        VStack(alignment: .leading, spacing: 16) {
            PlannerSectionTitle(title: "周学习统计", detail: summary.totalMinutes.map { "\(metric) \(hours($0))" } ?? "合计超出范围")
            HStack(spacing: 6) {
                Button("上一周") { moveWeek(-1) }
                Button("本周") { select(Date()) }
                Button("下一周") { moveWeek(1) }
                Spacer(minLength: 0)
                WeeklyStudyCopyButton(day: selectedDay, state: state)
            }.buttonStyle(SoftButtonStyle(horizontalPadding: 8))
            Picker("统计内容", selection: $showingActual) {
                Text("课表计划").tag(false)
                Text("实际已学").tag(true)
            }.pickerStyle(.segmented)
            Text("\(weekStart.formatted(.dateTime.month().day()))–\(calendar.date(byAdding: .day, value: 6, to: weekStart)!.formatted(.dateTime.month().day()))")
                .font(.caption).foregroundStyle(.secondary)
            Text(showingActual ? "按实际学习日期统计，保留已归档或已删除课程的学习记录。" : "当前课程的计划时长，含已确认任务的原计划；随重排更新。")
                .font(.caption2).foregroundStyle(.secondary)
            if let actual {
                if let undated = actual.undatedMinutes {
                    if undated > 0 {
                        Text("全部历史中另有 \(studyDuration(undated)) 无法确定学习日期，未计入本周；原进度与记录保留。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("日期不明的历史记录无法合计，未计入本周；原进度与记录保留。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if summary.totalMinutes == nil {
                Label("本周\(metric)时长无法合计，请核对记录；原记录已保留。", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if segments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(PlannerTheme.accent.opacity(0.75))
                    Text(showingActual ? "本周还没有可归属日期的已学记录" : "本周还没有学习安排")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart(segments) { segment in
                    BarMark(
                        x: .value("小时", Double(segment.minutes) / 60),
                        y: .value("日期", segment.dayLabel)
                    )
                    .foregroundStyle(by: .value("课程", segment.courseID.uuidString))
                    .cornerRadius(4)
                    .accessibilityLabel("\(segment.dayLabel)，\(segment.courseName)")
                    .accessibilityValue("\(metric) \(studyDuration(segment.minutes))")
                }
                .chartForegroundStyleScale(domain: seriesIDs.map(\.uuidString), range: seriesColors)
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

                FlowLegend(entries: legend)
            }
        }
        .padding(18)
        .plannerSurface()
    }
}

private struct WeeklyChartLegendEntry: Identifiable {
    let id: UUID
    let name: String
    let color: String
}

private struct FlowLegend: View {
    var entries: [WeeklyChartLegendEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { course in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(courseColor(course.color)).frame(width: 7, height: 7).padding(.top, 4)
                    Text(course.name).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CourseProgressPanel: View {
    var courses: [Course]
    var demands: [UUID: CourseDemand]
    var completedMinutes: (Course) -> Int
    var edit: (Course) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PlannerSectionTitle(title: "课程进度", detail: "\(courses.count) 门")

            if courses.isEmpty {
                Text("添加课程后，可在这里查看进度和每日学习建议。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
            } else {
                ForEach(courses.prefix(5)) { course in
                    Button { edit(course) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(course.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Text("\(Int(progress(course) * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            Text("已学 \(hours(completedMinutes(course))) / 共 \(hours(course.totalMinutes))")
                                .font(.caption).foregroundStyle(.secondary)

                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.07))
                                    Capsule()
                                        .fill(courseColor(course.color).gradient)
                                        .frame(width: proxy.size.width * progress(course))
                                }
                            }
                            .frame(height: 7)

                            Text(dailyRecommendation(course))
                                .foregroundStyle(.secondary).font(.caption2)
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
    var dailyMinutes: Double?
    var setDailyWeight: (Double) -> Void
    var edit: () -> Void
    var reorder: (() -> Void)?
    var websiteSource: (() -> Void)?
    var websiteStatus: String?
    private var progress: Double { min(1, Double(completed) / Double(max(1, course.totalMinutes))) }

    @Environment(\.plannerCompactContent) private var compact

    var body: some View {
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(spacing: 17))
        layout {
            HStack(alignment: .top, spacing: 17) {
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
                    Text("\(course.type.displayName) · 截止 \(course.deadline.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("已学 \(hours(completed)) / 共 \(hours(course.totalMinutes)) · \(course.type == .lessonBasedRecorded && (course.mergedSources != nil || course.webCourse != nil || course.manualLessons != nil) ? "按课节排程" : "最小时间块 \(minimumBlock) 分钟")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    DailyStudyWeightPicker(weight: Binding(get: { course.dailyWeight }, set: { setDailyWeight($0) }))
                        .frame(maxWidth: 360)
                        .padding(.top, 6)
                    if let dailyMinutes, dailyMinutes > 0 {
                        Text("参考每日 \(Int(ceil(dailyMinutes * course.dailyWeight))) 分钟 · 优先安排到前面的日期")
                            .font(.caption).foregroundStyle(course.dailyWeight > 1 ? Color.orange : Color.secondary)
                    }
                    Text(course.autoScheduleEnabled ? "实际安排受可用时间与完整课节限制。" : "恢复自动排程后生效。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
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
                    if let websiteSource { Button("网站来源与更新", action: websiteSource).buttonStyle(SoftButtonStyle()) }
                    if let websiteStatus, !websiteStatus.isEmpty {
                        Text(websiteStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let reorder { Button("调整课节顺序", action: reorder).buttonStyle(SoftButtonStyle()) }
                    Button("编辑", action: edit).buttonStyle(SoftButtonStyle())
                }
            }
            .fixedSize()
        }
        .padding(18)
        .plannerSurface(radius: 18, material: .thinMaterial, shadow: false)
    }
}

private struct FixedEventListRow: View {
    var event: FixedEvent
    var referenceDate: Date
    var showCalendar: (Date) -> Void
    var edit: (() -> Void)?
    var duplicate: () -> Void
    var delete: (FixedEvent) -> Void
    @State private var deletePrompt = false
    @State private var deletionReview: FixedEvent?

    @Environment(\.plannerCompactContent) private var compact

    var body: some View {
        let calendarDay = event.calendarNavigationDay(relativeTo: referenceDate)
        let firstDate = event.startDate.formatted(date: .abbreviated, time: .omitted)
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(spacing: 17))
        layout {
            HStack(alignment: .top, spacing: 17) {
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
                    Text(event.weekdays.isEmpty ? firstDate : "\(firstDate) 至 \(event.endDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("查看日历", systemImage: "calendar") {
                    if let calendarDay { showCalendar(calendarDay) }
                }
                .disabled(calendarDay == nil)
                .help("定位今天或下一次规则日期；已结束的事项定位最后一次，临时跳过的日期仍可查看")
                if let edit {
                    Button("编辑", action: edit).buttonStyle(SoftButtonStyle())
                } else {
                    Text("已完成").font(.caption).foregroundStyle(.secondary)
                }
                Button("复制", systemImage: "doc.on.doc", action: duplicate)
                    .buttonStyle(SoftButtonStyle())
                    .accessibilityLabel("复制固定事项：\(event.title)")
                    .help("复制为新事项，核对日期后再保存")
                Button("删除", systemImage: "trash", role: .destructive) { deletionReview = event; deletePrompt = true }
                    .buttonStyle(SoftButtonStyle())
                    .help("删除这条事项的全部过去和未来课表")
            }
            .fixedSize()
        }
        .padding(18)
        .plannerSurface(radius: 18, material: .thinMaterial, shadow: false)
        .confirmationDialog("删除「\(deletionReview?.title ?? event.title)」？", isPresented: $deletePrompt, titleVisibility: .visible) {
            Button("删除事项", role: .destructive) { if let deletionReview { delete(deletionReview) } }
        } message: {
            Text("将移除这条事项的全部过去和未来课表，并重新排程。")
        }
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
    /// Nil preserves all tasks in an independent compressed-plan preview.
    var courses: [Course]? = nil
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
        let visible = courses.map { CalendarDaySnapshot.visibleTasks(tasks, courses: $0) } ?? tasks
        let occupiedDays = Set(visible.lazy.filter { $0.start >= interval.start && $0.start < interval.end }
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

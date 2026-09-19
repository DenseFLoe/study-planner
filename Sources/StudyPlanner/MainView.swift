import SwiftUI
import StudyCore

enum Page: String, CaseIterable { case calendar = "学习日历", courses = "课程管理", fixed = "固定课表", settings = "学习设置" }
enum EditorSheet: Identifiable {
    case course(Course), fixed(FixedEvent), completion(ScheduledTask), review, risks
    var id: String {
        switch self {
        case .course(let c): "course\(c.id)"
        case .fixed(let e): "fixed\(e.id)"
        case .completion(let t): "task\(t.id)"
        case .review: "review"
        case .risks: "risks"
        }
    }
}
struct MainView: View {
    @Bindable var store: PlannerStore
    @State private var page = Page.calendar
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var month = Date()
    @State private var sheet: EditorSheet?
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 242)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if !store.isReady {
                    ContentUnavailableView("无法打开数据库", systemImage: "externaldrive.badge.exclamationmark", description: Text("请关闭软件并检查本地数据文件的访问权限。"))
                } else {
                    switch page {
                    case .calendar:
                        HStack(alignment: .top, spacing: 0) {
                            agenda.frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider()
                            progressPanel.frame(width: 280)
                        }
                    case .courses: courseList
                    case .fixed: fixedList
                    case .settings: SettingsView(store: store)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                if store.demo { Text("示例预览 · 不保存").font(.caption).foregroundStyle(.secondary) }
                Button("今天") { selectedDay = Calendar.current.startOfDay(for: Date()); month = selectedDay; page = .calendar }
                Menu {
                    Button("录播 / 可调度课程") { newCourse() }
                    Button("固定课程 / 其他事项") { newFixed() }
                } label: { Label("添加", systemImage: "plus") }.disabled(!store.isReady)
            }
        }
        .sheet(item: $sheet, onDismiss: { store.showDailyReview = false }) { selection in
            switch selection {
            case .course(let course): CourseEditor(store: store, course: course)
            case .fixed(let event): FixedEventEditor(store: store, event: event)
            case .completion(let task): CompletionEditor(store: store, task: task)
            case .review: DailyReviewView(store: store)
            case .risks: RiskView(store: store, adjustSettings: { sheet = nil; page = .settings }, editCourse: { sheet = .course($0) })
            }
        }
        .alert("操作提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onAppear { store.triggerAutomaticSync(); if store.showDailyReview { sheet = .review } }
        .onChange(of: store.showDailyReview) { _, value in if value && sheet == nil { sheet = .review } }
        .onChange(of: scenePhase) { _, value in if value == .active { store.checkDay(); store.triggerAutomaticSync() } }
        .onReceive(timer) { _ in store.checkDay() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 25)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("学习日程").font(.title3.bold())
                    Text("让每一天，有条不紊").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 16)
            VStack(spacing: 5) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: icon(item))
                            .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(page == item ? Color.blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(page == item ? Color.blue : Color.primary)
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            MonthCalendar(selectedDay: $selectedDay, month: $month, tasks: store.state.tasks, fixed: store.state.fixedEvents) { page = .calendar }
            if !store.reviewTasks.isEmpty {
                Button { sheet = .review } label: {
                    HStack {
                        Image(systemName: "checklist")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("学习完成确认").fontWeight(.medium)
                            Text("\(store.reviewTasks.count) 项计划待确认").font(.caption)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            Spacer()
            Label("独立日历 · 数据保存在本机", systemImage: "internaldrive").font(.caption2).foregroundStyle(.secondary)
        }.padding(18)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(page == .calendar ? selectedDay.formatted(.dateTime.month(.wide).day().weekday(.wide)) : page.rawValue).font(.system(size: 25, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !store.result.risks.isEmpty || !store.result.diagnostics.isEmpty {
                Button { sheet = .risks } label: { Label("排程需要调整", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            } else if !store.courses.isEmpty {
                Label("计划已更新", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.teal)
            }
        }.padding(24)
    }
    private var subtitle: String {
        switch page {
        case .calendar: "固定课表优先，学习任务随进度自动调整。"
        case .courses: "管理学习量、截止日期和课程进度。"
        case .fixed: "这些时间始终为固定课程和事项保留。"
        case .settings: "告诉我们你什么时候可以学习。"
        }
    }
    private var dayTasks: [ScheduledTask] {
        store.state.tasks.filter { Calendar.current.isDate($0.start, inSameDayAs: selectedDay) && (store.course($0.courseID)?.isArchived == false || !$0.isUnconfirmed) }
    }
    private var dayEvents: [FixedEvent] { store.state.fixedEvents.filter { $0.occurs(on: selectedDay, calendar: .current) } }
    private var agenda: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Metric(title: "安排学习", value: hours(dayTasks.filter(\.isUnconfirmed).reduce(0) { $0 + $1.durationMinutes }), icon: "book.closed")
                    Metric(title: "已确认学习", value: hours(store.state.completions.filter { Calendar.current.isDate($0.recordedAt, inSameDayAs: selectedDay) }.reduce(0) { $0 + $1.minutes }), icon: "checkmark.circle")
                    Metric(title: "固定事项", value: "\(dayEvents.count) 项", icon: "lock")
                }
                HStack {
                    Text("当天时间轴").font(.headline)
                    Spacer()
                    Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }.help("前一天")
                    Button { moveDay(1) } label: { Image(systemName: "chevron.right") }.help("后一天")
                }
                if dayTasks.isEmpty && dayEvents.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "sun.max").font(.system(size: 38, weight: .light)).foregroundStyle(.blue)
                        Text(store.courses.isEmpty ? "从第一门课程开始" : "这一天还没有安排").font(.title3.bold())
                        Text(store.courses.isEmpty ? "添加课程和截止日期，让学习计划自动生成。" : "可以查看其他日期，或调整可学习时间。").foregroundStyle(.secondary)
                        Button("添加学习课程") { newCourse() }.buttonStyle(.borderedProminent)
                        if store.courses.isEmpty { Button("载入示例，体验自动排程") { store.loadExample() }.buttonStyle(.link) }
                    }.frame(maxWidth: .infinity).padding(.vertical, 60)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(timelineItems) { item in
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(item.start.formatted(date: .omitted, time: .shortened)).font(.system(.callout, design: .monospaced).weight(.medium))
                                    Text(item.end.formatted(date: .omitted, time: .shortened)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }.frame(width: 54, alignment: .trailing).padding(.top, 14)
                                if let task = item.task { taskCard(task) } else if let event = item.event { eventCard(event) }
                            }
                        }
                    }
                    if dayTasks.contains(where: { !$0.isUnconfirmed }) {
                        Text("完成记录 · 不再占用时间").font(.headline)
                        ForEach(dayTasks.filter { !$0.isUnconfirmed }) { task in taskCard(task) }
                    }
                    Text("可提前确认未来任务；未完成的学习量会在剩余日期中重新分配。").font(.caption).foregroundStyle(.secondary).padding(.leading, 68)
                }
            }.padding(24)
        }
    }
    private func taskCard(_ task: ScheduledTask) -> some View {
        let course = store.course(task.courseID)
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(courseColor(course?.color ?? "blue")).frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(course?.name ?? "已删除课程").font(.headline)
                Text("\(hours(task.durationMinutes)) · \(task.isUnconfirmed ? (task.end < Date() ? "待确认" : "可调度学习") : statusLabel(task))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if task.isUnconfirmed {
                Button { _ = store.confirm(task, minutes: task.durationMinutes) } label: {
                    Image(systemName: "circle").font(.title2).foregroundStyle(courseColor(course?.color ?? "blue"))
                }.buttonStyle(.plain).help(task.start > Date() ? "提前完成此任务" : "确认全部完成")
                    .accessibilityLabel(task.start > Date() ? "提前完成\(course?.name ?? "任务")" : "完成\(course?.name ?? "任务")")
                Button { sheet = .completion(task) } label: { Image(systemName: "ellipsis") }.help("部分完成或未完成")
            } else {
                Image(systemName: task.status == .missed ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill").foregroundStyle(task.status == .missed ? Color.orange : Color.teal)
                Button("撤销") { _ = store.undoConfirmation(task) }
                    .buttonStyle(.borderless)
                    .help("撤销这次完成确认并重新排程")
                    .accessibilityLabel("撤销\(course?.name ?? "任务")的完成确认")
            }
        }.padding(14).frame(minHeight: 74).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
    private func eventCard(_ event: FixedEvent) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(courseColor(event.color).opacity(0.65)).frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(event.title).font(.headline)
                Label("固定事项 · 不参与自动移动", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { sheet = .fixed(event) } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("编辑固定事项")
        }.padding(14).frame(minHeight: 74).background(courseColor(event.color).opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }
    private var progressPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("课程进度").font(.headline); Spacer(); Text("\(store.courses.count) 门").font(.caption).foregroundStyle(.secondary) }
                ForEach(store.courses) { course in progressCard(course) }
                if store.courses.isEmpty { Text("添加课程后，可在这里查看进度和每日学习建议。").font(.callout).foregroundStyle(.secondary) }
                Divider()
                Label("计划会随学习进度动态变化", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                Text("每日建议按实际可学习天数计算。最小时间块产生的余量，会分配到不同日期。").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
    private func progressCard(_ course: Course) -> some View {
        let done = store.state.completedMinutes(for: course), remaining = store.state.remainingMinutes(for: course)
        let ratio = Double(done) / Double(max(1, course.totalMinutes))
        let demand = store.result.demands[course.id]
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: course.deadline)).day ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(courseColor(course.color)).frame(width: 8, height: 8)
                Text(course.name).fontWeight(.semibold)
                Spacer()
                Button { sheet = .course(course) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).foregroundStyle(.secondary).help("编辑课程")
            }
            ProgressView(value: ratio).tint(courseColor(course.color))
            HStack { Text("\(Int(ratio * 100))% 已完成"); Spacer(); Text("剩余 \(hours(remaining))") }.font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(remaining == 0 ? "全部完成" : days < 0 ? "已超过截止日期" : "距截止 \(days) 天").foregroundStyle(days < 0 && remaining > 0 ? Color.orange : Color.secondary)
                Text(remaining == 0 ? "" : course.autoScheduleEnabled ? (demand?.learnableDays == 0 ? "无可学习日期，请调整" : "建议约 \(hours(Int(ceil(demand?.averageMinutesPerDay ?? 0)))) / 天") : "已暂停自动排程").foregroundStyle(courseColor(course.color))
            }.font(.caption)
        }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
    private var courseList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("可调度课程").font(.headline); Spacer(); Button("添加课程", systemImage: "plus") { newCourse() }.buttonStyle(.borderedProminent) }
                ForEach(store.courses) { course in
                    HStack(spacing: 20) {
                        RoundedRectangle(cornerRadius: 4).fill(courseColor(course.color)).frame(width: 5)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(course.name).font(.headline)
                            Text("\(course.type.rawValue) · 截止 \(course.deadline.formatted(date: .abbreviated, time: .omitted))").font(.callout).foregroundStyle(.secondary)
                            Text("已学 \(hours(store.state.completedMinutes(for: course))) / 共 \(hours(course.totalMinutes)) · 最小时间块 \(course.minimumBlockMinutes == 0 ? store.state.settings.minimumScheduleUnit : course.minimumBlockMinutes) 分钟").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(course.autoScheduleEnabled ? "自动排程" : "已暂停").font(.caption).foregroundStyle(.secondary)
                        Button("编辑") { sheet = .course(course) }
                    }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
                if store.courses.isEmpty { ContentUnavailableView("还没有学习课程", systemImage: "books.vertical", description: Text("录入总学习量和截止日期，即可生成计划。")) }
            }.padding(28)
        }
    }
    private var fixedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("周期课表与固定事项").font(.headline); Spacer(); Button("添加固定事项", systemImage: "plus") { newFixed() }.buttonStyle(.borderedProminent) }
                ForEach(store.state.fixedEvents.sorted { $0.startDate < $1.startDate }) { event in
                    HStack {
                        Image(systemName: "lock.fill").foregroundStyle(.orange).padding(.trailing, 10)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(event.title).font(.headline)
                            Text("\(clockTime(event.startMinute))–\(clockTime(event.endMinute)) · \(repeatLabel(event.weekdays))").foregroundStyle(.secondary)
                            Text("\(event.startDate.formatted(date: .abbreviated, time: .omitted)) 至 \(event.endDate.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if event.endDate < Calendar.current.startOfDay(for: Date()) { Text("历史课表").font(.caption).foregroundStyle(.secondary) }
                        else { Button("编辑") { sheet = .fixed(event) } }
                    }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
                if store.state.fixedEvents.isEmpty { ContentUnavailableView("添加你的固定课表", systemImage: "calendar.badge.plus", description: Text("学校课程、补习班、考试或休息时间。支持每周重复和学期起止日期。")) }
            }.padding(28)
        }
    }
    private var timelineItems: [TimelineItem] {
        (dayTasks.filter(\.isUnconfirmed).map { TimelineItem(id: $0.id, start: $0.start, end: $0.end, task: $0) } + dayEvents.map {
            TimelineItem(id: $0.id, start: ScheduleEngine().instant(day: selectedDay, minute: $0.startMinute), end: ScheduleEngine().instant(day: selectedDay, minute: $0.endMinute), event: $0)
        }).sorted { $0.start < $1.start }
    }
    private func moveDay(_ step: Int) { selectedDay = Calendar.current.date(byAdding: .day, value: step, to: selectedDay)!; month = selectedDay }
    private func newCourse() { sheet = .course(Course(name: "", totalMinutes: 600, startDate: Calendar.current.startOfDay(for: Date()), deadline: Calendar.current.date(byAdding: .day, value: 30, to: Date())!, minimumBlockMinutes: 0)) }
    private func newFixed() { sheet = .fixed(FixedEvent(title: "", startMinute: 480, endMinute: 580, startDate: Calendar.current.startOfDay(for: Date()), endDate: Calendar.current.date(byAdding: .day, value: 111, to: Date())!, weekdays: [2])) }
    private func icon(_ page: Page) -> String { switch page { case .calendar: "calendar"; case .courses: "books.vertical"; case .fixed: "lock.square"; case .settings: "slider.horizontal.3" } }
}
private struct TimelineItem: Identifiable {
    var id: UUID; var start: Date; var end: Date
    var task: ScheduledTask?; var event: FixedEvent?
}
private struct Metric: View {
    var title: String; var value: String; var icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}
func statusLabel(_ task: ScheduledTask) -> String {
    switch task.status {
    case .completed: return task.confirmedAt.map { $0 < task.start } == true ? "已提前完成" : "已完成"
    case .partial: return "已完成 \(hours(task.completedMinutes)) · 余量已重排"
    case .missed, .rescheduled: return "未完成 · 已重新排程"
    case .planned: return "已计划"
    case .future: return "未来任务"
    }
}
let weekdayNames = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]
func repeatLabel(_ days: Set<Int>) -> String { days.isEmpty ? "单次事项" : [2,3,4,5,6,7,1].filter { days.contains($0) }.map { weekdayNames[$0]! }.joined(separator: "、") }
struct MonthCalendar: View {
    @Binding var selectedDay: Date
    @Binding var month: Date
    var tasks: [ScheduledTask]
    var fixed: [FixedEvent]
    var select: () -> Void
    private let cal = Calendar.current
    private var cells: [Date?] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let offset = (cal.component(.weekday, from: first) + 5) % 7
        return Array(repeating: nil, count: offset) + cal.range(of: .day, in: .month, for: first)!.map { cal.date(byAdding: .day, value: $0 - 1, to: first) }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(month.formatted(.dateTime.year().month(.wide))).font(.callout.weight(.semibold))
                Spacer()
                Button { month = cal.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left") }.help("上个月")
                Button { month = cal.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right") }.help("下个月")
            }.buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 5) {
                ForEach(["一","二","三","四","五","六","日"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.tertiary).frame(height: 20) }
                ForEach(cells.indices, id: \.self) { i in
                    if let day = cells[i] {
                        let chosen = cal.isDate(day, inSameDayAs: selectedDay)
                        let occupied = tasks.contains { cal.isDate($0.start, inSameDayAs: day) } || fixed.contains { $0.occurs(on: day, calendar: cal) }
                        Button { selectedDay = day; select() } label: {
                            VStack(spacing: 2) {
                                Text("\(cal.component(.day, from: day))").font(.system(size: 12, weight: chosen || cal.isDateInToday(day) ? .bold : .regular))
                                Circle().fill(occupied ? (chosen ? Color.white : Color.blue.opacity(0.6)) : .clear).frame(width: 3, height: 3)
                            }.frame(maxWidth: .infinity).frame(height: 30)
                                .background(chosen ? Color.blue : cal.isDateInToday(day) ? Color.blue.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(chosen ? Color.white : Color.primary)
                        }.buttonStyle(.plain).accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    } else { Color.clear.frame(height: 30) }
                }
            }
        }
    }
}

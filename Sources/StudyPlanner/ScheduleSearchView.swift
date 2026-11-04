import SwiftUI
import StudyCore

enum ScheduleSearchScope: String, CaseIterable, Identifiable {
    case upcoming = "接下来", history = "历史", all = "全部"
    var id: Self { self }
    var explanation: String {
        switch self {
        case .upcoming: "今天及以后的未确认安排 · 最近的在前"
        case .history: "已确认记录与往日安排 · 最近的在前"
        case .all: "全部已排日程 · 按日期从早到晚"
        }
    }
}

enum ScheduleSearch {
    static func matches(query: String, tasks: [ScheduledTask], courses: [Course],
                        scope: ScheduleSearchScope = .all, now: Date = Date(),
                        calendar: Calendar = .current) -> [ScheduledTask] {
        let terms = query.precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let coursesByID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let today = calendar.startOfDay(for: now)
        let dateLabel = DateFormatter()
        dateLabel.locale = Locale(identifier: "en_US_POSIX")
        dateLabel.calendar = Calendar(identifier: .gregorian)
        dateLabel.timeZone = calendar.timeZone
        dateLabel.dateFormat = "yyyy-MM-dd"
        return tasks.filter { task in
            let course = coursesByID[task.courseID]
            guard course?.isArchived == false || !task.isUnconfirmed else { return false }
            // Include unfinished work from today and windows crossing midnight.
            let upcoming = task.isUnconfirmed && (task.start >= today || task.planningEnd > today)
            if scope == .upcoming && !upcoming { return false }
            if scope == .history && upcoming { return false }
            let text = [course?.name, task.lessonName, dateLabel.string(from: task.start)].compactMap { $0 }
                .joined(separator: " ").precomposedStringWithCompatibilityMapping
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted {
            if $0.start != $1.start { return scope == .history ? $0.start > $1.start : $0.start < $1.start }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Search results show history as it was recorded: signed-off tasks report the
    /// status and minutes actually studied, while only unconfirmed plans show 未确认.
    static func confirmationLabel(for task: ScheduledTask) -> String {
        task.isUnconfirmed
            ? "未确认 · 计划 \(hours(task.durationMinutes))"
            : "\(statusLabel(task)) · 实际完成 \(hours(task.completedMinutes))"
    }
}

struct ScheduleSearchView: View {
    let tasks: [ScheduledTask]
    let courses: [Course]
    let selectDate: (Date) -> Void
    @State private var query = ""
    @State private var scope = ScheduleSearchScope.upcoming
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var results: [ScheduledTask] {
        ScheduleSearch.matches(query: query, tasks: tasks, courses: courses, scope: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("搜索课程日期").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("课程、课时或日期（YYYY-MM-DD），可组合关键词", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Picker("搜索范围", selection: $scope) {
                ForEach(ScheduleSearchScope.allCases) { value in Text(value.rawValue).tag(value) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("scheduleSearchScope")
            Text(scope.explanation).font(.caption).foregroundStyle(.secondary)
            let matches = results
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("查找哪天学这节课", systemImage: "calendar.badge.magnifyingglass",
                                       description: Text("输入课程、课时名称或日期，也可用空格组合关键词。点击结果跳转到当天；历史记录可切换到“历史”或“全部”查看。"))
            } else if matches.isEmpty {
                ContentUnavailableView("没有找到相关日程", systemImage: "magnifyingglass",
                                       description: Text(scope == .all
                                           ? "试试更短的关键词；尚未排入日程的课时不会显示日期。"
                                           : "试试更短的关键词，或切换到“全部”查找其他日期。"))
            } else {
                Text("找到 \(matches.count) 项安排")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(matches) { task in
                            resultRow(task)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 660, height: 570, alignment: .top)
        .onAppear { searchFocused = true }
    }

    private func resultRow(_ task: ScheduledTask) -> some View {
        let course = courses.first { $0.id == task.courseID }
        return Button { selectDate(task.start) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(task.start.formatted(.dateTime.year().month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                        .font(.headline).foregroundStyle(Color.accentColor)
                    Spacer()
                    Label("查看当天", systemImage: "arrow.right").font(.caption)
                }
                Text(task.lessonName ?? course?.name ?? "已删除课程")
                    .font(.system(size: 18, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if task.lessonName != nil {
                    Text(course?.name ?? "已删除课程").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(task.planningStart.formatted(date: .omitted, time: .shortened))–\(task.planningEnd.formatted(date: .omitted, time: .shortened)) · \(ScheduleSearch.confirmationLabel(for: task))\(task.isFloating ? " · 时段内完成" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

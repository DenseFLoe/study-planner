import SwiftUI
import StudyCore

enum ScheduleSearch {
    static func matches(query: String, tasks: [ScheduledTask], courses: [Course]) -> [ScheduledTask] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let coursesByID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tasks.filter { task in
            let course = coursesByID[task.courseID]
            guard course?.isArchived == false || !task.isUnconfirmed else { return false }
            let text = [course?.name, task.lessonName].compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct ScheduleSearchView: View {
    let tasks: [ScheduledTask]
    let courses: [Course]
    let selectDate: (Date) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var results: [ScheduledTask] {
        ScheduleSearch.matches(query: query, tasks: tasks, courses: courses)
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
                TextField("输入课程或课时名称，例如：简单商品经济", text: $query)
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
            let matches = results
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("查找哪天学这节课", systemImage: "calendar.badge.magnifyingglass",
                                       description: Text("搜索全部已排日程，包括历史记录和未来安排。点击结果即可跳转到当天。"))
            } else if matches.isEmpty {
                ContentUnavailableView("没有找到相关日程", systemImage: "magnifyingglass",
                                       description: Text("试试更短的关键词；尚未排入日程的课时不会显示日期。"))
            } else {
                Text("找到 \(matches.count) 项安排 · 按日期排序")
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
        .frame(width: 660, height: 570)
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
                Text("\(task.planningStart.formatted(date: .omitted, time: .shortened))–\(task.planningEnd.formatted(date: .omitted, time: .shortened)) · \(task.isUnconfirmed ? "未确认" : "已确认")\(task.isFloating ? " · 时段内完成" : "")")
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

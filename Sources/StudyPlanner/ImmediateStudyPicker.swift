import SwiftUI
import StudyCore

struct ImmediateStudyPicker: View {
    @Bindable var store: PlannerStore
    var didSchedule: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var failure: String?

    var body: some View {
        let courses = store.state.immediateStudyCourses
        VStack(alignment: .leading, spacing: 18) {
            Text("立刻调换到现在来上").font(.title2.bold())
            Text("选择一门不定时录播课程，将下一节未完成课节安排在现在（按分钟取整），其余未确认课程重新排课。")
                .foregroundStyle(.secondary)
            if courses.isEmpty {
                ContentUnavailableView("没有可选的不定时课程", systemImage: "books.vertical",
                                       description: Text("请先添加含课节的不定时录播课程，并开启自动排课。"))
            } else {
                Picker("选择课程", selection: $selectedID) {
                    Text("请选择课程").tag(nil as UUID?)
                    ForEach(courses) { course in Text(course.name).tag(Optional(course.id)) }
                }
                if let course = courses.first(where: { $0.id == selectedID }),
                   let lesson = store.state.lessonWorkItems(for: course).first(where: { $0.remainingMinutes > 0 }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lesson.name).font(.headline)
                        Text("本节剩余 \(lesson.remainingMinutes) 分钟 · 保留原课节顺序")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("日期、可学习时段、固定事项与 15 分钟课间休息优先。立即学习高于混排、每日加量、课程优先级、均衡和拖动顺序；重排必须保留各课程截止日前已排入的学习量。无法满足时提示错误并保留原课表。")
                .font(.caption).foregroundStyle(.secondary)
            Text("成功后，本节在结束或确认前继续优先；修改时间约束使其失效时按时间约束重排，也可在右侧取消。")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("立即调换并重排") {
                    guard let selectedID else { return }
                    if store.studyImmediately(courseID: selectedID) {
                        didSchedule(); dismiss()
                    } else {
                        failure = store.errorMessage
                        store.errorMessage = nil
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil || store.syncBusy || store.orderSaveBusy)
            }
        }
        .padding(24).frame(width: 560)
    }
}

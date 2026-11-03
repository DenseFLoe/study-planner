import SwiftUI
import StudyCore

/// 两层原生菜单：课程 → 未完成分节。选中后把该课节作为新的排课约束从现在开始，允许后续未确认课表整体重排。
struct ImmediateStudyMenu: View {
    @Bindable var store: PlannerStore
    var didSchedule: () -> Void

    private var entryDisabled: Bool { !store.isReady || store.orderSaveBusy }

    var body: some View {
        let courses = store.state.immediateStudyCourses
        Menu {
            if courses.isEmpty {
                Button("暂无可立即学习的分节研习") {}.disabled(true)
            } else {
                ForEach(courses) { course in
                    Menu(course.name) {
                        let lessons = store.state.lessonWorkItems(for: course).filter { $0.remainingMinutes > 0 }
                        if lessons.isEmpty {
                            Button("暂无未完成分节") {}.disabled(true)
                        } else {
                            ForEach(lessons) { lesson in
                                Button {
                                    Task { if await store.studyImmediately(courseID: course.id, lessonID: lesson.id) { didSchedule() } }
                                } label: {
                                    Text("\(lesson.name) · 剩余 \(lesson.remainingMinutes) 分钟")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("立即上某节课", systemImage: "play.circle")
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .disabled(entryDisabled)
        .help("选择任意未完成分节，从当前分钟向上取整开始；今日时间不足时，原有未确认课程会移到截止日前的其他可用时段。空档不足整节时先学一段，剩余分钟保留并优先接续；已确认记录和固定事项保留，排不下的学习量会提示，无法开始时保留原数据")
    }
}

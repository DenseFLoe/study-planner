import SwiftUI
import StudyCore

/// 两层原生菜单：课程 → 未完成分节。选中后仅该分节提前到当前分钟开始，其余分节按原顺序重排。
struct ImmediateStudyMenu: View {
    @Bindable var store: PlannerStore
    var didSchedule: () -> Void

    private var entryDisabled: Bool { !store.isReady || store.syncBusy || store.orderSaveBusy }

    var body: some View {
        let courses = store.state.immediateStudyCourses
        Menu {
            if courses.isEmpty {
                Button("暂无可立即学习的不定时课程") {}.disabled(true)
            } else {
                ForEach(courses) { course in
                    Menu(course.name) {
                        let lessons = store.state.lessonWorkItems(for: course).filter { $0.remainingMinutes > 0 }
                        if lessons.isEmpty {
                            Button("暂无未完成分节") {}.disabled(true)
                        } else {
                            ForEach(lessons) { lesson in
                                Button {
                                    if store.studyImmediately(courseID: course.id, lessonID: lesson.id) { didSchedule() }
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
        .help("选择任意未完成分节，从当前分钟向上取整开始上课；仅该分节提前，其余分节按原顺序重排，失败时保留原课表")
    }
}

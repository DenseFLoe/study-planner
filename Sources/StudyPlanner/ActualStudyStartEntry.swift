import SwiftUI
import StudyCore

struct ActualStudyStartEntry: View {
    @Bindable var store: PlannerStore
    var didSave: () -> Void
    @State private var time = Date()

    private var savedTime: Date? { store.state.settings.actualStudyStart(on: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("今日实际开课时间", systemImage: "clock.badge.checkmark")
                .font(.headline)
            Text("从这个时间重新安排今天的未确认课程，并调整后续日期。仍按可学习时段排课，避开固定事项，保留已确认进度。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { timePicker; saveButton }
                VStack(alignment: .leading, spacing: 10) { timePicker; saveButton }
            }
            if let savedTime {
                Label("已按 \(savedTime.formatted(date: .omitted, time: .shortened)) 更新今天及后续课表", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.teal)
            } else {
                Text("每天可重新输入，仅对今天生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .plannerSurface(radius: 16, material: .thinMaterial, shadow: false)
        .onAppear { time = savedTime ?? Date() }
        .onChange(of: savedTime) { _, value in time = value ?? Date() }
    }

    private var timePicker: some View {
        DatePicker("开始时间", selection: $time, displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .fixedSize()
            .accessibilityIdentifier("actual-study-start-time")
    }

    private var saveButton: some View {
        Button("生成新课表", systemImage: "arrow.triangle.2.circlepath") {
            if store.saveActualStudyStart(time) { didSave() }
        }
        .buttonStyle(SoftButtonStyle(prominent: true))
        .disabled(!store.isReady || store.syncBusy)
        .accessibilityIdentifier("apply-actual-study-start")
    }
}

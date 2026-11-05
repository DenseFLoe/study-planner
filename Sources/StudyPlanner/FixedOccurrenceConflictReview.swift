import SwiftUI
import StudyCore

struct FixedOccurrenceConflictReview: View {
    @Bindable var store: PlannerStore
    let event: FixedEvent
    let day: Date
    @State var conflicts: [FixedEventConflict]
    @State private var saving = false
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    private var canReplace: Bool {
        !conflicts.isEmpty && conflicts.allSatisfy {
            $0.date == Calendar.current.startOfDay(for: day) && $0.reason != .activeTask
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("恢复本日安排前，请核对占用", systemImage: "calendar.badge.exclamationmark")
                .font(.title2.bold()).foregroundStyle(.orange)
            Text(day.formatted(.dateTime.year().month().day().weekday())).font(.headline)
            Text("待恢复：\(event.title) · \(clockTime(event.startMinute))–\(clockTime(event.endMinute))" +
                 (event.isFloating ? " · 浮动占用 \(event.occupiedMinutes) 分钟" : ""))
            Text("本日尚未恢复。确认后，只临时移除下列事项在这一天的安排，再恢复「\(event.title)」并重新排程。其他日期保留；临时移除的事项仍可在当天日程中恢复。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(conflict.title).fontWeight(.medium)
                            Text(conflict.timeDescription).monospacedDigit()
                            Text(conflict.explanation).foregroundStyle(.secondary)
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("保持临时移除") { dismiss() }.keyboardShortcut(.cancelAction)
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("恢复并跳过上列事项") { save() }
                    .buttonStyle(.borderedProminent).disabled(!canReplace)
            }
        }.padding(24).frame(width: 680, height: 560)
            .disabled(saving || store.orderSaveBusy)
            .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving, !store.orderSaveBusy, canReplace else { return }
        let reviewedConflicts = conflicts
        saving = true; message = ""
        Task {
            defer { saving = false }
            if await store.restoreEventOccurrence(event, on: day, reviewedConflicts: reviewedConflicts) {
                dismiss()
            } else if let updated = store.pendingEventConflicts {
                conflicts = updated
                message = "当天事项已有变化，列表已更新。本次未恢复或跳过任何事项，请重新核对后再确认。"
            } else {
                message = store.errorMessage ?? "恢复未保存，请重试。"
            }
        }
    }
}

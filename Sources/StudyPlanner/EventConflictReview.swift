import SwiftUI
import StudyCore

struct EventConflictReview: View {
    @Bindable var store: PlannerStore
    var event: FixedEvent
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var skipped: Set<Date> = []
    @State private var message = ""
    @State var conflicts: [FixedEventConflict]
    private var dates: [Date] { Array(Set(conflicts.map(\.date))).sorted() }
    private var remaining: Int { Set(dates).subtracting(skipped).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("逐日处理时间冲突", systemImage: "calendar.badge.exclamationmark")
                .font(.title2.bold()).foregroundStyle(.orange)
            Text("「\(event.title)」 · \(clockTime(event.startMinute))–\(clockTime(event.endMinute))" +
                 (event.isFloating ? " · 浮动占用 \(event.occupiedMinutes) 分钟" : ""))
                .font(.headline)
            Text("是否在冲突当天跳过这项安排？每一天可独立确认；同一天的冲突一起处理。已有事项及其他日期不受影响。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("\(conflicts.count) 处冲突 · \(dates.count) 天 · \(remaining) 天未确认").font(.caption)
                Spacer()
                Button("清除选择") { skipped = [] }.disabled(skipped.isEmpty)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(dates, id: \.self) { day in
                        ConflictDayCard(day: day, conflicts: conflicts.filter { $0.date == day },
                                        selected: Binding(get: { skipped.contains(day) }, set: { value in
                            if value { skipped.insert(day) } else { skipped.remove(day) }
                        }))
                    }
                }.padding(2)
            }
            if event.weekdays.isEmpty {
                Text("这是单次事项；跳过这一天后，该事项不会产生安排。").font(.caption).foregroundStyle(.orange)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            Text(remaining > 0 ? "尚有冲突未确认。可逐日选择跳过，或返回修改时间。" : "保存后会跳过已确认日期，并重新安排学习任务。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("返回修改") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("全部跳过并保存") { skipped.formUnion(dates); save() }
                    .disabled(dates.isEmpty)
                Button("保存已确认的选择") { save() }
                    .buttonStyle(.borderedProminent).disabled(remaining > 0 || dates.isEmpty)
            }
        }.padding(24).frame(width: 680, height: 650)
    }
    private func save() {
        if store.saveEvent(event, skippingDates: skipped) {
            dismiss()
            onSaved()
        } else {
            if let updated = store.pendingEventConflicts { conflicts = updated }
            message = store.pendingEventConflicts == nil ? (store.errorMessage ?? "保存失败，请重试。") : "仍有未处理的冲突，列表已更新，请确认后再保存。"
        }
    }
}


private struct ConflictDayCard: View {
    var day: Date
    var conflicts: [FixedEventConflict]
    @Binding var selected: Bool
    private var tint: Color { selected ? .teal : .orange }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(day.formatted(.dateTime.year().month().day().weekday())).font(.headline)
                Spacer()
                Toggle(selected ? "已确认跳过" : "跳过这一天", isOn: $selected).toggleStyle(.checkbox)
            }
            ForEach(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 5) {
                    Text("与「\(conflict.title)」冲突").fontWeight(.medium)
                    Text(conflict.timeDescription).monospacedDigit()
                    Text(conflict.explanation).foregroundStyle(.secondary)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3)))
    }
}

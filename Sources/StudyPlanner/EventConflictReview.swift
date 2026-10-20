import SwiftUI
import StudyCore

private enum ConflictChoice: Int {
    case unresolved, skipNew, skipLocal
}

struct EventConflictReview: View {
    @Bindable var store: PlannerStore
    var event: FixedEvent
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [Date: ConflictChoice] = [:]
    @State private var message = ""
    @State var conflicts: [FixedEventConflict]
    private var dates: [Date] { Array(Set(conflicts.map(\.date))).sorted() }
    private var remaining: Int { dates.filter { choices[$0, default: .unresolved] == .unresolved }.count }
    private var canSkipAllLocal: Bool { !conflicts.contains { $0.reason == .activeTask } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("逐日处理时间冲突", systemImage: "calendar.badge.exclamationmark")
                .font(.title2.bold()).foregroundStyle(.orange)
            Text("「\(event.title)」 · \(clockTime(event.startMinute))–\(clockTime(event.endMinute))" +
                 (event.isFloating ? " · 浮动占用 \(event.occupiedMinutes) 分钟" : ""))
                .font(.headline)
            Text("每个冲突日期可选择：跳过新课程，保留本地安排；或跳过当天冲突的本地固定事项，保留新课程。同一天的多个冲突一起处理。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("\(conflicts.count) 处冲突 · \(dates.count) 天 · \(remaining) 天未确认").font(.caption)
                Spacer()
                Button("清除选择") { choices = [:] }.disabled(choices.isEmpty)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(dates, id: \.self) { day in
                        ConflictDayCard(day: day, conflicts: conflicts.filter { $0.date == day },
                                        choice: Binding(get: { choices[day, default: .unresolved] },
                                                        set: { choices[day] = $0 }))
                    }
                }.padding(2)
            }
            if event.weekdays.isEmpty {
                Text("这是单次事项；选择跳过新课程后，该事项不会产生安排。").font(.caption).foregroundStyle(.orange)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            Text(remaining > 0 ? "请为每个冲突日期选择处理方式，或返回修改时间。" : "保存后按所选方式跳过当天安排，并重新安排学习任务。其他日期保留。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("返回修改") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("全部跳过新课程并保存") { chooseAll(.skipNew) }.disabled(dates.isEmpty)
                Button("全部跳过本地并保存") { chooseAll(.skipLocal) }
                    .disabled(dates.isEmpty || !canSkipAllLocal)
                Button("保存选择") { save() }
                    .buttonStyle(.borderedProminent).disabled(remaining > 0 || dates.isEmpty)
            }
        }.padding(24).frame(width: 780, height: 680)
    }
    private func chooseAll(_ choice: ConflictChoice) {
        for day in dates { choices[day] = choice }
        save()
    }
    private func save() {
        let skipped = Set(choices.filter { $0.value == .skipNew }.map(\.key))
        let skippedLocal = Set(choices.filter { $0.value == .skipLocal }.map(\.key))
        if store.saveEvent(event, skippingDates: skipped, skippingExistingDates: skippedLocal) {
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
    @Binding var choice: ConflictChoice
    private var tint: Color { choice == .unresolved ? .orange : .teal }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(day.formatted(.dateTime.year().month().day().weekday())).font(.headline)
            ForEach(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 5) {
                    Text("与本地「\(conflict.title)」冲突").fontWeight(.medium)
                    Text(conflict.timeDescription).monospacedDigit()
                    Text(conflict.explanation).foregroundStyle(.secondary)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("处理方式", selection: $choice) {
                Text("请选择").tag(ConflictChoice.unresolved)
                Text("跳过新课程（不植入）").tag(ConflictChoice.skipNew)
                if !conflicts.contains(where: { $0.reason == .activeTask }) {
                    Text("跳过本地固定事项").tag(ConflictChoice.skipLocal)
                }
            }.pickerStyle(.segmented)
            if choice == .skipLocal {
                Text("仅跳过上列本地事项在当天的安排，可在主页恢复。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3)))
    }
}

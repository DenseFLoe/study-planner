import SwiftUI
import StudyCore

struct DailyConsequencesView: View {
    @Bindable var store: PlannerStore
    @State private var controller: DailyConsequenceController
    @AppStorage("dailyStudyLoadWarningMinutes") private var warningMinutes = 480
    private struct Input: Equatable {
        var state: PlannerState
        var tasks: [ScheduledTask]
        var day: Date
        var warning: Int
    }
    init(store: PlannerStore) {
        self.store = store
        _controller = State(initialValue: DailyConsequenceController(inMemory: store.demo))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("昨日结果 · 今日后果预报", systemImage: "calendar.badge.clock").font(.headline)
            yesterdaySection
            Divider()
            if let day = controller.today {
                Text("今天 \(day.date.formatted(.dateTime.month().day()))").font(.subheadline.bold())
                Text("已确认有效学习 \(hours(controller.confirmedToday)) / 今日目标 \(hours(day.goalMinutes))")
                    .font(.caption.weight(.medium))
                Text("确认学习不会降低今日目标；课程或可学时段变更时更新预报。各档同时展示，无需选择。")
                    .font(.caption2).foregroundStyle(.secondary)
                if controller.todayUsesLegacyDates { Text("部分旧记录按确认日期汇总，补录请核对实际日期。").font(.caption2).foregroundStyle(.secondary) }
                if day.goalMinutes > 0 {
                    ForEach(day.fractions, id: \.self) { fraction in
                        ConsequenceScenarioRow(day: day, fraction: fraction, confirmed: controller.confirmedToday,
                            forecast: day.forecasts.first { $0.fraction == fraction },
                            celebration: controller.celebrationEvents[fraction, default: 0])
                            .id("\(day.id)-\(fraction)")
                    }
                    if controller.calculating { ProgressView("正在核算各档后果…").controlSize(.small) }
                    Text("推演假设之后每天也只完成当天预排量的同一比例，最多查看未来90天；压力按预排课表估计，未找到排法不当作无解。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("达标表示今天已超过这一档少学量；整体压力仍以上方实时预警为准。")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("今天没有待执行的学习目标，请同时留意实时排程预警。").font(.caption).foregroundStyle(.secondary)
                }
            } else { ProgressView("正在准备今日预报…").controlSize(.small) }
            if let message = controller.storageMessage { Text(message).font(.caption2).foregroundStyle(.orange) }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .task(id: Input(state: store.state, tasks: store.result.tasks, day: Calendar.current.startOfDay(for: Date()), warning: warningMinutes)) {
            await controller.refresh(state: store.state, result: store.result, now: Date(), warningMinutes: warningMinutes)
        }
        .onDisappear { controller.cancel() }
    }
    @ViewBuilder private var yesterdaySection: some View {
        if let reality = controller.yesterday {
            VStack(alignment: .leading, spacing: 7) {
                Text("昨日 \(reality.date.formatted(.dateTime.month().day()))").font(.subheadline.bold())
                Text("已确认 \(hours(reality.confirmedMinutes)) / 当日目标 \(hours(reality.goalMinutes))").font(.caption)
                if reality.isReviewed {
                    Label("昨日已核对", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    if !reality.achievedFractions.isEmpty {
                        Text(reality.achievedFractions.contains(1000) ? "昨日目标已完成。" : "已超过 \(reality.achievedFractions.count) 档少学情形。")
                            .font(.caption).foregroundStyle(.teal)
                    }
                } else {
                    Text("昨日尚未全部核对；未确认记录不会直接算作没学。").font(.caption).foregroundStyle(.orange)
                }
                if let outcome = reality.outcome {
                    Text("按昨日已确认学习量推算：").font(.caption2).foregroundStyle(.secondary)
                    ConsequenceOutcomeText(outcome: outcome)
                } else {
                    Text("课程或原有进度已变化，昨日预报需重新核对。").font(.caption2).foregroundStyle(.secondary)
                }
                if reality.usesLegacyDates { Text("部分旧记录按确认日期统计，补录日期请核对。").font(.caption2).foregroundStyle(.secondary) }
                if reality.ambiguousRecords > 0 {
                    Text("有 \(reality.ambiguousRecords) 条记录缺少明确的实际学习日期，暂不作最终结论。").font(.caption2).foregroundStyle(.orange)
                }
                if !reality.isReviewed {
                    Button("核对待确认任务") { store.showDailyReview = true }.buttonStyle(.link).font(.caption)
                    let pending = store.state.tasks.contains { $0.isUnconfirmed && Calendar.current.isDate($0.start, inSameDayAs: reality.date) }
                    if !pending && reality.ambiguousRecords == 0 {
                        Button("昨日已核对，没有其他学习") { controller.markYesterdayReviewed(state: store.state, now: Date()) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        } else if controller.checkingYesterday {
            ProgressView("正在核对昨日结果…").controlSize(.small)
        } else {
            Text("尚无昨日预报记录；从今天开始保留每日对照。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ConsequenceScenarioRow: View {
    let day: DailyConsequenceDay
    let fraction: Int
    let confirmed: Int
    let forecast: DailyConsequenceForecast?
    let celebration: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burst = false
    @State private var phase = 0.0
    private var passed: Bool { day.achieved(fraction, confirmed: confirmed) }
    private var title: String {
        if fraction == 0 { return "今天完全不学" }
        if fraction == 1000 { return "今天完成全部计划" }
        return "今天只完成 \(fraction / 10)% · \(hours(day.target(for: fraction)))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: passed ? "checkmark.seal.fill" : "arrow.triangle.branch")
                    .foregroundStyle(passed ? .teal : .secondary)
                    .scaleEffect(burst && !reduceMotion ? 1.12 : 1)
                Text(title).font(.caption.weight(.semibold))
            }
            if passed {
                Text(fraction == 1000 ? "今日目标已完成" : "已超过这一档少学量 · 已避开")
                    .font(.caption.weight(.bold)).foregroundStyle(.teal)
            } else {
                Text("再确认 \(hours(max(0, day.threshold(for: fraction) - confirmed)))，\(fraction == 1000 ? "达到今日目标" : "超过这一档")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let forecast, let outcome = forecast.firstDay {
                if passed {
                    DisclosureGroup(fraction == 1000 ? "查看达标后的预排" : "查看这一档原先的后果") { forecastDetails(forecast, outcome: outcome) }
                        .font(.caption2)
                } else {
                    Text("若今天停在这一档，明日起：").font(.caption2).foregroundStyle(.secondary)
                    forecastDetails(forecast, outcome: outcome)
                }
            } else if let unavailable = forecast?.unavailableTodayMinutes, !passed {
                Text("按当前今日课表，这档还差 \(hours(unavailable)) 没有可执行安排，暂不把它当成能达成的假设。")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !passed {
                Text("正在推算，不先给出未经核算的天数。").font(.caption2).foregroundStyle(.secondary)
            } else if forecast?.evaluatedDays == 0 {
                Text(forecast?.unavailableTodayMinutes != nil ? "已用实际确认进度跨过这一档，先前未排定的假设不再适用。" : "首次预报前已超过这一档，不撤回已确认学习量来反算后果。").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(passed ? Color.teal.opacity(0.09) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(passed ? Color.teal.opacity(burst ? 0.9 : 0.35) : Color.clear, lineWidth: burst ? 2 : 1))
        .overlay(alignment: .topLeading) {
            if burst && !reduceMotion {
                ForEach(0..<10, id: \.self) { index in
                    let angle = Double(index) * .pi / 5
                    Circle().fill(index.isMultiple(of: 2) ? Color.teal : Color.yellow)
                        .frame(width: 4, height: 4)
                        .offset(x: 18 + cos(angle) * 32 * phase, y: 18 + sin(angle) * 32 * phase)
                        .opacity(1 - phase)
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: passed)
        .onChange(of: celebration) { _, value in
            guard value > 0, passed else { return }
            phase = 0; burst = true
            if !reduceMotion { withAnimation(.easeOut(duration: 0.8)) { phase = 1 } }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(950))
                guard celebration == value else { return }
                burst = false
            }
        }
    }
    @ViewBuilder private func forecastDetails(_ value: DailyConsequenceForecast, outcome: DailyConsequenceOutcome) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ConsequenceOutcomeText(outcome: outcome)
            Text(pressureText(value)).font(.caption2).foregroundStyle(.secondary)
            Text(limitText(value)).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func pressureText(_ value: DailyConsequenceForecast) -> String {
        if let days = value.pressureAfterDays {
            return days == 0 ? "压力线：当前预排已超过提醒线。" : "若每天都按此比例完成，预排约第 \(days) 天触及压力线。"
        }
        if value.uncertainFromDay != nil || value.provenLimitAfterDays != nil { return "课表存在未确定或已冲突内容，暂不给出安全的压力缓冲天数。" }
        return "本次推演的 \(value.evaluatedDays) 天内，未发现新增超负担日期。"
    }
    private func limitText(_ value: DailyConsequenceForecast) -> String {
        if let proven = value.provenLimitAfterDays {
            if let unknown = value.uncertainFromDay, unknown < proven {
                return "极限：第 \(unknown) 天起排法待复核，最迟第 \(proven) 天已证实存在约束冲突。"
            }
            return proven == 0 ? "极限：当前已确认存在约束冲突。" : "若每天都按此比例完成，第 \(proven) 天已能证实存在约束冲突。"
        }
        if let unknown = value.uncertainFromDay { return "极限：第 \(unknown) 天起排法尚未确定，不能断言已超限。" }
        return "在本次 \(value.evaluatedDays) 天推演内，未证实硬上限不足。"
    }
}

private struct ConsequenceOutcomeText: View {
    let outcome: DailyConsequenceOutcome
    var body: some View {
        switch outcome.kind {
        case .scheduled:
            Text("仍可按期排入；后续最重一天 \(hours(outcome.peakMinutes))。").font(.caption)
        case .heavy:
            Text("能排入，但有 \(outcome.heavyDays) 天超出负担提醒线；最重一天 \(hours(outcome.peakMinutes))。").font(.caption).foregroundStyle(.orange)
        case .pending:
            Text("暂未排入 \(hours(outcome.unplacedMinutes))，完整排法仍待确认。").font(.caption).foregroundStyle(.orange)
        case .shortage:
            if let minutes = outcome.provenDeficit {
                Text("已证实至少缺少 \(hours(minutes))；涉及 \(outcome.courseNames.joined(separator: "、"))。").font(.caption).foregroundStyle(.red)
            } else {
                Text("已证实缺少能放下 \(outcome.continuousMinutes ?? 0) 分钟内容的连续空档。").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

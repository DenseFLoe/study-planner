import Foundation
import Observation
import StudyCore
import StudyPersistence

@MainActor @Observable
final class DailyConsequenceController {
    private(set) var today: DailyConsequenceDay?
    private(set) var yesterday: DailyConsequenceReality?
    private(set) var confirmedToday = 0
    private(set) var todayUsesLegacyDates = false
    private(set) var celebrationEvents: [Int: Int] = [:]
    private(set) var calculating = false
    private(set) var checkingYesterday = false
    private(set) var storageMessage: String?
    private(set) var todayError: String?
    private(set) var yesterdayError: String?
    @ObservationIgnored private let repository: DailyConsequenceRepository
    @ObservationIgnored private var journal = DailyConsequenceJournal()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loadTask: Task<DailyConsequenceJournal, Error>?
    @ObservationIgnored private var forecastTask: Task<Void, Never>?
    @ObservationIgnored private var realityTask: Task<Void, Never>?
    @ObservationIgnored private var runningEntry: UUID?
    @ObservationIgnored private var forecastGeneration = UUID()
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var inputGeneration = UUID()
    @ObservationIgnored private var writesEnabled = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(inMemory: Bool = false, repository: DailyConsequenceRepository? = nil) {
        self.repository = repository ?? DailyConsequenceRepository(inMemory: inMemory)
    }

    func refresh(state: PlannerState, result: ScheduleResult, now: Date, warningMinutes: Int) async {
        let inputToken = UUID(); inputGeneration = inputToken
        realityTask?.cancel(); refreshGeneration = UUID(); checkingYesterday = false
        if !loaded {
            if loadTask == nil { let repository = repository; loadTask = Task { try await repository.load() } }
            do {
                let value = try await loadTask!.value
                guard inputGeneration == inputToken, !Task.isCancelled else { return }
                if !loaded { journal = value }
            } catch {
                guard inputGeneration == inputToken, !Task.isCancelled else { return }
                writesEnabled = false; storageMessage = "预报历史读取失败，暂用临时预报，原记录未覆盖。"
            }
            loaded = true
        }
        guard inputGeneration == inputToken, !Task.isCancelled else { return }
        defer { updateYesterday(state: state, now: now) }
        let analyzer = DailyConsequenceAnalyzer(), calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        do {
            // Prepare the complete daily update before publishing or saving it.
            let confirmed = try analyzer.confirmed(on: day, state: state)
            let revision = analyzer.revision(state: state, warningMinutes: warningMinutes)
            var candidate = journal, events = celebrationEvents
            var index = candidate.days.firstIndex { calendar.isDate($0.date, inSameDayAs: day) }
            if try index == nil || candidate.days[index!].revision != revision || !analyzer.capturedEvidenceIsValid(candidate.days[index!], state: state) {
                var entry = try analyzer.capture(state: state, result: result, now: now, warningMinutes: warningMinutes)
                if let index {
                    let previous = candidate.days[index]
                    if previous.revision == analyzer.revision(state: state, warningMinutes: previous.warningMinutes) { entry.goalMinutes = previous.goalMinutes }
                    entry.celebrated = previous.celebrated.union(entry.fractions.filter { entry.achieved($0, confirmed: entry.confirmedAtCapture) })
                }
                if let index { candidate.days[index] = entry } else { candidate.days.append(entry) }
                let oldest = calendar.date(byAdding: .day, value: -13, to: day)!
                candidate.days.removeAll { $0.date < oldest }
                index = candidate.days.firstIndex { $0.id == entry.id }
                events = [:]
            }
            guard let index else { return }
            var entry = candidate.days[index]
            let animate = today?.id == entry.id
            for fraction in entry.fractions where entry.achieved(fraction, confirmed: confirmed) && !entry.celebrated.contains(fraction) {
                entry.celebrated.insert(fraction)
                if animate { events[fraction, default: 0] += 1 }
            }
            candidate.days[index] = entry
            if candidate != journal { journal = candidate; persist() }
            confirmedToday = confirmed
            let tasks = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            todayUsesLegacyDates = state.completions.contains { record in
                analyzer.effectiveDay(record, task: tasks[record.taskID]).map { $0.legacy && calendar.isDate($0.date, inSameDayAs: day) } == true
            }
            celebrationEvents = events; today = entry; todayError = nil
            if let runningEntry, runningEntry != entry.id { cancelForecast() }
            guard entry.goalMinutes != 0 else { cancelForecast(); return }
            guard entry.forecasts.count < entry.fractions.count, runningEntry != entry.id else { return }
            cancelForecast(); runningEntry = entry.id; calculating = true
            let token = UUID(); forecastGeneration = token
            let snapshot = entry
            forecastTask = Task.detached(priority: .utility) { [weak self] in
                let analyzer = DailyConsequenceAnalyzer()
                do {
                    for fraction in snapshot.fractions where !snapshot.forecasts.contains(where: { $0.fraction == fraction }) {
                        guard !Task.isCancelled, let value = try analyzer.forecast(snapshot, fraction: fraction) else { break }
                        guard let self, !Task.isCancelled else { return }
                        await self.accept(value, entryID: snapshot.id, token: token)
                    }
                    await self?.finished(entryID: snapshot.id, token: token)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.failedForecast(entryID: snapshot.id, token: token)
                }
            }
        } catch {
            cancelForecast()
            today = nil; confirmedToday = 0; todayUsesLegacyDates = false; celebrationEvents = [:]
            todayError = "今日学习分钟合计超出范围，暂时无法计算预报。原记录未修改。"
        }
    }

    private func accept(_ value: DailyConsequenceForecast, entryID: UUID, token: UUID) {
        guard forecastGeneration == token, runningEntry == entryID, let index = journal.days.firstIndex(where: { $0.id == entryID }) else { return }
        journal.days[index].forecasts.removeAll { $0.id == value.id }
        journal.days[index].forecasts.append(value)
        journal.days[index].forecasts.sort { $0.fraction < $1.fraction }
        if today?.id == entryID { today = journal.days[index] }
        persist()
    }
    private func finished(entryID: UUID, token: UUID) {
        guard forecastGeneration == token, runningEntry == entryID else { return }
        runningEntry = nil; calculating = false
    }
    private func failedForecast(entryID: UUID, token: UUID) {
        guard forecastGeneration == token, runningEntry == entryID, today?.id == entryID else { return }
        today = nil; confirmedToday = 0; todayUsesLegacyDates = false; celebrationEvents = [:]
        todayError = "今日预报的分钟合计超出范围，暂时无法完成计算。原学习记录未修改。"
        runningEntry = nil; calculating = false
    }
    func markYesterdayReviewed(state: PlannerState, now: Date) {
        realityTask?.cancel()
        let token = UUID(); refreshGeneration = token
        let inputToken = inputGeneration, calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        guard let entry = journal.days.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else {
            checkingYesterday = false; return
        }
        checkingYesterday = true
        realityTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let value = try DailyConsequenceAnalyzer().reality(entry, state: state)
                guard !Task.isCancelled else { return }
                let pending = state.tasks.contains { $0.isUnconfirmed && calendar.isDate($0.start, inSameDayAs: date) }
                if pending || value.ambiguousRecords > 0 {
                    await self?.acceptReality(value, token: token)
                } else {
                    await self?.acceptReviewedReality(value, entryID: entry.id, reviewedAt: now, token: token, inputToken: inputToken)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failedReality(token: token)
            }
        }
    }
    private func acceptReviewedReality(_ value: DailyConsequenceReality, entryID: UUID, reviewedAt: Date, token: UUID, inputToken: UUID) {
        guard refreshGeneration == token, inputGeneration == inputToken,
              let index = journal.days.firstIndex(where: { $0.id == entryID }) else { return }
        journal.days[index].reviewedAt = reviewedAt
        var reviewed = value; reviewed.isReviewed = true
        yesterday = reviewed; yesterdayError = nil; checkingYesterday = false
        persist()
    }
    private func updateYesterday(state: PlannerState, now: Date) {
        realityTask?.cancel()
        let token = UUID(); refreshGeneration = token
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        guard let entry = journal.days.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else {
            yesterday = nil; yesterdayError = nil; checkingYesterday = false; return
        }
        if yesterday?.date != entry.date { yesterday = nil }
        checkingYesterday = true
        realityTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let value = try DailyConsequenceAnalyzer().reality(entry, state: state)
                guard !Task.isCancelled else { return }
                await self?.acceptReality(value, token: token)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failedReality(token: token)
            }
        }
    }
    private func acceptReality(_ value: DailyConsequenceReality, token: UUID) {
        guard refreshGeneration == token else { return }
        yesterday = value; yesterdayError = nil; checkingYesterday = false
    }
    private func failedReality(token: UUID) {
        guard refreshGeneration == token else { return }
        yesterday = nil; checkingYesterday = false
        yesterdayError = "昨日学习分钟合计超出范围，暂时无法核对结果。原记录未修改。"
    }
    private func persist() {
        guard writesEnabled else { return }
        sequence += 1
        let value = journal, next = sequence, repository = repository
        saveTask = Task { [weak self] in
            do {
                try await repository.save(value, sequence: next)
                if self?.sequence == next { self?.storageMessage = nil }
            } catch {
                if self?.sequence == next { self?.storageMessage = "预报历史未能保存；本次结果仍可查看，重开后的达标特效可能需要重新核对。" }
            }
        }
    }
    func waitForPersistence() async { await saveTask?.value }
    func waitForYesterday() async { await realityTask?.value }
    func waitForForecasts() async { await forecastTask?.value }
    private func cancelForecast() {
        forecastTask?.cancel(); forecastGeneration = UUID(); runningEntry = nil; calculating = false
    }
    func cancel() {
        cancelForecast(); realityTask?.cancel(); refreshGeneration = UUID(); inputGeneration = UUID(); checkingYesterday = false
    }
}

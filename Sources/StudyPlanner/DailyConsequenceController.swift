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
    @ObservationIgnored private var writesEnabled = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(inMemory: Bool = false, repository: DailyConsequenceRepository? = nil) {
        self.repository = repository ?? DailyConsequenceRepository(inMemory: inMemory)
    }

    func refresh(state: PlannerState, result: ScheduleResult, now: Date, warningMinutes: Int) async {
        if !loaded {
            if loadTask == nil { let repository = repository; loadTask = Task { try await repository.load() } }
            do { let value = try await loadTask!.value; if !loaded { journal = value } }
            catch { writesEnabled = false; storageMessage = "预报历史读取失败，暂用临时预报，原记录未覆盖。" }
            loaded = true
        }
        guard !Task.isCancelled else { return }
        let analyzer = DailyConsequenceAnalyzer(), calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let revision = analyzer.revision(state: state, warningMinutes: warningMinutes)
        var index = journal.days.firstIndex { calendar.isDate($0.date, inSameDayAs: day) }
        if index == nil || journal.days[index!].revision != revision || !analyzer.capturedEvidenceIsValid(journal.days[index!], state: state) {
            var entry = analyzer.capture(state: state, result: result, now: now, warningMinutes: warningMinutes)
            if let index {
                let previous = journal.days[index]
                if previous.revision == analyzer.revision(state: state, warningMinutes: previous.warningMinutes) { entry.goalMinutes = previous.goalMinutes }
                entry.celebrated = previous.celebrated.union(entry.fractions.filter { entry.achieved($0, confirmed: entry.confirmedAtCapture) })
            }
            if let index { journal.days[index] = entry } else { journal.days.append(entry) }
            let oldest = calendar.date(byAdding: .day, value: -13, to: day)!
            journal.days.removeAll { $0.date < oldest }
            index = journal.days.firstIndex { $0.id == entry.id }
            celebrationEvents = [:]
            persist()
        }
        guard let index else { return }
        confirmedToday = analyzer.confirmed(on: day, state: state)
        todayUsesLegacyDates = state.completions.contains { record in
            analyzer.effectiveDay(record, state: state).map { $0.legacy && calendar.isDate($0.date, inSameDayAs: day) } == true
        }
        var entry = journal.days[index]
        let animate = today?.id == entry.id
        for fraction in entry.fractions where entry.achieved(fraction, confirmed: confirmedToday) && !entry.celebrated.contains(fraction) {
            entry.celebrated.insert(fraction)
            if animate { celebrationEvents[fraction, default: 0] += 1 }
        }
        if entry != journal.days[index] { journal.days[index] = entry; persist() }
        today = entry
        updateYesterday(state: state, now: now)
        if entry.goalMinutes == 0 { forecastTask?.cancel(); runningEntry = nil; calculating = false; return }
        if entry.forecasts.count < entry.fractions.count && runningEntry != entry.id {
            forecastTask?.cancel(); runningEntry = entry.id; calculating = true
            let token = UUID(); forecastGeneration = token
            let snapshot = entry
            forecastTask = Task.detached(priority: .utility) { [weak self] in
                let analyzer = DailyConsequenceAnalyzer()
                for fraction in snapshot.fractions where !snapshot.forecasts.contains(where: { $0.fraction == fraction }) {
                    guard !Task.isCancelled, let value = analyzer.forecast(snapshot, fraction: fraction) else { break }
                    guard let self else { return }
                    await self.accept(value, entryID: snapshot.id, token: token)
                }
                await self?.finished(entryID: snapshot.id, token: token)
            }
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
    func markYesterdayReviewed(state: PlannerState, now: Date) {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        guard let index = journal.days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }),
              !state.tasks.contains(where: { $0.isUnconfirmed && calendar.isDate($0.start, inSameDayAs: date) }) else { return }
        journal.days[index].reviewedAt = now
        persist(); updateYesterday(state: state, now: now)
    }
    private func updateYesterday(state: PlannerState, now: Date) {
        realityTask?.cancel()
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        guard let entry = journal.days.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else { yesterday = nil; checkingYesterday = false; return }
        if yesterday?.date != entry.date { yesterday = nil }
        checkingYesterday = true
        let token = UUID(); refreshGeneration = token
        realityTask = Task.detached(priority: .utility) { [weak self] in
            let value = DailyConsequenceAnalyzer().reality(entry, state: state)
            guard !Task.isCancelled else { return }
            await self?.acceptReality(value, token: token)
        }
    }
    private func acceptReality(_ value: DailyConsequenceReality, token: UUID) {
        guard refreshGeneration == token else { return }
        yesterday = value; checkingYesterday = false
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
    func cancel() { forecastTask?.cancel(); realityTask?.cancel(); forecastGeneration = UUID(); runningEntry = nil; calculating = false; checkingYesterday = false }
}

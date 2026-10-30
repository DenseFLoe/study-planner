import Foundation
import Observation
import StudyCore
import StudyPersistence

@MainActor @Observable
final class CompressedScheduleController {
    private(set) var plan: CompressedSchedule?
    private(set) var sharedPreview: CompressedSchedulePreview?
    private(set) var calculating = false
    private(set) var message: String?
    private(set) var cacheMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var input: Input?
    @ObservationIgnored private let cache: CompressedScheduleRepository?
    @ObservationIgnored private var loadedCache = false
    @ObservationIgnored var onResolved: ((CompressedSchedulePreview) -> Void)?
    @ObservationIgnored private let calculate: @Sendable (PlannerState, Date, Calendar) async throws -> CompressedSchedule

    private struct Input: Equatable {
        var basis: CompressedScheduleBasis
        var calendar: Calendar
    }

    init(cache: CompressedScheduleRepository? = nil, calculate: @escaping @Sendable (PlannerState, Date, Calendar) async throws -> CompressedSchedule = {
        try CompressedScheduleEngine(calendar: $2).calculate(state: $0, now: $1)
    }) { self.cache = cache; self.calculate = calculate }

    func update(state: PlannerState, now: Date = Date(), calendar: Calendar = .current) {
        if !loadedCache {
            loadedCache = true
            // A derived cache can be rebuilt if unreadable; the business database
            // and the synced bounded preview are never changed by this read.
            if let saved = try? cache?.load() {
                input = Input(basis: saved.basis, calendar: saved.calendar)
                plan = saved.plan; sharedPreview = saved.preview
            }
        }
        let next = Input(basis: CompressedScheduleBasis(state: state), calendar: calendar)
        if let input, input.calendar == calendar, input.basis.matches(next.basis, now: now, calendar: calendar) { return }
        start(state: state, input: next, now: now)
    }

    func recalculate(state: PlannerState, now: Date = Date(), calendar: Calendar = .current) {
        loadedCache = true
        start(state: state, input: Input(basis: CompressedScheduleBasis(state: state), calendar: calendar), now: now)
    }

    private func start(state: PlannerState, input next: Input, now: Date) {
        input = next
        task?.cancel()
        let token = UUID(), operation = calculate
        generation = token
        calculating = true; plan = nil; sharedPreview = nil; message = nil; cacheMessage = nil
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                // Use live progress only when a structural edit or manual request
                // starts a new baseline. Ordinary confirmations leave it asleep.
                let value = try await operation(state, now, next.calendar)
                guard !Task.isCancelled else { return }
                let preview = try? CompressedSchedulePreview(plan: value, state: state)
                await self?.accept(value, preview: preview, message: nil, input: next, token: token)
            } catch is CancellationError {
                // Replaced inputs own their own running indicator and result.
            } catch {
                guard !Task.isCancelled else { return }
                await self?.accept(nil, message: error.localizedDescription, input: next, token: token)
            }
        }
    }

    private func accept(_ value: CompressedSchedule?, preview: CompressedSchedulePreview? = nil, message: String?, input: Input, token: UUID) {
        guard generation == token else { return }
        plan = value; sharedPreview = preview; self.message = message; calculating = false; task = nil
        if let value, let cache {
            do { try cache.save(.init(basis: input.basis, calendar: input.calendar, plan: value, preview: preview)) }
            catch { cacheMessage = "方案未能缓存；下次打开时可能重新计算。" }
        }
        if let preview { onResolved?(preview) }
    }

    func waitForCalculation() async { await task?.value }
    deinit { task?.cancel() }
}

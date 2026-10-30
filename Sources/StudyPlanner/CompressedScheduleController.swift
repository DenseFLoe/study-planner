import Foundation
import Observation
import StudyCore

@MainActor @Observable
final class CompressedScheduleController {
    private(set) var plan: CompressedSchedule?
    private(set) var sharedPreview: CompressedSchedulePreview?
    private(set) var calculating = false
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var input: Input?
    @ObservationIgnored var onResolved: ((CompressedSchedulePreview) -> Void)?
    @ObservationIgnored private let calculate: @Sendable (PlannerState, Date, Calendar) async throws -> CompressedSchedule

    private struct Input: Equatable {
        var state: PlannerState
        var day: Date
        var calendar: Calendar
    }

    init(calculate: @escaping @Sendable (PlannerState, Date, Calendar) async throws -> CompressedSchedule = {
        try CompressedScheduleEngine(calendar: $2).calculate(state: $0, now: $1)
    }) { self.calculate = calculate }

    func update(state: PlannerState, now: Date = Date(), calendar: Calendar = .current) {
        var snapshot = state
        // Only confirmations identify credited lessons. Ordinary draft changes
        // (including dragging a task) must not restart this independent search.
        snapshot.tasks.removeAll { $0.isUnconfirmed }
        snapshot.settings = AppSettings()
        snapshot.settings.availability = state.settings.availability
        snapshot.settings.minimumScheduleUnit = state.settings.minimumScheduleUnit
        let next = Input(state: snapshot, day: calendar.startOfDay(for: now), calendar: calendar)
        guard next != input else { return }
        input = next
        task?.cancel()
        let token = UUID(), operation = calculate
        generation = token
        calculating = true; plan = nil; sharedPreview = nil; message = nil
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                let value = try await operation(next.state, now, calendar)
                guard !Task.isCancelled else { return }
                let preview = try? CompressedSchedulePreview(plan: value, state: next.state)
                await self?.accept(value, preview: preview, message: nil, token: token)
            } catch is CancellationError {
                // Replaced inputs own their own running indicator and result.
            } catch {
                guard !Task.isCancelled else { return }
                await self?.accept(nil, message: error.localizedDescription, token: token)
            }
        }
    }

    private func accept(_ value: CompressedSchedule?, preview: CompressedSchedulePreview? = nil, message: String?, token: UUID) {
        guard generation == token else { return }
        plan = value; sharedPreview = preview; self.message = message; calculating = false; task = nil
        if let preview { onResolved?(preview) }
    }

    func waitForCalculation() async { await task?.value }
    deinit { task?.cancel() }
}

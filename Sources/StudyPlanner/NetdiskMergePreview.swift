import Foundation
import Observation
import StudyCore

/// Keeps large, read-only merges out of SwiftUI's body evaluation. Only the scan,
/// selection and trimmed title identify work; search and disclosure changes do not.
@MainActor @Observable
final class NetdiskMergePreview {
    struct Request: Equatable, Sendable {
        let revision: UUID
        let selected: Set<String>
        let name: String

        init(revision: UUID, selected: Set<String>, name: String) {
            self.revision = revision
            self.selected = selected
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    typealias Prepare = @Sendable ([NetdiskSnapshotBuilder.Course], String, NetdiskScan) async throws
        -> NetdiskSnapshotBuilder.Course?

    private var request: Request?
    private var prepared: NetdiskSnapshotBuilder.Course?
    private var preparing = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let prepare: Prepare

    init(prepare: @escaping Prepare = { courses, name, scan in
        try NetdiskSnapshotBuilder.merge(courses, name: name, scan: scan,
                                         checkCancellation: { try Task.checkCancellation() })
    }) {
        self.prepare = prepare
    }

    deinit { task?.cancel() }

    func candidate(for input: Request?) -> NetdiskSnapshotBuilder.Course? {
        // The view can render a new input before onChange starts its task. Never
        // enable import (or show a previous preview) in that interval.
        guard let input, input == request else { return nil }
        return prepared
    }

    func isUnavailable(for input: Request?) -> Bool {
        input != nil && input == request && !preparing && prepared == nil
    }

    func update(_ input: Request?, courses: [NetdiskSnapshotBuilder.Course], scan: NetdiskScan?) {
        guard let input, input.selected.count >= 2, !input.name.isEmpty, let scan else {
            cancel()
            return
        }
        guard input != request else { return }
        cancel()
        request = input
        preparing = true
        let current = generation, prepare = prepare
        task = Task { [weak self] in
            do {
                // Collapse rapid title edits and selection changes before sorting.
                try await Task.sleep(for: .milliseconds(120))
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let chosen = courses.filter { input.selected.contains($0.packageID) && $0.refusal == nil }
                    return try await prepare(chosen, input.name, scan)
                }
                let value = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.prepared = value
                self.preparing = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.preparing = false
                self.task = nil
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        request = nil
        prepared = nil
        preparing = false
    }
}

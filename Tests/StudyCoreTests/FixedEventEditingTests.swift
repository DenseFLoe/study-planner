import XCTest
@testable import StudyCore

final class FixedEventEditingTests: XCTestCase {
    func testDeletionRequiresTheReviewedRuleAndPreservesUnrelatedRules() throws {
        let reviewed = event
        let edits: [(inout FixedEvent) -> Void] = [
            { $0.title = "同步新名称" }, { $0.notes = "新备注" }, { $0.color = "green" },
            { $0.startMinute += 5 }, { $0.endMinute += 5 }, { $0.floatingDurationMinutes = 30 },
            { $0.startDate.addTimeInterval(86400) }, { $0.endDate.addTimeInterval(86400) },
            { $0.weekdays = [2] }, { $0.excludedDates = [self.day] }
        ]
        for edit in edits {
            var changed = reviewed; edit(&changed)
            var state = PlannerState(); state.fixedEvents = [changed]
            let before = state
            XCTAssertThrowsError(try state.removeFixedEvent(reviewed: reviewed)) { error in
                guard case FixedEventEditError.removalChanged = error else { return XCTFail("Wrong conflict: \(error)") }
            }
            XCTAssertEqual(state, before)
        }
        var state = PlannerState(), other = reviewed; other.id = UUID()
        state.fixedEvents = [reviewed, other]; state.settings.minimumScheduleUnit = 15
        try state.removeFixedEvent(reviewed: reviewed)
        XCTAssertEqual(state.fixedEvents, [other]); XCTAssertEqual(state.settings.minimumScheduleUnit, 15)
        XCTAssertThrowsError(try state.removeFixedEvent(reviewed: reviewed))
        XCTAssertEqual(state.fixedEvents, [other])
    }
    private let calendar = Calendar(identifier: .gregorian)
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))! }
    private var event: FixedEvent { FixedEvent(title: "Original", startMinute: 540, endMinute: 600, startDate: day, endDate: day) }

    func testOldNotesDraftPreservesRemoteRenameTimeAndSkippedDate() throws {
        let baseline = event
        var draft = baseline, remote = baseline
        draft.notes = "Local notes"
        remote.title = "Phone title"; remote.startMinute = 600; remote.endMinute = 660
        remote.excludedDates = [day]
        var state = PlannerState(); state.fixedEvents = [remote]
        try FixedEventEdit(event: draft, baseline: baseline).apply(to: &state, now: day, calendar: calendar)
        remote.notes = draft.notes
        XCTAssertEqual(state.fixedEvents, [remote])
        XCTAssertEqual(draft.title, baseline.title, "Merging must not replace the retained draft")
    }

    func testSameFieldConflictAndDeletionKeepDraftAndState() throws {
        let baseline = event
        var draft = baseline, remote = baseline
        draft.title = "Mac"; remote.title = "Phone"
        for events in [[remote], []] {
            var state = PlannerState(); state.fixedEvents = events
            let original = state
            XCTAssertThrowsError(try FixedEventEdit(event: draft, baseline: baseline).apply(to: &state, now: day)) {
                XCTAssertTrue($0 is FixedEventEditError)
            }
            XCTAssertEqual(state, original)
            XCTAssertEqual(draft.title, "Mac")
        }
    }

    func testEverySchedulingFieldConflictsWithConcurrentExclusion() throws {
        let baseline = event
        var remote = baseline; remote.excludedDates = [day]
        let edits: [(inout FixedEvent) -> Void] = [
            { $0.startMinute += 5 }, { $0.endMinute += 5 }, { $0.startDate.addTimeInterval(86400) },
            { $0.endDate.addTimeInterval(86400) }, { $0.weekdays = [2] }, { $0.floatingDurationMinutes = 30 },
            { $0.excludedDates = [self.day.addingTimeInterval(86400)] }
        ]
        for edit in edits {
            var draft = baseline; edit(&draft)
            XCTAssertThrowsError(try draft.mergingDraft(from: baseline, into: remote))
            XCTAssertEqual(try draft.mergingDraft(from: baseline, into: draft), draft, "Same-value edits are idempotent")
        }
    }

    func testHistorySplitUsesLatestRuleAndPreservesAlreadyStartedToday() throws {
        var baseline = event
        baseline.startDate = day.addingTimeInterval(-86400)
        baseline.endDate = day.addingTimeInterval(3 * 86400)
        baseline.weekdays = Set(1...7)
        var draft = baseline, remote = baseline
        draft.notes = "Local notes"
        remote.title = "Phone title"; remote.startMinute = 480
        remote.excludedDates = [day.addingTimeInterval(2 * 86400)]
        var state = PlannerState(); state.fixedEvents = [remote]
        try FixedEventEdit(event: draft, baseline: baseline).apply(to: &state, now: day.addingTimeInterval(9 * 3600), calendar: calendar)
        let history = try XCTUnwrap(state.fixedEvents.first { $0.id == baseline.id })
        let future = try XCTUnwrap(state.fixedEvents.first { $0.id != baseline.id })
        XCTAssertEqual(state.fixedEvents.count, 2)
        remote.endDate = day
        XCTAssertEqual(history, remote)
        XCTAssertEqual(future.startDate, day.addingTimeInterval(86400))
        XCTAssertEqual(future.startMinute, 480)
        XCTAssertEqual(future.title, "Phone title")
        XCTAssertEqual(future.notes, "Local notes")
        XCTAssertEqual(future.excludedDates, remote.excludedDates)
    }

    func testReviewDoesNotSilentlySkipNewOrChangedOccupants() throws {
        let incoming = event
        var occupant = event; occupant.id = UUID(); occupant.title = "Occupant"
        var state = PlannerState(); state.fixedEvents = [occupant]
        let reviewed = try conflicts(for: incoming, in: state)
        for change in [0, 1, 2] {
            var latest = state
            if change == 0 { latest.fixedEvents[0].title = "Phone rename" }
            if change == 1 {
                var additional = occupant; additional.id = UUID(); additional.title = "New occupant"
                latest.fixedEvents.append(additional)
            }
            if change == 2 { latest.fixedEvents = [] }
            let original = latest
            XCTAssertThrowsError(try FixedEventEdit(event: incoming, baseline: nil, skippingExistingDates: [day],
                                                  reviewedConflicts: reviewed).apply(to: &latest, now: day, calendar: calendar))
            XCTAssertEqual(latest, original, "Failure must leave neither skips nor a new rule")
        }
    }

    func testReviewCarriesOriginalBaselineAndRejectsUnreviewedSkips() throws {
        let baseline = event
        var occupant = event; occupant.id = UUID()
        var draft = baseline; draft.title = "Local title"
        var state = PlannerState(); state.fixedEvents = [baseline, occupant]
        let reviewed = try conflicts(for: draft, in: state)
        state.fixedEvents[0].title = "Phone title"
        let original = state
        XCTAssertThrowsError(try FixedEventEdit(event: draft, baseline: baseline, skippingExistingDates: [day],
                                              reviewedConflicts: reviewed).apply(to: &state, now: day)) {
            XCTAssertTrue($0 is FixedEventEditError)
        }
        XCTAssertEqual(state, original)
        XCTAssertThrowsError(try FixedEventEdit(event: draft, baseline: nil, skippingDates: [day]).apply(to: &state, now: day))
    }

    private func conflicts(for incoming: FixedEvent, in state: PlannerState) throws -> [FixedEventConflict] {
        var probe = state
        do { try probe.updateFixedEvent(incoming, now: day, calendar: calendar) }
        catch let PlannerError.fixedConflict(found) { return found }
        XCTFail("Fixture requires a conflict")
        return []
    }
}

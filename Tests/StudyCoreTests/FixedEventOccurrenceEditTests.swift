import XCTest
@testable import StudyCore

final class FixedEventOccurrenceEditTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))! }
    private var event: FixedEvent { .init(title: "复习", startMinute: 540, endMinute: 600, startDate: day,
        endDate: calendar.date(byAdding: .day, value: 3, to: day)!, weekdays: Set(1...7)) }

    func testChangedSelectedOccurrenceIsRejectedBeforeMutation() throws {
        let reviewed = event, edit = FixedEventOccurrenceEdit(reviewed: event, on: day, skipped: true)
        let changes: [(inout FixedEvent) -> Void] = [
            { $0.title = "新的事项" }, { $0.startMinute += 5 }, { $0.endMinute += 5 },
            { $0.floatingDurationMinutes = 30 }, { $0.startDate.addTimeInterval(86400) },
            { $0.endDate = self.day.addingTimeInterval(-86400) },
            { $0.weekdays = [self.calendar.component(.weekday, from: self.day) % 7 + 1] }
        ]
        for change in changes {
            var current = reviewed; change(&current)
            var state = PlannerState(); state.fixedEvents = [current]; let before = state
            XCTAssertThrowsError(try edit.apply(to: &state, now: day, calendar: calendar))
            XCTAssertEqual(state, before)
        }
        var removed = PlannerState()
        XCTAssertThrowsError(try edit.apply(to: &removed, now: day, calendar: calendar))
        XCTAssertTrue(removed.fixedEvents.isEmpty)
    }

    func testSkipPreservesOtherDatesAndMetadataAndIsIdempotent() throws {
        let reviewed = event, tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        var latest = reviewed; latest.notes = "新备注"; latest.color = "blue"; latest.excludedDates = [tomorrow]
        latest.endDate = calendar.date(byAdding: .day, value: 4, to: day)!
        var state = PlannerState(); state.fixedEvents = [latest]
        let edit = FixedEventOccurrenceEdit(reviewed: reviewed, on: day, skipped: true)
        try edit.apply(to: &state, now: day, calendar: calendar)
        latest.excludedDates.insert(day)
        XCTAssertEqual(state.fixedEvents, [latest])
        let saved = state
        try edit.apply(to: &state, now: day, calendar: calendar)
        XCTAssertEqual(state, saved)
        XCTAssertThrowsError(try edit.apply(to: &state, now: tomorrow, calendar: calendar))
        XCTAssertEqual(state, saved)
    }

    func testRestoreChecksCurrentOccupantsAndKeepsOtherSkippedDates() throws {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        var reviewed = event; reviewed.excludedDates = [day, tomorrow]
        let edit = FixedEventOccurrenceEdit(reviewed: reviewed, on: day, skipped: false)
        let blocker = FixedEvent(title: "后来新增", startMinute: 550, endMinute: 580, startDate: day, endDate: day)
        var state = PlannerState(); state.fixedEvents = [reviewed, blocker]; let before = state
        XCTAssertThrowsError(try edit.apply(to: &state, now: day, calendar: calendar))
        XCTAssertEqual(state, before)
        state.fixedEvents.removeLast()
        try edit.apply(to: &state, now: day, calendar: calendar)
        XCTAssertEqual(state.fixedEvents[0].excludedDates, [tomorrow])
        XCTAssertTrue(state.fixedEvents[0].occurs(on: day, calendar: calendar))
    }
}

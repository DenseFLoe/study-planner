import XCTest
@testable import StudyPlanner

final class PlannerWindowLayoutTests: XCTestCase {
    func testColumnsFoldBeforeCrowdingTheAgenda() {
        let narrow = PlannerWindowLayout(width: 992)
        XCTAssertFalse(narrow.showsSidebar)
        XCTAssertFalse(narrow.showsInsights)
        XCTAssertFalse(narrow.compactAgenda)

        let middle = PlannerWindowLayout(width: 993)
        XCTAssertTrue(middle.showsSidebar)
        XCTAssertFalse(middle.showsInsights)
        XCTAssertFalse(middle.compactAgenda)

        let beforeInsights = PlannerWindowLayout(width: 1323)
        XCTAssertTrue(beforeInsights.showsSidebar)
        XCTAssertFalse(beforeInsights.showsInsights)
        XCTAssertFalse(beforeInsights.compactAgenda)

        let wide = PlannerWindowLayout(width: 1324)
        XCTAssertTrue(wide.showsSidebar)
        XCTAssertTrue(wide.showsInsights)
        XCTAssertFalse(wide.compactAgenda)
        XCTAssertEqual(PlannerWindowLayout(width: PlannerTheme.referenceWindowWidth), wide)
    }

    func testAgendaOnlyCompactsAfterBothColumnsHaveFolded() {
        for width in 680...1600 {
            let layout = PlannerWindowLayout(width: Double(width))
            XCTAssertEqual(layout.compactAgenda, width < 760, "window width: \(width)")
            if layout.compactAgenda {
                XCTAssertFalse(layout.showsSidebar)
                XCTAssertFalse(layout.showsInsights)
            }
        }
    }

    func testLiveResizePublishesOnlyPresentationChanges() {
        // A continuous drag must not invalidate data views for every pixel.
        var previous = PlannerWindowLayout(width: 680)
        var changedWidths: [Int] = []
        for width in 681...1440 {
            let next = PlannerWindowLayout(width: Double(width))
            if next != previous { changedWidths.append(width) }
            previous = next
        }
        XCTAssertEqual(changedWidths, [760, 900, 993, 1133, 1324])
    }
}

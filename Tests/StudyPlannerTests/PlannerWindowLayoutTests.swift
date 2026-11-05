import XCTest
@testable import StudyPlanner

final class PlannerWindowLayoutTests: XCTestCase {
    func testColumnsFoldBeforeCrowdingTheAgenda() {
        let narrow = PlannerWindowLayout(width: 959)
        XCTAssertFalse(narrow.showsSidebar)
        XCTAssertFalse(narrow.showsInsights)
        XCTAssertFalse(narrow.compactAgenda)

        let middle = PlannerWindowLayout(width: 960)
        XCTAssertTrue(middle.showsSidebar)
        XCTAssertFalse(middle.showsInsights)
        XCTAssertTrue(middle.compactAgenda)

        let wide = PlannerWindowLayout(width: 1280)
        XCTAssertTrue(wide.showsSidebar)
        XCTAssertTrue(wide.showsInsights)
        XCTAssertTrue(wide.compactAgenda)
        XCTAssertFalse(PlannerWindowLayout(width: 1324).compactAgenda)
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
        XCTAssertEqual(changedWidths, [760, 900, 960, 993, 1133, 1280, 1324])
    }
}

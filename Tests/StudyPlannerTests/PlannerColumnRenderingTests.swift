import AppKit
import SwiftUI
import StudyCore
import XCTest
@testable import StudyPlanner

@MainActor
final class PlannerColumnRenderingTests: XCTestCase {
    @Observable fileprivate final class Model {
        var expanded = true
        var value = 0
    }

    private final class Renders {
        var values: [Int] = []
        var enabled: [Bool] = []
        var widths: [CGFloat] = []
        var slotWidths: [CGFloat] = []
        var identities: [UUID] = []
        var animated = false
        var aggregations = 0
    }

    private struct Panel: View {
        var model: Model
        var renders: Renders
        @Environment(\.isEnabled) private var enabled
        @State private var identity = UUID()

        var body: some View {
            let _ = renders.values.append(model.value)
            let _ = renders.enabled.append(enabled)
            let _ = renders.identities.append(identity)
            Text("Panel \(model.value)")
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    renders.widths.append($0)
                }
                .transaction { if $0.animation != nil { renders.animated = true } }
        }
    }

    private struct ProgressContent: View {
        var course: Course
        var renders: Renders

        var body: some View {
            CourseProgressPanel(courses: [course], demands: [:], completedMinutes: { _ in
                renders.aggregations += 1
                return 30
            }, edit: { _ in })
        }
    }

    private struct Harness: View {
        var model: Model
        var renders: Renders
        var edge: HorizontalEdge
        let course = Course(name: "Synthetic course", totalMinutes: 60, startDate: .distantPast, deadline: .distantFuture)

        var body: some View {
            HStack(spacing: 0) {
                PlannerCollapsibleColumn(isExpanded: model.expanded, width: 330, edge: edge) {
                    VStack {
                        Panel(model: model, renders: renders)
                        ProgressContent(course: course, renders: renders)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    renders.slotWidths.append($0)
                }
                Color.clear
            }
            .animation(PlannerTheme.columnTransition, value: model.expanded)
            .transaction(value: model.expanded) { $0.plannerColumnTransition = true }
        }
    }

    func testFoldingKeepsPanelContentStableAndLive() async throws {
        _ = NSApplication.shared
        for edge in [HorizontalEdge.leading, .trailing] {
            let model = Model()
            let renders = Renders()
            let host = NSHostingView(rootView: Harness(model: model, renders: renders, edge: edge))
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(renders.values.isEmpty)
            let initialAggregations = renders.aggregations
            XCTAssertEqual(initialAggregations, 1, "Resolve progress once per course")
            // Let SwiftUI establish the retained subtree's dynamic-property
            // locations before measuring repeated presentation-only updates.
            for expanded in [false, true] {
                model.expanded = expanded
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
            }
            let settledAggregations = renders.aggregations

            for expanded in [false, true, false] {
                model.expanded = expanded
                for _ in 0..<35 {
                    try await Task.sleep(for: .milliseconds(10))
                    host.layoutSubtreeIfNeeded()
                }
            }
            XCTAssertEqual(Set(renders.identities).count, 1, "Folding preserves panel state")
            XCTAssertEqual(renders.enabled.last, false, "Collapsed controls cannot receive keyboard input")
            XCTAssertTrue(renders.widths.allSatisfy { $0 == 330 })
            XCTAssertFalse(renders.animated, "Slot animations must not reach panel content")
            XCTAssertEqual(renders.slotWidths.last, 0)
            XCTAssertEqual(renders.aggregations, settledAggregations,
                           "Changing a panel's enabled state must not rescan its lessons")

            withAnimation(.linear(duration: 0.05)) { model.value = 1 }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(renders.values.last, 1, "Collapsed content still observes data changes")
            XCTAssertTrue(renders.animated, "Ordinary data animations must survive the resize boundary")
        }
    }
}

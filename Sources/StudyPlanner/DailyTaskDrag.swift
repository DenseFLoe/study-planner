import SwiftUI

struct DailyTaskFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Motion values shared by the dragged card and the timeline that reorders it.
/// Keeping them in one place is what lets the release, the offset returning to
/// zero and the neighbour swap read as one continuous move.
enum DailyTaskMotion {
    /// The drag's release transaction and the timeline's reorder animation use the
    /// same spring, so the offset and the list order interpolate together from the
    /// release point instead of snapping or arriving on two separate timelines.
    static let settleResponse: Double = 0.38
    static let settleDampingFraction: Double = 0.86
    static var settle: Animation {
        .spring(response: settleResponse, dampingFraction: settleDampingFraction)
    }

    /// Lift, drop-target highlight and hint feedback. These are attached as local
    /// value animations and never wrap the position offset, so pointer tracking
    /// stays frame-exact while the feedback itself still eases.
    static var lift: Animation { .spring(response: 0.26, dampingFraction: 0.84) }
    static var target: Animation { .easeOut(duration: 0.16) }
    /// Row hover feedback; disabled outright under Reduce Motion.
    static var hover: Animation { .spring(response: 0.28, dampingFraction: 0.82) }

    static let liftScale: CGFloat = 1.012
    static let liftShadowOpacity: Double = 0.16
    static let liftShadowRadius: CGFloat = 14
    static let liftShadowY: CGFloat = 6
}

/// A short click continues to reach buttons; only a held press begins reordering.
struct DailyTaskDrag: ViewModifier {
    let id: UUID
    let enabled: Bool
    let targeted: Bool
    let changed: (CGPoint?) -> Void
    let ended: (CGPoint?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var holding = false
    /// The pointer offset is view state rather than a `@GestureState`, because the
    /// release has to animate it back to zero inside the very transaction that
    /// reorders the list. A gesture state would zero it outside that transaction
    /// and cut the move in two.
    @State private var translation: CGSize = .zero

    private var liftAnimation: Animation? { reduceMotion ? nil : DailyTaskMotion.lift }
    private var targetAnimation: Animation? { reduceMotion ? nil : DailyTaskMotion.target }

    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: 17))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: DailyTaskFrames.self,
                                       value: enabled ? [id: proxy.frame(in: .named("dailyTaskTimeline"))] : [:])
            })
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(targeted || holding ? Color.accentColor : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                Text("松开交换").font(.caption.bold()).padding(6)
                    .background(.regularMaterial, in: Capsule()).padding(6)
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(!targeted)
            }
            .scaleEffect(holding && !reduceMotion ? DailyTaskMotion.liftScale : 1)
            .shadow(color: .black.opacity(holding && !reduceMotion ? DailyTaskMotion.liftShadowOpacity : 0),
                    radius: DailyTaskMotion.liftShadowRadius, y: DailyTaskMotion.liftShadowY)
            // Scoped animations: only the lift and the target highlight animate.
            // The offset stays outside them, so following the pointer never picks
            // up an implicit spring and stays frame-exact.
            .animation(liftAnimation, value: holding)
            .animation(targetAnimation, value: targeted)
            .offset(translation)
            // Deliberately a low-precedence gesture: a plain click on the card's
            // confirm or partial-completion buttons has to win the press, and only
            // a press held past the long-press delay may start reordering.
            // `highPriorityGesture` outranked those buttons and swallowed their
            // clicks, and the `.subviews` mask kept swallowing them even while
            // reordering was disabled, so the mask is `.none` there instead.
            .gesture(reorderGesture, including: enabled ? .all : .none)
            .onChange(of: holding) { _, active in
                guard !active else { return }
                // A normal release already zeroed the offset inside `settle`, so a
                // non-zero offset here means the gesture was cancelled and no
                // `onEnded` ran. Recover it without swapping, then drop the hint.
                if translation != .zero {
                    var transaction = Transaction(animation: reduceMotion ? nil : DailyTaskMotion.settle)
                    transaction.disablesAnimations = reduceMotion
                    withTransaction(transaction) { translation = .zero }
                }
                changed(nil)
            }
            .help(enabled ? "长按课程板块后拖到另一课程或课节板块上，松开交换本日顺序" : "")
    }

    /// Long press, then follow the pointer. Kept apart from `body` so the
    /// precedence and the mask it is attached with stay visible at the call site.
    private var reorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("dailyTaskTimeline")))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                guard let drag else {
                    // Held, but the pointer has not moved yet.
                    changed(nil)
                    return
                }
                // Follow the pointer exactly: this write is never animated.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { translation = drag.translation }
                changed(drag.location)
            }
            .onEnded { value in
                let location: CGPoint?
                if case .second(true, let drag) = value { location = drag?.location } else { location = nil }
                settle(location)
            }
    }

    /// Release: the offset returns to zero and the list swaps inside one
    /// transaction, so both interpolate continuously from the release point.
    private func settle(_ location: CGPoint?) {
        var transaction = Transaction(animation: reduceMotion ? nil : DailyTaskMotion.settle)
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) {
            translation = .zero
            ended(location)
        }
    }
}

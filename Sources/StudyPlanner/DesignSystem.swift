import SwiftUI

enum PlannerTheme {
    static let accent = Color(red: 0.08, green: 0.46, blue: 0.98)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let opaqueSurface = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.075)
    static let glassHairline = Color.white.opacity(0.46)
    static let softShadow = Color.black.opacity(0.07)
    static let radius: CGFloat = 20
    static let compactRadius: CGFloat = 14
    static let pagePadding: CGFloat = 26
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
}
/// A quiet wash of color gives transparent surfaces something to refract without
/// competing with the schedule itself.
struct PlannerGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PlannerTheme.canvas

                Circle()
                    .fill(PlannerTheme.accent.opacity(colorScheme == .dark ? 0.16 : 0.10))
                    .frame(width: proxy.size.width * 0.58)
                    .blur(radius: 105)
                    .offset(x: proxy.size.width * 0.34, y: -proxy.size.height * 0.36)

                Circle()
                    .fill(Color.purple.opacity(colorScheme == .dark ? 0.11 : 0.065))
                    .frame(width: proxy.size.width * 0.42)
                    .blur(radius: 115)
                    .offset(x: -proxy.size.width * 0.38, y: proxy.size.height * 0.38)

                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.015 : 0.16),
                        Color.clear,
                        PlannerTheme.accent.opacity(colorScheme == .dark ? 0.035 : 0.025)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct LiquidGlassModifier<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool
    var fallbackMaterial: Material
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    shape.fill(PlannerTheme.opaqueSurface)
                    if let tint {
                        shape.fill(tint.opacity(0.72))
                    }
                }
                .overlay {
                    shape.strokeBorder(PlannerTheme.hairline, lineWidth: 1)
                }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(
                Glass.regular.tint(tint).interactive(interactive),
                in: shape
            )
        } else {
            content
                .background {
                    shape.fill(fallbackMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.78))
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                PlannerTheme.glassHairline,
                                Color.white.opacity(0.12),
                                Color.black.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                }
        }
    }
}

extension View {
    func liquidGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackMaterial: Material = .regularMaterial
    ) -> some View {
        modifier(
            LiquidGlassModifier(
                shape: shape,
                tint: tint,
                interactive: interactive,
                fallbackMaterial: fallbackMaterial
            )
        )
    }
}

struct PlannerSurface: ViewModifier {
    var radius: CGFloat = PlannerTheme.radius
    var material: Material = .regularMaterial
    var shadow: Bool = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .liquidGlass(in: shape, fallbackMaterial: material)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.38),
                            PlannerTheme.hairline,
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.7
                )
            }
            .shadow(color: shadow ? PlannerTheme.softShadow : .clear, radius: 18, y: 7)
    }
}

extension View {
    func plannerSurface(
        radius: CGFloat = PlannerTheme.radius,
        material: Material = .regularMaterial,
        shadow: Bool = true
    ) -> some View {
        modifier(PlannerSurface(radius: radius, material: material, shadow: shadow))
    }
}

struct CircularIconButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 17 : 13, weight: .semibold))
            .frame(width: prominent ? 42 : 32, height: prominent ? 42 : 32)
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.72))
            .liquidGlass(
                in: Circle(),
                tint: prominent ? PlannerTheme.accent : nil,
                interactive: true,
                fallbackMaterial: .thinMaterial
            )
            .shadow(
                color: prominent ? PlannerTheme.accent.opacity(0.25) : Color.black.opacity(0.045),
                radius: prominent ? 11 : 5,
                y: prominent ? 5 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 15)
            .frame(height: 34)
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.78))
            .liquidGlass(
                in: Capsule(style: .continuous),
                tint: prominent ? PlannerTheme.accent : nil,
                interactive: true,
                fallbackMaterial: .thinMaterial
            )
            .shadow(
                color: prominent ? PlannerTheme.accent.opacity(0.20) : Color.black.opacity(0.035),
                radius: prominent ? 9 : 4,
                y: prominent ? 4 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

struct PlannerSectionTitle: View {
    var title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

import SwiftUI

/// Centering the occupied portion communicates a quota, not a scheduled start.
struct FloatingWindowIndicator: View {
    var occupied: Int
    var window: Int
    var tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack {
                    Capsule().fill(tint.opacity(0.08))
                    Capsule().strokeBorder(tint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Capsule().fill(tint.opacity(0.45))
                        .frame(width: max(8, geometry.size.width * min(1, max(0, Double(occupied) / Double(max(1, window))))))
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(tint)
                }
            }.frame(height: 12)
            Text("占用 \(occupied) 分钟 / 时段 \(max(0, window)) 分钟 · 位置未定")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时段内浮动，占用 \(occupied) 分钟，时段共 \(window) 分钟，具体位置未定")
    }
}

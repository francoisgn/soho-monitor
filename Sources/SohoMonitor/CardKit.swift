import SohoMonitorCore
import SwiftUI

// The shared card look (OnlySwitch-like): an icon, a large rounded figure, a name, pills, a thin bar and a sparkline,
// on native Liquid Glass. Pure rules (levels, clamping, formatting, sparkline scale) live in SohoMonitorCore.

/// Colour tokens: one accent per metric, warning and critical states. Apple system colours: they adapt to light,
/// dark and Increase Contrast on their own.
enum CardColor {
    static let cpu = Color.blue
    static let gpu = Color.purple
    static let memory = Color.green
    static let disk = Color.orange
    static let network = Color.cyan
    static let warning = Color.orange
    static let critical = Color.red

    /// The accent when normal, orange or red otherwise.
    static func tint(_ level: MetricLevel, accent: Color) -> Color {
        switch level {
        case .normal: accent
        case .warning: warning
        case .critical: critical
        }
    }
}

/// A glass card. Under Reduce Transparency it falls back to an opaque window-coloured background.
struct GlassCard<Content: View>: View {
    var accent: Color
    var cornerRadius: CGFloat = 24
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(shape.strokeBorder(.separator, lineWidth: 1))
                } else {
                    // A subtle accent sheen from the top-left corner over the glass.
                    shape.fill(
                        LinearGradient(
                            colors: [accent.opacity(0.16), .clear, .white.opacity(0.03)], startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                }
            }
            .modifier(GlassBackground(enabled: !reduceTransparency, cornerRadius: cornerRadius))
    }
}

private struct GlassBackground: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}

/// Icon, metric name and subtitle on the left, the large figure on the right.
struct MetricHeader: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var figure: String
    var tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(figure)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A small glass capsule with a short fact ("10 cores", "Swap 1.2 GB").
struct InfoPill: View {
    var text: String
    var tint: Color?
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            if let tint {
                Circle().fill(tint.gradient).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
        .help(help ?? text)
    }
}

/// A thin capsule bar, filled to `fraction` (clamped; nil shows an empty track).
struct ThinBar: View {
    var fraction: Double?
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(tint.gradient)
                .frame(width: proxy.size.width * (fraction.flatMap(MetricFraction.clamped) ?? 0))
        }
        .frame(height: 5)
        .background(.primary.opacity(0.10), in: .capsule)
        .clipShape(.capsule)
        .animation(.smooth, value: fraction)
    }
}

/// History line with a soft fill below it. Fewer than two points: a flat baseline, never a crash.
struct Sparkline: View {
    var values: [Double]
    var domain: SparklineScale.Domain = .unit
    /// Points the full width stands for, so the line grows from the right while the history fills up.
    var capacity: Int
    var tint: Color

    var body: some View {
        let heights = SparklineScale.normalized(values, domain: domain)
        GeometryReader { proxy in
            let size = proxy.size
            if heights.count >= 2 {
                let step = size.width / CGFloat(max(1, capacity - 1))
                let start = size.width - step * CGFloat(heights.count - 1)
                let points = heights.enumerated().map { index, height in
                    CGPoint(x: start + step * CGFloat(index), y: size.height * (1 - CGFloat(height)))
                }
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: size.height))
                    for point in points { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { path in path.addLines(points) }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                    path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                }
                .stroke(.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

/// Pills that wrap onto as many lines as needed.
struct PillRow: View {
    var pills: [InfoPill]

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in pill }
        }
    }
}

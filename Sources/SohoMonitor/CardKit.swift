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
    static let nas = Color.indigo
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
    /// Gap between the card's rows; the compact CPU and memory cards use less.
    var spacing: CGFloat = 8
    /// Inner margin; the compact CPU and memory cards use less vertical room.
    var padding = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Icon and metric name on the left, the large figure on the right; the subtitle (chip name, "6.0 GB of 16.0 GB")
/// on its own line below, with the card's full width: next to the figure a half-width card had no room for it.
struct MetricHeader: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var figure: String
    var tint: Color
    /// A smaller icon and figure and a tighter subtitle gap, for the compact CPU and memory cards.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                    .background(tint.gradient, in: .circle)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(figure)
                    .font(.system(size: compact ? 24 : 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize()
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle)
            }
        }
    }
}

/// A small glass capsule with a short fact ("10 cores", "Swap 1.2 GB"); opaque under Reduce Transparency.
struct InfoPill: View {
    var text: String
    var tint: Color?
    var help: String?
    /// What VoiceOver reads when the visible text is a shortened form (the compact pressure pill); else the text.
    var spoken: String?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let label = HStack(spacing: 4) {
            if let tint {
                Circle().fill(tint.gradient).frame(width: 6, height: 6)
            }
            if let spoken {
                Text(text).truncationMode(.tail).accessibilityLabel(spoken)
            } else {
                Text(text).truncationMode(.tail)
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .help(help ?? text)
        if reduceTransparency {
            label.background(Color(nsColor: .controlBackgroundColor), in: .capsule)
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
        } else {
            label.glassEffect(.regular, in: .capsule)
        }
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
    /// Drawing height; the compact CPU and memory cards use a shorter one.
    var height: CGFloat = 30

    var body: some View {
        let heights = SparklineScale.normalized(values, domain: domain)
        GeometryReader { proxy in
            let size = proxy.size
            if heights.count >= 2 {
                let step = size.width / CGFloat(max(1, capacity - 1))
                let start = size.width - step * CGFloat(heights.count - 1)
                let points = heights.enumerated().map { index, level in
                    CGPoint(x: start + step * CGFloat(index), y: size.height * (1 - CGFloat(level)))
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
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Calls `action` with the pointer's location (view coordinates, origin top-left) while it is over the view, and
    /// with nil when it leaves. Unlike `onHover` / `onContinuousHover`, which never fired in the desktop panel (an
    /// agent app is not active, its panel never key), it uses an always-active AppKit tracking area. Clicks and drags
    /// go through to the view below.
    func onPointer(_ action: @escaping @MainActor (CGPoint?) -> Void) -> some View {
        overlay(PointerTracker(action: action))
    }
}

private struct PointerTracker: NSViewRepresentable {
    let action: @MainActor (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.action = action
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.action = action
    }

    final class TrackingView: NSView {
        var action: (@MainActor (CGPoint?) -> Void)?

        override var isFlipped: Bool { true }

        // Transparent to clicks: only the tracking area matters.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { action?(nil) }

        // Removed while under the pointer: no exit arrives, so report one, after the SwiftUI update that removed it.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window == nil, let action else { return }
            Task { @MainActor in action(nil) }
        }

        private func report(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            action?(bounds.contains(point) ? point : nil)
        }
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

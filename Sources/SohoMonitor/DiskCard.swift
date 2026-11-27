import SohoMonitorCore
import SwiftUI

/// The disk card: volume, used / total, free-space pill, one continuous segmented bar, legend chips, the top 3
/// folders of the selected group, and the scan status. Native Liquid Glass (macOS 26).
/// Hovering the bar or a chip highlights that segment and puts its name, size and share in the header; the legend
/// shows the biggest groups only, a chip unfolds the rest until the panel is hidden.
struct DiskCard: View {
    static let width: CGFloat = 420
    /// Chips shown while the legend is folded.
    static let compactLegendCount = 3

    let model: AppModel
    let onDrag: (DesktopPanelController.DragPhase) -> Void
    let onResetPosition: () -> Void

    @State private var openGroup: String?
    /// One hover state for the bar and the chips, so both highlight the same segment.
    @State private var hovered: BarSegment.Kind?
    /// Not persisted: folded again whenever the panel is hidden.
    @State private var legendExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = model.snapshot {
                let groups = DiskSummary.groups(of: snapshot)
                let scale = DiskSummary.barScale(of: snapshot, groups: groups)
                let hoverText = hovered.flatMap {
                    DiskBar.summary(of: $0, groups: groups, free: snapshot.free, scale: scale)
                }
                header(snapshot, hoverText: hoverText, groups: groups)
                SegmentedBar(groups: groups, free: snapshot.free, scale: scale, hovered: $hovered)
                legend(groups)
                if let name = openGroup, let group = groups.first(where: { $0.name == name }) {
                    TopFolders(group: group, tops: snapshot.tops.filter { $0.group == name })
                }
            } else {
                MetricHeader(symbol: "internaldrive", title: "Disk", figure: "—", tint: CardColor.disk, compact: true)
                Text(model.isScanning ? "First scan in progress…" : "No disk data yet")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ConfigProblems(state: model.configState, url: model.configURL)
            footer
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .frame(width: Self.width, alignment: .leading)
        .background(
            // A subtle top-left sheen over the glass, as on the widget.
            LinearGradient(
                colors: [.white.opacity(0.10), .clear, .white.opacity(0.04)], startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 28)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .contentShape(.rect(cornerRadius: 28))
        .onTapGesture(count: 2, perform: onResetPosition)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in onDrag(.changed) }
                .onEnded { _ in onDrag(.ended) }
        )
        .padding(12)  // room for the glass's own shadow inside the transparent panel
        .onChange(of: model.panelVisible) { _, visible in
            guard !visible else { return }
            legendExpanded = false
            hovered = nil  // no hover end arrives once the panel is ordered out
        }
        // A new snapshot may drop the hovered group (and bring it back later): start again from the next move.
        .onChange(of: model.snapshot?.updated) { hovered = nil }
    }

    /// The CPU and memory cards' header (icon, "Disk", used share as the large figure), then "X of Y used" and the
    /// free-space pill. While a segment is hovered, its line replaces "X of Y used"; both stay in the layout (one
    /// hidden) so the card keeps its size. The volume name is left to VoiceOver: on the startup disk it repeats
    /// "Disk".
    private func header(_ snapshot: DiskSnapshot, hoverText: String?, groups: [DiskGroup]) -> some View {
        let figure = PercentFormat.whole(DiskSummary.usedFraction(of: snapshot))
        return VStack(alignment: .leading, spacing: 6) {
            MetricHeader(symbol: "internaldrive", title: "Disk", figure: figure, tint: CardColor.disk, compact: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Disk, \(snapshot.volume.isEmpty ? "startup disk" : snapshot.volume)")
                .accessibilityValue("\(figure) used")
            usageLine(snapshot, hoverText: hoverText, groups: groups)
        }
    }

    private func usageLine(_ snapshot: DiskSnapshot, hoverText: String?, groups: [DiskGroup]) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                let used = Text(ByteFormat.short(snapshot.used))
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                ZStack(alignment: .leading) {
                    Text("\(used) of \(ByteFormat.short(snapshot.total)) used")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .opacity(hoverText == nil ? 1 : 0)
                    if let hoverText, let hovered {
                        HStack(spacing: 5) {
                            SegmentDot(kind: hovered, groups: groups)
                            Text(hoverText)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .accessibilityHidden(true)  // VoiceOver reads the same from the bar's segments
                    }
                }
            }
            Spacer()
            Text("\(ByteFormat.short(snapshot.free)) free")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.free(model.freeLevel))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        }
    }

    /// Folded: the biggest groups (and the open one) then a "+N more" chip; unfolded: every group then "Less".
    /// Changes that resize the panel are not animated: an animated window resize of the desktop panel crashed the app
    /// (stack overflow in Auto Layout, reproduced on main by opening a chip).
    private func legend(_ groups: [DiskGroup]) -> some View {
        let compact = DiskSummary.compactLegend(groups, limit: Self.compactLegendCount, keeping: openGroup)
        return FlowLayout(spacing: 6, lineSpacing: 5) {
            ForEach(legendExpanded ? groups : compact.shown) { group in
                LegendChip(group: group, selected: openGroup == group.name) {
                    openGroup = openGroup == group.name ? nil : group.name
                }
                .onPointer { point in
                    let kind = BarSegment.Kind.group(group.name)
                    hovered = point != nil ? kind : (hovered == kind ? nil : hovered)
                }
            }
            if compact.hiddenCount > 0 {
                LegendToggle(expanded: legendExpanded, hiddenCount: compact.hiddenCount) {
                    legendExpanded.toggle()
                    hovered = nil  // a chip folded away under the pointer sends no exit
                }
            }
        }
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 6) {
                if model.isScanning {
                    ProgressView().controlSize(.mini)
                    Text("Scanning…")
                } else if let snapshot = model.snapshot {
                    Text("Updated \(RelativeAge.string(from: snapshot.updated, now: context.date))")
                }
                if let error = model.lastScanError {
                    Text("· scan failed: \(error)").foregroundStyle(.red).lineLimit(1)
                } else if model.snapshot?.categories.contains(where: \.partial) == true {
                    Text("· ⚠︎ partial: grant Full Disk Access to SohoMonitor")
                        .foregroundStyle(Palette.warning)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.tertiary)
        }
    }
}

/// Apple system colours, in group order (biggest first); fixed greys for the computed groups.
enum Palette {
    static let groups: [Color] = [.blue, .orange, .purple, .green, .pink, .cyan, .yellow, .indigo, .teal]
    static let warning = Color.yellow

    static func color(_ slot: ColorSlot) -> Color {
        switch slot {
        case .palette(let index): groups[index % groups.count]
        case .macOS: Color(nsColor: .systemGray)
        case .other: Color(nsColor: .systemGray).opacity(0.55)
        }
    }

    static func free(_ level: FreeSpaceLevel) -> Color {
        switch level {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// One continuous glass capsule: adjoining segments split by a hairline, a single gloss over the whole bar. Drawn from
/// `DiskBar.layout`, which the hover test reads too, so the highlighted segment is the one under the pointer.
private struct SegmentedBar: View {
    let groups: [DiskGroup]
    let free: Int64
    let scale: Int64
    @Binding var hovered: BarSegment.Kind?

    var body: some View {
        GeometryReader { proxy in
            let segments = DiskBar.layout(groups: groups, free: free, scale: scale, width: proxy.size.width)
            // A hover left over from a group gone after a rescan dims nothing.
            let lit = segments.contains { $0.kind == hovered } ? hovered : nil
            ZStack(alignment: .leading) {
                ForEach(segments, id: \.kind) { segment in
                    fill(segment)
                        .frame(width: segment.width)
                        .overlay(alignment: .leading) {
                            if segment.start > 0 { Rectangle().fill(.black.opacity(0.35)).frame(width: 1) }
                        }
                        .opacity(lit == nil || lit == segment.kind ? 1 : 0.55)
                        .offset(x: segment.start)
                        .accessibilityElement()
                        .accessibilityLabel(segment.name)
                        .accessibilityValue(
                            "\(ByteFormat.short(segment.bytes)), \(DiskBar.share(segment.bytes, of: scale))")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .onPointer { point in hovered = point.flatMap { DiskBar.segment(at: $0.x, in: segments)?.kind } }
        }
        .frame(height: 14)
        .background(.black.opacity(0.18))
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.45), location: 0), .init(color: .white.opacity(0.1), location: 0.46),
                    .init(color: .black.opacity(0.1), location: 0.54), .init(color: .black.opacity(0.18), location: 1),
                ], startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .clipShape(.capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .animation(.smooth, value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk usage")
    }

    /// A group in its colour; the free space is the bare track, lit while hovered.
    @ViewBuilder private func fill(_ segment: BarSegment) -> some View {
        switch segment.kind {
        case .group(let name):
            Rectangle().fill(Palette.color(colorSlot(of: name, in: groups)).gradient)
        case .free:
            Rectangle().fill(.white.opacity(hovered == .free ? 0.22 : 0))
        }
    }
}

private func colorSlot(of name: String, in groups: [DiskGroup]) -> ColorSlot {
    groups.first(where: { $0.name == name })?.colorSlot ?? .other
}

/// The colour of the hovered segment, before its line in the header; a ring for the free space.
private struct SegmentDot: View {
    let kind: BarSegment.Kind
    let groups: [DiskGroup]

    var body: some View {
        switch kind {
        case .group(let name):
            Circle().fill(Palette.color(colorSlot(of: name, in: groups)).gradient).frame(width: 8, height: 8)
        case .free:
            Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }
}

/// "+N more" while folded, "Less" while unfolded; a chip like the others so it reads as part of the legend.
private struct LegendToggle: View {
    let expanded: Bool
    let hiddenCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(expanded ? "Less" : "+\(hiddenCount) more")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(expanded ? "Show fewer categories" : "Show \(hiddenCount) more categories")
        .help(expanded ? "Show the biggest categories only" : "Show every category")
    }
}

private struct LegendChip: View {
    let group: DiskGroup
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.color(group.colorSlot).gradient)
                    .overlay(
                        Circle().fill(
                            RadialGradient(
                                colors: [.white.opacity(0.8), .clear], center: UnitPoint(x: 0.32, y: 0.28),
                                startRadius: 0, endRadius: 4))
                    )
                    .frame(width: 9, height: 9)
                Text(group.name).foregroundStyle(.primary)
                Text(ByteFormat.short(group.bytes))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if group.partial {
                    Text("⚠︎").foregroundStyle(Palette.warning).help("Partial: some folders could not be read")
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .glassEffect(
            selected ? .regular.tint(.white.opacity(0.18)).interactive() : .regular.interactive(), in: .capsule
        )
        .help(group.detail)
    }
}

/// The three biggest folders of a group, each with a gauge relative to the group.
private struct TopFolders: View {
    let group: DiskGroup
    let tops: [TopFolder]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top \(group.name)".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.secondary)
            if tops.isEmpty {
                Text(isComputed ? "Computed, no folder breakdown." : "No folder breakdown yet (next scan).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(tops, id: \.path) { top in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text((top.path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(ByteFormat.short(top.bytes))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(PathDisplay.abbreviated(top.path, home: NSHomeDirectory()))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Capsule()
                        .fill(.black.opacity(0.2))
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Palette.color(group.colorSlot).gradient)
                                    .frame(width: proxy.size.width * share(top.bytes))
                            }
                        }
                }
                .help(top.path)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var isComputed: Bool { group.colorSlot == .macOS || group.colorSlot == .other }

    private func share(_ bytes: Int64) -> CGFloat {
        group.bytes > 0 ? CGFloat(min(1, Double(bytes) / Double(group.bytes))) : 0
    }
}

/// Configuration errors (last valid configuration still in use) and warnings, with the file to edit.
private struct ConfigProblems: View {
    let state: ConfigState
    let url: URL

    var body: some View {
        if !state.errors.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    state.hasValidConfig
                        ? "Config error: the last valid configuration stays in use" : "Config error: nothing to scan"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                ForEach(Array(state.errors.prefix(4).enumerated()), id: \.offset) { _, issue in
                    Text(issue.description).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if state.errors.count > 4 {
                    Text("… and \(state.errors.count - 4) more").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Text(PathDisplay.abbreviated(url.path, home: NSHomeDirectory()))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
        } else if !state.warnings.isEmpty {
            Text("Config: \(state.warnings.map(\.description).joined(separator: "; "))")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }
}

/// Chips that wrap onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let last = rows[rows.count - 1]
            if !last.indices.isEmpty, last.width + spacing + size.width > width {
                rows.append(Row())
            }
            let current = rows[rows.count - 1]
            rows[rows.count - 1].width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            rows[rows.count - 1].height = max(current.height, size.height)
            rows[rows.count - 1].indices.append(index)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

import SohoMonitorCore
import SwiftUI

/// The disk card: volume, used / total, free-space pill, one continuous segmented bar, legend chips, the top 3
/// folders of the selected group, and the scan status. Native Liquid Glass (macOS 26).
struct DiskCard: View {
    static let width: CGFloat = 420

    let model: AppModel
    let onDrag: (DesktopPanelController.DragPhase) -> Void
    let onResetPosition: () -> Void

    @State private var openGroup: String?
    @State private var hoveredGroup: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = model.snapshot {
                let groups = DiskSummary.groups(of: snapshot)
                header(snapshot)
                SegmentedBar(
                    groups: groups, scale: DiskSummary.barScale(of: snapshot, groups: groups),
                    hovered: $hoveredGroup)
                legend(groups)
                if let name = hoveredGroup, let group = groups.first(where: { $0.name == name }) {
                    HoverDetail(group: group)
                }
                if let name = openGroup, let group = groups.first(where: { $0.name == name }) {
                    TopFolders(group: group, tops: snapshot.tops.filter { $0.group == name })
                }
            } else {
                Text("Disk").font(.system(size: 15, weight: .semibold))
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
    }

    private func header(_ snapshot: DiskSnapshot) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.volume.isEmpty ? "Startup disk" : snapshot.volume)
                    .font(.system(size: 15, weight: .semibold))
                let used = Text(ByteFormat.short(snapshot.used))
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                Text("\(used) of \(ByteFormat.short(snapshot.total)) used")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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

    private func legend(_ groups: [DiskGroup]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 5) {
            ForEach(groups) { group in
                LegendChip(group: group, selected: openGroup == group.name) {
                    withAnimation(.snappy) { openGroup = openGroup == group.name ? nil : group.name }
                }
                .onHover { hoveredGroup = $0 ? group.name : (hoveredGroup == group.name ? nil : hoveredGroup) }
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

/// One continuous glass capsule: adjoining segments split by a hairline, a single gloss over the whole bar.
private struct SegmentedBar: View {
    let groups: [DiskGroup]
    let scale: Int64
    @Binding var hovered: String?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Rectangle()
                        .fill(Palette.color(group.colorSlot).gradient)
                        .frame(width: max(3, proxy.size.width * fraction(group.bytes)))
                        .overlay(alignment: .leading) {
                            if index > 0 { Rectangle().fill(.black.opacity(0.35)).frame(width: 1) }
                        }
                        .opacity(hovered == nil || hovered == group.name ? 1 : 0.55)
                        .onHover { hovered = $0 ? group.name : (hovered == group.name ? nil : hovered) }
                        .help(group.detail)
                }
                Spacer(minLength: 0)
            }
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
    }

    private func fraction(_ bytes: Int64) -> CGFloat {
        scale > 0 ? CGFloat(Double(bytes) / Double(scale)) : 0
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

private struct HoverDetail: View {
    let group: DiskGroup

    var body: some View {
        Text(group.detail)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
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
private struct FlowLayout: Layout {
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

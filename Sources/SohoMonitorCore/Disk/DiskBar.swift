import Foundation

/// One stretch of the disk card's bar: a group, or the free space after the last group.
public struct BarSegment: Sendable, Equatable {
    public enum Kind: Sendable, Hashable {
        case group(String)
        case free

        public var name: String {
            switch self {
            case .group(let name): name
            case .free: "Free"
            }
        }
    }

    public var kind: Kind
    public var bytes: Int64
    /// Leading edge, in points from the bar's leading edge.
    public var start: Double
    public var width: Double

    public var end: Double { start + width }

    /// Name shown on hover and read by VoiceOver.
    public var name: String { kind.name }
}

/// Geometry of the bar, shared by its drawing and its hit test so the hovered segment is the one drawn under the
/// pointer.
public enum DiskBar {
    /// A group never narrower than this, so a small one stays visible and hoverable.
    public static let minimumSegmentWidth = 3.0

    /// Groups left to right at their share of `scale`, at least `minimumWidth` wide, cut at the end of the bar (a
    /// group left with no room is dropped); then the free space over the rest of the bar when there is some. Zero-size
    /// groups, a zero scale or a zero width give no segment.
    public static func layout(
        groups: [DiskGroup], free: Int64, scale: Int64, width: Double, minimumWidth: Double = minimumSegmentWidth
    ) -> [BarSegment] {
        guard scale > 0, width > 0 else { return [] }
        var segments: [BarSegment] = []
        var cursor = 0.0
        for group in groups where group.bytes > 0 {
            let natural = width * Double(group.bytes) / Double(scale)
            let segmentWidth = min(max(minimumWidth, natural), width - cursor)
            guard segmentWidth > 0 else { break }
            segments.append(
                BarSegment(kind: .group(group.name), bytes: group.bytes, start: cursor, width: segmentWidth))
            cursor += segmentWidth
        }
        if free > 0, cursor < width {
            segments.append(BarSegment(kind: .free, bytes: free, start: cursor, width: width - cursor))
        }
        return segments
    }

    /// The segment under `x`: each one covers [start, end), the last one also its end (the bar's trailing pixel).
    /// Nil outside the bar or over the bare track past the last segment.
    public static func segment(at x: Double, in segments: [BarSegment]) -> BarSegment? {
        if let hit = segments.first(where: { $0.start <= x && x < $0.end }) { return hit }
        if let last = segments.last, x == last.end { return last }
        return nil
    }

    /// Whole percent of the bar: "<1%" for a sliver that is not nothing, "0%" with no scale.
    public static func share(_ bytes: Int64, of scale: Int64) -> String {
        guard scale > 0, bytes > 0 else { return "0%" }
        let percent = Double(bytes) / Double(scale) * 100
        return percent < 0.5 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    /// Hover line of a segment: "Dev · 50.0 GB · 10%". Nil for a group the snapshot no longer has, or no free space
    /// (a hover left over from before a rescan shows nothing rather than a stale figure).
    public static func summary(of kind: BarSegment.Kind, groups: [DiskGroup], free: Int64, scale: Int64) -> String? {
        let bytes: Int64
        switch kind {
        case .group(let name):
            guard let group = groups.first(where: { $0.name == name }) else { return nil }
            bytes = group.bytes
        case .free:
            guard free > 0 else { return nil }
            bytes = free
        }
        return "\(kind.name) · \(ByteFormat.short(bytes)) · \(share(bytes, of: scale))"
    }
}

/// The legend chips to show when the legend is folded, and how many are left out.
public struct LegendSelection: Sendable, Equatable {
    public var shown: [DiskGroup]
    public var hiddenCount: Int

    public init(shown: [DiskGroup], hiddenCount: Int) {
        self.shown = shown
        self.hiddenCount = hiddenCount
    }
}

extension DiskSummary {
    /// The `limit` biggest groups (a tie goes to the one first in the bar), plus `keeping` (the group whose folders
    /// are open) when it is not among them, in the bar's order so chips and segments line up.
    public static func compactLegend(_ groups: [DiskGroup], limit: Int, keeping: String? = nil) -> LegendSelection {
        let biggest = groups.indices
            .sorted { groups[$0].bytes != groups[$1].bytes ? groups[$0].bytes > groups[$1].bytes : $0 < $1 }
            .prefix(max(0, limit))
        var kept = Set(biggest)
        if let keeping, let index = groups.firstIndex(where: { $0.name == keeping }) { kept.insert(index) }
        let shown = groups.indices.filter(kept.contains).map { groups[$0] }
        return LegendSelection(shown: shown, hiddenCount: groups.count - shown.count)
    }
}

import Foundation
import Testing

@testable import SohoMonitorCore

private let gb: Int64 = 1_000_000_000

private func group(_ name: String, _ bytes: Int64, slot: ColorSlot = .palette(0)) -> DiskGroup {
    DiskGroup(name: name, bytes: bytes, partial: false, items: [], colorSlot: slot)
}

@Suite struct DiskBarLayoutTests {
    @Test func segmentsFollowTheirShareThenTheFreeSpaceFillsTheRest() {
        // 500 GB disk drawn 100 pt wide: 1 pt = 5 GB.
        let segments = DiskBar.layout(
            groups: [group("Dev", 100 * gb), group("Photos", 50 * gb)], free: 350 * gb, scale: 500 * gb, width: 100)
        #expect(segments.map(\.kind) == [.group("Dev"), .group("Photos"), .free])
        #expect(segments.map(\.start) == [0, 20, 30])
        #expect(segments.map(\.width) == [20, 10, 70])
        #expect(segments.map(\.bytes) == [100 * gb, 50 * gb, 350 * gb])
    }

    @Test func aTinyGroupKeepsTheMinimumWidthAndPushesTheNextOnes() {
        let segments = DiskBar.layout(
            groups: [group("Tiny", 1), group("Dev", 100 * gb)], free: 400 * gb, scale: 500 * gb, width: 100)
        #expect(segments.map(\.start) == [0, 3, 23])
        #expect(segments.map(\.width) == [3, 20, 77])
    }

    @Test func segmentsNeverRunPastTheEndOfTheBar() {
        // Minimum widths that add up to more than the bar: the last ones are squeezed, then dropped.
        let segments = DiskBar.layout(
            groups: [group("A", 1), group("B", 1), group("C", 1)], free: 0, scale: 10, width: 7)
        #expect(segments.map(\.kind) == [.group("A"), .group("B"), .group("C")])
        #expect(segments.map(\.width) == [3, 3, 1])
        #expect(segments.last?.end == 7)
        let squeezed = DiskBar.layout(
            groups: [group("A", 1), group("B", 1), group("C", 1)], free: 5, scale: 10, width: 6)
        #expect(squeezed.map(\.kind) == [.group("A"), .group("B")])
    }

    @Test func zeroSizeGroupsAndAFullDiskHaveNoSegment() {
        let segments = DiskBar.layout(
            groups: [group("Empty", 0), group("Dev", 500 * gb)], free: 0, scale: 500 * gb, width: 100)
        #expect(segments.map(\.kind) == [.group("Dev")])
        #expect(segments.map(\.width) == [100])
    }

    @Test func noScaleOrNoWidthMeansNoSegment() {
        #expect(DiskBar.layout(groups: [group("Dev", 1)], free: 1, scale: 0, width: 100).isEmpty)
        #expect(DiskBar.layout(groups: [group("Dev", 1)], free: 1, scale: 10, width: 0).isEmpty)
        #expect(DiskBar.layout(groups: [], free: 0, scale: 10, width: 100).isEmpty)
    }
}

@Suite struct DiskBarHitTests {
    private let segments = DiskBar.layout(
        groups: [group("Dev", 100 * gb), group("Tiny", 1), group("Photos", 50 * gb)], free: 350 * gb,
        scale: 500 * gb, width: 100)

    static let hits: [(Double, BarSegment.Kind?)] = [
        (-0.5, nil), (0, .group("Dev")), (19.9, .group("Dev")), (20, .group("Tiny")), (22.9, .group("Tiny")),
        (23, .group("Photos")), (33, .free), (99.9, .free), (100, .free), (100.1, nil),
    ]

    @Test(arguments: hits)
    func aPointFindsTheSegmentUnderIt(x: Double, kind: BarSegment.Kind?) {
        #expect(DiskBar.segment(at: x, in: segments)?.kind == kind)
    }

    @Test func theTrackPastTheLastSegmentIsNotHit() {
        // No free space and a group smaller than the bar: the rest of the track is nothing.
        let partial = DiskBar.layout(groups: [group("Dev", 50)], free: 0, scale: 100, width: 100)
        #expect(DiskBar.segment(at: 49, in: partial)?.kind == .group("Dev"))
        #expect(DiskBar.segment(at: 50, in: partial)?.kind == .group("Dev"))
        #expect(DiskBar.segment(at: 51, in: partial) == nil)
        #expect(DiskBar.segment(at: 1, in: []) == nil)
    }
}

@Suite struct DiskBarTextTests {
    static let shares: [(Int64, String)] = [(0, "0%"), (1, "<1%"), (4, "<1%"), (5, "1%"), (994, "99%"), (1000, "100%")]

    @Test(arguments: shares)
    func shareIsAWholePercentOfTheBar(bytes: Int64, text: String) {
        #expect(DiskBar.share(bytes, of: 1000) == text)
    }

    @Test func shareOfAnEmptyScaleIsZero() {
        #expect(DiskBar.share(10, of: 0) == "0%")
    }

    @Test func summaryNamesTheSegmentItsSizeAndShare() {
        let groups = [group("Dev", 50 * gb)]
        #expect(
            DiskBar.summary(of: .group("Dev"), groups: groups, free: 450 * gb, scale: 500 * gb) == "Dev · 50.0 GB · 10%"
        )
        #expect(DiskBar.summary(of: .free, groups: groups, free: 450 * gb, scale: 500 * gb) == "Free · 450.0 GB · 90%")
    }

    @Test func summaryOfAGoneGroupOrNoFreeSpaceIsNil() {
        let groups = [group("Dev", 50 * gb)]
        #expect(DiskBar.summary(of: .group("Gone"), groups: groups, free: 1, scale: 500 * gb) == nil)
        #expect(DiskBar.summary(of: .free, groups: groups, free: 0, scale: 500 * gb) == nil)
    }
}

@Suite struct CompactLegendTests {
    private let groups = [
        group("Dev", 50 * gb, slot: .palette(0)), group("Photos", 30 * gb, slot: .palette(1)),
        group("Cloud", 5 * gb, slot: .palette(2)), group("Music", 1 * gb, slot: .palette(3)),
        group("macOS", 20 * gb, slot: .macOS), group("Other", 90 * gb, slot: .other),
    ]

    @Test func showsTheBiggestGroupsInTheBarOrder() {
        let legend = DiskSummary.compactLegend(groups, limit: 3)
        #expect(legend.shown.map(\.name) == ["Dev", "Photos", "Other"])
        #expect(legend.hiddenCount == 3)
    }

    @Test func fewerGroupsThanTheLimitAreAllShown() {
        let legend = DiskSummary.compactLegend(Array(groups.prefix(3)), limit: 3)
        #expect(legend.shown.map(\.name) == ["Dev", "Photos", "Cloud"])
        #expect(legend.hiddenCount == 0)
        #expect(DiskSummary.compactLegend([], limit: 3) == LegendSelection(shown: [], hiddenCount: 0))
    }

    @Test func aTieIsBrokenByTheBarOrder() {
        let tied = [group("A", 10), group("B", 5), group("C", 5), group("D", 5)]
        #expect(DiskSummary.compactLegend(tied, limit: 2).shown.map(\.name) == ["A", "B"])
    }

    @Test func theOpenGroupStaysVisible() {
        let legend = DiskSummary.compactLegend(groups, limit: 3, keeping: "Music")
        #expect(legend.shown.map(\.name) == ["Dev", "Photos", "Music", "Other"])
        #expect(legend.hiddenCount == 2)
        // Already among the biggest, or unknown: nothing added.
        #expect(DiskSummary.compactLegend(groups, limit: 3, keeping: "Dev").shown.count == 3)
        #expect(DiskSummary.compactLegend(groups, limit: 3, keeping: "Gone").shown.count == 3)
    }

    @Test func aNonPositiveLimitShowsOnlyTheKeptGroup() {
        #expect(DiskSummary.compactLegend(groups, limit: 0).shown.isEmpty)
        #expect(DiskSummary.compactLegend(groups, limit: -1, keeping: "Cloud").shown.map(\.name) == ["Cloud"])
    }
}

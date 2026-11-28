import Testing

@testable import SohoMonitorCore

private let gb: Int64 = 1_000_000_000

private func measure(_ path: String, _ bytes: Int64, _ children: [(String, Int64)] = [], partial: Bool = false)
    -> DuMeasurement
{
    DuMeasurement(
        path: path, bytes: bytes, children: children.map { DuEntry(path: $0.0, bytes: $0.1) }, partial: partial)
}

@Suite struct DiskTallyTests {
    @Test func aPathCountedEarlierIsSubtractedFromTheContainingPath() {
        var tally = DiskTally()
        tally.startCategory(group: "Dev", label: "DerivedData")
        tally.add(measure("/u/Library/Developer/Xcode/DerivedData", 3 * gb))
        tally.startCategory(group: "Dev", label: "Xcode other")
        tally.add(
            measure(
                "/u/Library/Developer", 10 * gb,
                [("/u/Library/Developer/Xcode", 5 * gb), ("/u/Library/Developer/Toolchains", 5 * gb)]))
        let result = tally.finish()
        #expect(
            result.categories == [
                CategoryUsage(group: "Dev", label: "DerivedData", bytes: 3 * gb, partial: false),
                CategoryUsage(group: "Dev", label: "Xcode other", bytes: 7 * gb, partial: false),
            ])
    }

    @Test func netValuesAreNeverSubtractedTwice() {
        // Caches/Homebrew (1) counted first, then Caches (net 4 = 5 - 1), then Library (10 - 4 - 1 = 5).
        var tally = DiskTally()
        tally.startCategory(group: "Dev", label: "Homebrew")
        tally.add(measure("/u/Library/Caches/Homebrew", 1 * gb))
        tally.startCategory(group: "Caches", label: "Caches")
        tally.add(measure("/u/Library/Caches", 5 * gb))
        tally.startCategory(group: "Library", label: "Library")
        tally.add(measure("/u/Library", 10 * gb))
        #expect(tally.finish().categories.map(\.bytes) == [1 * gb, 4 * gb, 5 * gb])
    }

    @Test func netIsClampedAtZero() {
        // APFS clones are counted in full by du: a child can exceed its parent.
        var tally = DiskTally()
        tally.startCategory(group: "A", label: "A")
        tally.add(measure("/u/x/y", 8 * gb))
        tally.startCategory(group: "B", label: "B")
        tally.add(measure("/u/x", 5 * gb))
        #expect(tally.finish().categories.map(\.bytes) == [8 * gb, 0])
    }

    @Test func aPathInsideAnAlreadyCountedPathCountsZero() {
        var tally = DiskTally()
        tally.startCategory(group: "A", label: "Broad")
        tally.add(measure("/u/Library", 10 * gb))
        tally.startCategory(group: "B", label: "Narrow, listed too late")
        #expect(tally.isCounted("/u/Library/Caches"))
        #expect(tally.isCounted("/u/Library"))
        #expect(!tally.isCounted("/u/LibraryOld"))
        tally.add(measure("/u/Library/Caches", 2 * gb))
        #expect(tally.finish().categories.map(\.bytes) == [10 * gb, 0])
    }

    @Test func partialFlagSticksToItsCategory() {
        var tally = DiskTally()
        tally.startCategory(group: "App data", label: "Other apps")
        tally.add(measure("/u/Library/Application Support", 1 * gb))
        tally.add(measure("/u/Library/Containers", 1 * gb, partial: true))
        tally.startCategory(group: "Caches", label: "Caches")
        tally.add(measure("/u/Library/Caches", 1 * gb))
        #expect(tally.finish().categories.map(\.partial) == [true, false])
    }

    @Test func accessKindsStickToTheirCategory() {
        var tally = DiskTally()
        tally.startCategory(group: "App data", label: "Other apps")
        tally.add(
            DuMeasurement(
                path: "/u/Library/Application Support", bytes: 1 * gb, children: [], partial: true,
                unreadable: ["/u/Library/Application Support/Vendor/locked"]))
        tally.add(
            DuMeasurement(
                path: "/u/Library/Containers", bytes: 1 * gb, children: [], partial: true,
                unreadable: ["/u/Library/Containers/x/locked", "/u/Library/Application Support/Vendor/locked"]))
        tally.startCategory(group: "Mail", label: "Mail")
        tally.add(
            DuMeasurement(
                path: "/u/Library/Mail", bytes: 1 * gb, children: [], partial: true, fullDiskAccessDenied: true))
        let categories = tally.finish().categories
        #expect(categories.map(\.fullDiskAccessDenied) == [false, true])
        // Duplicates across paths of one category are listed once, in order.
        #expect(
            categories[0].unreadable == [
                "/u/Library/Application Support/Vendor/locked", "/u/Library/Containers/x/locked",
            ])
        #expect(categories[1].unreadable.isEmpty)
    }

    @Test func unreadableFoldersAreCappedPerCategory() {
        var tally = DiskTally()
        tally.startCategory(group: "App data", label: "Other apps")
        let many = (0..<(DiskTally.unreadableLimit + 5)).map { "/u/locked/\($0)" }
        tally.add(DuMeasurement(path: "/u/locked", bytes: 1, children: [], partial: true, unreadable: many))
        #expect(tally.finish().categories[0].unreadable == Array(many.prefix(DiskTally.unreadableLimit)))
    }

    @Test func specialBytesAreAddedAsIs() {
        var tally = DiskTally()
        tally.startCategory(group: "Dev", label: "iOS runtimes")
        tally.addBytes(16 * gb, partial: false)
        #expect(tally.finish().categories == [CategoryUsage(group: "Dev", label: "iOS runtimes", bytes: 16 * gb)])
    }

    @Test func categoriesWithoutAnyExistingPathAreStillListed() {
        var tally = DiskTally()
        tally.startCategory(group: "Dev", label: "Test simulators")
        tally.startCategory(group: "Dev", label: "Simulators")
        tally.add(measure("/u/sim", 1 * gb))
        #expect(tally.finish().categories.map(\.bytes) == [0, 1 * gb])
    }

    @Test func topThreePerGroupIsNetOfMoreSpecificCategories() {
        var tally = DiskTally()
        tally.startCategory(group: "App data", label: "Claude")
        tally.add(
            measure("/u/AS/Claude", 13 * gb, [("/u/AS/Claude/vm_bundles", 11 * gb), ("/u/AS/Claude/logs", 2 * gb)]))
        tally.startCategory(group: "App data", label: "Other apps")
        tally.add(
            measure(
                "/u/AS", 20 * gb,
                [
                    ("/u/AS/Claude", 13 * gb),  // counted by "Claude": net 0, never listed twice
                    ("/u/AS/Google", 1 * gb),
                    ("/u/AS/Slack", 3 * gb),
                ]))
        tally.startCategory(group: "Caches", label: "Caches")
        tally.add(measure("/u/Caches", 1 * gb))  // no children: the path itself is the candidate
        let tops = tally.finish().tops
        #expect(
            tops == [
                TopFolder(group: "App data", path: "/u/AS/Claude/vm_bundles", bytes: 11 * gb),
                TopFolder(group: "App data", path: "/u/AS/Slack", bytes: 3 * gb),
                TopFolder(group: "App data", path: "/u/AS/Claude/logs", bytes: 2 * gb),
                TopFolder(group: "Caches", path: "/u/Caches", bytes: 1 * gb),
            ])
    }

    @Test func topCandidateSubtractsWhatIsCountedBelowIt() {
        var tally = DiskTally()
        tally.startCategory(group: "Dev", label: "DerivedData")
        tally.add(measure("/u/Dev/Xcode/DerivedData", 4 * gb))
        tally.startCategory(group: "Dev", label: "Xcode other")
        tally.add(measure("/u/Dev", 9 * gb, [("/u/Dev/Xcode", 6 * gb), ("/u/Dev/Other", 3 * gb)]))
        #expect(
            tally.finish().tops == [
                TopFolder(group: "Dev", path: "/u/Dev/Xcode/DerivedData", bytes: 4 * gb),
                TopFolder(group: "Dev", path: "/u/Dev/Other", bytes: 3 * gb),
                TopFolder(group: "Dev", path: "/u/Dev/Xcode", bytes: 2 * gb),
            ])
    }

    @Test func topTiesAreOrderedByPathForStableOutput() {
        var tally = DiskTally()
        tally.startCategory(group: "G", label: "G")
        tally.add(measure("/r", 4 * gb, [("/r/b", 1 * gb), ("/r/a", 1 * gb), ("/r/d", 1 * gb), ("/r/c", 1 * gb)]))
        #expect(tally.finish().tops.map(\.path) == ["/r/a", "/r/b", "/r/c"])
    }
}

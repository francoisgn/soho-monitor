import Foundation
import Testing

@testable import SohoMonitorCore

private let gb: Int64 = 1_000_000_000

private func snapshot(_ categories: [CategoryUsage], total: Int64 = 500 * gb, free: Int64 = 200 * gb) -> DiskSnapshot {
    DiskSnapshot(
        updated: Date(timeIntervalSince1970: 1_800_000_000), duration: 12, volume: "Macintosh HD",
        total: total, used: total - free, free: free, categories: categories, tops: [])
}

@Suite struct DiskSnapshotAssemblyTests {
    @Test func otherIsUsedMinusMacOSMinusCounted() {
        let s = DiskSnapshot.assemble(
            categories: [CategoryUsage(group: "Dev", label: "Git", bytes: 100 * gb)],
            tops: [],
            volume: VolumeInfo(name: "Macintosh HD", total: 500 * gb, free: 200 * gb, containerReference: "disk3"),
            macOSBytes: 50 * gb,
            updated: Date(timeIntervalSince1970: 0), duration: 3)
        #expect(s.used == 300 * gb)
        #expect(
            s.categories == [
                CategoryUsage(group: "Dev", label: "Git", bytes: 100 * gb),
                CategoryUsage(group: "macOS", label: "macOS", bytes: 50 * gb),
                CategoryUsage(group: "Other", label: "Other", bytes: 150 * gb),
            ])
    }

    @Test func otherIsClampedAtZero() {
        // du counts APFS clones in full: categories can add up to more than the real usage.
        let s = DiskSnapshot.assemble(
            categories: [CategoryUsage(group: "Dev", label: "Sims", bytes: 400 * gb)],
            tops: [],
            volume: VolumeInfo(name: "HD", total: 500 * gb, free: 200 * gb, containerReference: "disk3"),
            macOSBytes: 50 * gb, updated: Date(timeIntervalSince1970: 0), duration: 1)
        #expect(s.categories.last == CategoryUsage(group: "Other", label: "Other", bytes: 0))
    }

    @Test func snapshotRoundTripsAndToleratesMissingOptionalFields() throws {
        let s = snapshot([CategoryUsage(group: "Dev", label: "Git", bytes: 1, partial: true)])
        let data = try DiskSnapshot.encoder.encode(s)
        #expect(try DiskSnapshot.decoder.decode(DiskSnapshot.self, from: data) == s)

        // A cache written without "tops" or "partial" (older or hand-made) still loads.
        let minimal = Data(
            """
            {"updated": 1800000000, "duration": 1, "volume": "HD", "total": 10, "used": 4, "free": 6,
             "categories": [{"group": "A", "label": "A", "bytes": 4}]}
            """.utf8)
        let decoded = try DiskSnapshot.decoder.decode(DiskSnapshot.self, from: minimal)
        #expect(decoded.tops.isEmpty)
        #expect(decoded.categories == [CategoryUsage(group: "A", label: "A", bytes: 4, partial: false)])
    }
}

@Suite struct DiskSummaryTests {
    @Test func groupsAreSortedBySizeWithMacOSAndOtherLast() {
        let s = snapshot([
            CategoryUsage(group: "Other", label: "Other", bytes: 90 * gb),
            CategoryUsage(group: "Dev", label: "Git", bytes: 10 * gb),
            CategoryUsage(group: "Photos", label: "Photos", bytes: 30 * gb),
            CategoryUsage(group: "Dev", label: "Agent work", bytes: 40 * gb, partial: true),
            CategoryUsage(group: "Dev", label: "Empty", bytes: 0),
            CategoryUsage(group: "Cloud", label: "Dropbox", bytes: 0),
            CategoryUsage(group: "macOS", label: "macOS", bytes: 20 * gb),
        ])
        let groups = DiskSummary.groups(of: s)
        #expect(groups.map(\.name) == ["Dev", "Photos", "macOS", "Other"])
        #expect(groups.map(\.bytes) == [50 * gb, 30 * gb, 20 * gb, 90 * gb])
        #expect(groups.map(\.colorSlot) == [.palette(0), .palette(1), .macOS, .other])
        #expect(groups[0].partial)
        #expect(!groups[1].partial)
        // Items of a group: non-empty ones, biggest first.
        #expect(groups[0].items.map(\.label) == ["Agent work", "Git"])
    }

    @Test func barScaleCoversCategoriesThatExceedTheDisk() {
        let normal = snapshot([CategoryUsage(group: "A", label: "A", bytes: 100 * gb)])
        #expect(DiskSummary.barScale(of: normal, groups: DiskSummary.groups(of: normal)) == 500 * gb)
        let clones = snapshot([CategoryUsage(group: "A", label: "A", bytes: 400 * gb)])
        #expect(DiskSummary.barScale(of: clones, groups: DiskSummary.groups(of: clones)) == 600 * gb)
    }

    static let levels: [(Int64, FreeSpaceLevel)] = [
        (200, .normal), (100, .normal), (99, .warning), (50, .warning), (49, .critical), (0, .critical),
    ]

    @Test(arguments: levels)
    func freeSpaceLevelFollowsThresholds(free: Int64, level: FreeSpaceLevel) {
        #expect(FreeSpaceLevel(free: free, total: 500, warningPercent: 20, criticalPercent: 10) == level)
    }

    @Test func zeroTotalIsNotADivisionByZero() {
        #expect(FreeSpaceLevel(free: 0, total: 0, warningPercent: 20, criticalPercent: 10) == .normal)
    }

    @Test func detailListsTheCategoriesOfAGroup() {
        let s = snapshot([
            CategoryUsage(group: "Dev", label: "Git", bytes: 10 * gb),
            CategoryUsage(group: "Dev", label: "Agent work", bytes: 40 * gb),
            CategoryUsage(group: "Photos", label: "Photos", bytes: 30 * gb),
        ])
        let groups = DiskSummary.groups(of: s)
        #expect(groups[0].detail == "Dev: 50.0 GB\n  Agent work: 40.0 GB\n  Git: 10.0 GB")
        #expect(groups[1].detail == "Photos: 30.0 GB")
    }

    @Test func menuSummaryLine() {
        let s = snapshot([], total: 494_384_795_648, free: 183_916_957_696)
        #expect(DiskSummary.menuLine(of: s) == "Macintosh HD: 183.9 GB free of 494.4 GB")
    }
}

@Suite struct ScanScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func scansNowWithoutAnySnapshot() {
        #expect(ScanSchedule.nextScan(lastUpdated: nil, intervalMinutes: 30, now: now) == now)
    }

    @Test func waitsForTheIntervalAfterTheLastScan() {
        let last = now.addingTimeInterval(-10 * 60)
        #expect(
            ScanSchedule.nextScan(lastUpdated: last, intervalMinutes: 30, now: now) == now.addingTimeInterval(20 * 60))
    }

    @Test func aStaleOrFutureSnapshotScansNow() {
        #expect(
            ScanSchedule.nextScan(lastUpdated: now.addingTimeInterval(-3 * 3600), intervalMinutes: 30, now: now) == now)
        // A clock moved backwards must not postpone the scan beyond one interval.
        #expect(
            ScanSchedule.nextScan(lastUpdated: now.addingTimeInterval(86_400), intervalMinutes: 30, now: now)
                == now.addingTimeInterval(30 * 60))
    }

    @Test func aFailedAttemptWaitsOneIntervalInsteadOfRetryingAtOnce() {
        // No snapshot (first run) or a stale one, and a scan that just failed: wait one interval, never loop.
        #expect(
            ScanSchedule.nextScan(lastUpdated: nil, lastAttempt: now, intervalMinutes: 30, now: now)
                == now.addingTimeInterval(30 * 60))
        #expect(
            ScanSchedule.nextScan(
                lastUpdated: now.addingTimeInterval(-3 * 3600), lastAttempt: now.addingTimeInterval(-5 * 60),
                intervalMinutes: 30, now: now) == now.addingTimeInterval(25 * 60))
    }
}

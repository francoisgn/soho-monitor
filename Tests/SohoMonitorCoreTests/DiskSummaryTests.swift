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

@Suite struct DiskSnapshotAccessCacheTests {
    @Test func accessFieldsRoundTrip() throws {
        let s = snapshot([
            CategoryUsage(
                group: "App data", label: "Other apps", bytes: 1, partial: true, fullDiskAccessDenied: false,
                unreadable: ["/Users/me/Library/Application Support/Vendor/locked"]),
            CategoryUsage(group: "Mail", label: "Mail", bytes: 1, partial: true, fullDiskAccessDenied: true),
        ])
        let data = try DiskSnapshot.encoder.encode(s)
        #expect(try DiskSnapshot.decoder.decode(DiskSnapshot.self, from: data) == s)
    }

    @Test func aCacheFromTheCurrentReleaseKeepsItsFullDiskAccessMessage() throws {
        // Written before the two kinds were told apart: "partial" then meant "grant Full Disk Access".
        let previous = Data(
            """
            {"updated": 1800000000, "duration": 1, "volume": "HD", "total": 10, "used": 4, "free": 6, "tops": [],
             "categories": [{"group": "A", "label": "A", "bytes": 4, "partial": true},
                            {"group": "B", "label": "B", "bytes": 0, "partial": false}]}
            """.utf8)
        let decoded = try DiskSnapshot.decoder.decode(DiskSnapshot.self, from: previous)
        #expect(decoded.categories.map(\.fullDiskAccessDenied) == [true, false])
        #expect(decoded.categories.allSatisfy { $0.unreadable.isEmpty })
        #expect(DiskSummary.partialNote(of: decoded.categories) == .fullDiskAccess(unreadable: []))
    }
}

@Suite struct PartialNoteTests {
    private let home = "/Users/me"
    private let locked = "/Users/me/Library/Application Support/Vendor/updater/1234.run"
    private let other = "/Users/me/Library/Caches/root-owned"

    @Test func completeScanHasNoNote() {
        #expect(DiskSummary.partialNote(of: [CategoryUsage(group: "A", label: "A", bytes: 1)]) == nil)
    }

    @Test func onlyPermissionDeniedNamesTheFoldersWithoutAskingForFullDiskAccess() {
        let note = DiskSummary.partialNote(of: [
            CategoryUsage(group: "A", label: "A", bytes: 1, partial: true, unreadable: [locked]),
            CategoryUsage(group: "B", label: "B", bytes: 1, partial: true, unreadable: [other, locked]),
        ])
        #expect(note == .unreadable([locked, other]))
        let text = note?.footer(home: home) ?? ""
        #expect(!text.contains("Full Disk Access"))
        #expect(text == "not readable by your user: ~/Library/Application Support/Vendor/…/1234.run +1 more")
        #expect(note?.isWarning == false)
        #expect(
            note?.detail(home: home)
                == """
                Folders not readable by your user (POSIX permissions; Full Disk Access does not change them):
                ~/Library/Application Support/Vendor/updater/1234.run
                ~/Library/Caches/root-owned
                """)
    }

    @Test func oneUnreadableFolderIsNamedAlone() {
        let note = DiskSummary.partialNote(of: [
            CategoryUsage(group: "A", label: "A", bytes: 1, partial: true, unreadable: [other])
        ])
        #expect(note?.footer(home: home) == "not readable by your user: ~/Library/Caches/root-owned")
    }

    @Test func operationNotPermittedKeepsTheFullDiskAccessMessage() {
        let note = DiskSummary.partialNote(of: [
            CategoryUsage(group: "Mail", label: "Mail", bytes: 1, partial: true, fullDiskAccessDenied: true)
        ])
        #expect(note == .fullDiskAccess(unreadable: []))
        #expect(note?.footer(home: home) == "partial: grant Full Disk Access to SohoMonitor")
        #expect(note?.isWarning == true)
        #expect(note?.detail(home: home) == "Some folders need Full Disk Access to be measured.")
    }

    @Test func bothKindsTheFullDiskAccessMessageWinsAndTheFoldersAreStillListed() {
        let note = DiskSummary.partialNote(of: [
            CategoryUsage(group: "A", label: "A", bytes: 1, partial: true, unreadable: [locked]),
            CategoryUsage(group: "Mail", label: "Mail", bytes: 1, partial: true, fullDiskAccessDenied: true),
        ])
        #expect(note == .fullDiskAccess(unreadable: [locked]))
        #expect(note?.footer(home: home) == "partial: grant Full Disk Access to SohoMonitor")
        #expect(
            note?.detail(home: home)
                == """
                Some folders need Full Disk Access to be measured.
                Folders not readable by your user (POSIX permissions; Full Disk Access does not change them):
                ~/Library/Application Support/Vendor/updater/1234.run
                """)
    }

    @Test func partialWithoutAnAccessErrorIsNeitherKind() {
        // simctl missing: the iOS runtimes are unknown, which no permission fixes.
        let note = DiskSummary.partialNote(of: [CategoryUsage(group: "Dev", label: "iOS", bytes: 0, partial: true)])
        #expect(note == .incomplete)
        #expect(note?.footer(home: home) == "partial: some sizes could not be measured")
        #expect(note?.footer(home: home).contains("Full Disk Access") == false)
    }

    @Test func groupsCarryTheirOwnNote() {
        let s = snapshot([
            CategoryUsage(group: "App data", label: "Other apps", bytes: 2 * gb, partial: true, unreadable: [locked]),
            CategoryUsage(group: "Mail", label: "Mail", bytes: 1 * gb, partial: true, fullDiskAccessDenied: true),
            CategoryUsage(group: "Dev", label: "Git", bytes: 3 * gb),
        ])
        let notes = Dictionary(uniqueKeysWithValues: DiskSummary.groups(of: s).map { ($0.name, $0.note) })
        #expect(notes["App data"] == .unreadable([locked]))
        #expect(notes["Mail"] == .fullDiskAccess(unreadable: []))
        #expect(notes["Dev"] == .some(nil))
    }

    @Test(arguments: [
        (
            "/Users/me/Library/Application Support/Vendor/updater/1234.run",
            "~/Library/Application Support/Vendor/…/1234.run"
        ),
        ("/Users/me/Library/Caches/root-owned", "~/Library/Caches/root-owned"),
        ("/Users/me/a/b/c/d", "~/a/b/c/d"),
        ("/Library/Application Support/Vendor/x/y/z", "/Library/Application Support/Vendor/…/z"),
        ("/Users/me", "~"),
    ])
    func shortPathKeepsTheHeadAndTheLeaf(path: String, short: String) {
        #expect(PathDisplay.short(path, home: "/Users/me") == short)
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

    @Test func usedFractionIsUsedOverTotalAndNilWithoutADisk() {
        #expect(DiskSummary.usedFraction(of: snapshot([], total: 500 * gb, free: 125 * gb)) == 0.75)
        #expect(DiskSummary.usedFraction(of: snapshot([], total: 0, free: 0)) == nil)
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

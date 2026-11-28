import Foundation
import Testing

@testable import SohoMonitorCore

private let gb: Int64 = 1_000_000_000

/// Plays back canned command outputs: no process is started, the real disk is never read.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String: CommandOutput]
    private(set) var calls: [String] = []

    init(_ outputs: [String: CommandOutput]) { self.outputs = outputs }

    static func key(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: " ")
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandOutput {
        let key = Self.key(executable, arguments)
        return try lock.withLock {
            calls.append(key)
            guard let output = outputs[key] else { throw ProbeError.commandFailed("no fixture for \(key)") }
            return output
        }
    }
}

struct FakePaths: PathResolving {
    var matches: [String: [String]]
    func resolve(_ pattern: String) -> [String] { matches[pattern] ?? [] }
}

private func out(_ stdout: String, _ stderr: String = "", status: Int32 = 0) -> CommandOutput {
    CommandOutput(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), status: status)
}

private func du(_ path: String) -> String { FakeRunner.key("/usr/bin/du", ["-k", "-d", "1", path]) }

private let diskutilOutputs: [String: CommandOutput] = [
    FakeRunner.key("/usr/sbin/diskutil", ["info", "-plist", "/"]): out(SystemFixtures.diskutilInfo),
    FakeRunner.key("/usr/sbin/diskutil", ["apfs", "list", "-plist", "disk3"]): out(SystemFixtures.apfsList),
]

@Suite struct DiskScannerTests {
    private let config = DiskConfig(categories: [
        DiskCategory(group: "Dev", label: "iOS runtimes", source: .iosRuntimes),
        DiskCategory(group: "Dev", label: "DerivedData", source: .paths(["~/Library/Developer/Xcode/DerivedData"])),
        DiskCategory(group: "Dev", label: "Xcode other", source: .paths(["~/Library/Developer"])),
        DiskCategory(group: "Cloud", label: "Dropbox", source: .paths(["~/Library/CloudStorage/Dropbox*"])),
        DiskCategory(group: "Mail", label: "Mail", source: .paths(["~/Library/Mail", "~/Library/Developer"])),
    ])

    private let paths = FakePaths(matches: [
        "~/Library/Developer/Xcode/DerivedData": ["/Users/me/Library/Developer/Xcode/DerivedData"],
        "~/Library/Developer": ["/Users/me/Library/Developer"],
        "~/Library/CloudStorage/Dropbox*": [
            "/Users/me/Library/CloudStorage/Dropbox", "/Users/me/Library/CloudStorage/Dropbox-Work",
        ],
        "~/Library/Mail": ["/Users/me/Library/Mail"],
    ])

    private func runner(simctl: CommandOutput? = nil) -> FakeRunner {
        var outputs = diskutilOutputs
        outputs[FakeRunner.key("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])] =
            simctl ?? out(SystemFixtures.simctlRuntimes)
        outputs[du("/Users/me/Library/Developer/Xcode/DerivedData")] =
            out("1953125\t/Users/me/Library/Developer/Xcode/DerivedData\n")  // 2 GB
        outputs[du("/Users/me/Library/Developer")] = out(
            """
            4882812\t/Users/me/Library/Developer/Xcode
            976562\t/Users/me/Library/Developer/Toolchains
            5859375\t/Users/me/Library/Developer

            """)  // 6 GB, Xcode 5 GB of which DerivedData 2 GB
        outputs[du("/Users/me/Library/CloudStorage/Dropbox")] = out("1\t/Users/me/Library/CloudStorage/Dropbox\n")
        outputs[du("/Users/me/Library/CloudStorage/Dropbox-Work")] =
            out("2\t/Users/me/Library/CloudStorage/Dropbox-Work\n")
        outputs[du("/Users/me/Library/Mail")] = out(
            "100\t/Users/me/Library/Mail\n", "du: /Users/me/Library/Mail/V10: Operation not permitted\n", status: 1)
        return FakeRunner(outputs)
    }

    @Test func scanAppliesTheRulesEndToEnd() async throws {
        let clock = SteppingClock(start: Date(timeIntervalSince1970: 1_800_000_000), step: 7)
        let fake = runner()
        let scanner = DiskScanner(runner: fake, paths: paths, now: clock.next)
        let s = try await scanner.scan(config)

        #expect(s.volume == "Macintosh HD")
        #expect(s.total == 494_384_795_648)
        #expect(s.free == 183_916_957_696)
        #expect(s.used == 494_384_795_648 - 183_916_957_696)
        let runtimes: Int64 = 8_315_434_484 + 8_338_867_041
        let derived: Int64 = 1_953_125 * 1024
        let xcodeOther: Int64 = 5_859_375 * 1024 - derived
        let macOS: Int64 = 48_000_000_000
        let counted = runtimes + derived + xcodeOther + 3 * 1024 + 100 * 1024
        #expect(
            s.categories == [
                CategoryUsage(group: "Dev", label: "iOS runtimes", bytes: runtimes),
                CategoryUsage(group: "Dev", label: "DerivedData", bytes: derived),
                CategoryUsage(group: "Dev", label: "Xcode other", bytes: xcodeOther),
                CategoryUsage(group: "Cloud", label: "Dropbox", bytes: 3 * 1024),
                // ~/Library/Developer listed again: already counted, adds nothing.
                CategoryUsage(
                    group: "Mail", label: "Mail", bytes: 100 * 1024, partial: true, fullDiskAccessDenied: true),
                CategoryUsage(group: "macOS", label: "macOS", bytes: macOS),
                CategoryUsage(group: "Other", label: "Other", bytes: s.used - macOS - counted),
            ])
        #expect(
            s.tops.filter { $0.group == "Dev" }.map(\.path) == [
                "/Users/me/Library/Developer/Xcode",
                "/Users/me/Library/Developer/Xcode/DerivedData",
                "/Users/me/Library/Developer/Toolchains",
            ])
        #expect(s.updated == Date(timeIntervalSince1970: 1_800_000_007))
        #expect(s.duration == 7)
        // Each path is measured once, with one `du -d 1` pass.
        #expect(fake.calls.filter { $0 == du("/Users/me/Library/Developer") }.count == 1)
    }

    @Test func unavailableSimctlCountsZeroAndFlagsPartial() async throws {
        let scanner = DiskScanner(runner: runner(simctl: out("", "xcrun: error", status: 1)), paths: paths)
        let s = try await scanner.scan(config)
        // No Xcode is not a Full Disk Access problem.
        #expect(s.categories[0] == CategoryUsage(group: "Dev", label: "iOS runtimes", bytes: 0, partial: true))
        #expect(!s.categories[0].fullDiskAccessDenied)
    }

    @Test func aRootOwnedFolderIsNamedWithoutAskingForFullDiskAccess() async throws {
        // End to end, from du's stderr to the footer: the only refusal is POSIX (EACCES), as with FDA granted.
        let locked = "/Users/me/Library/Application Support/Vendor/updater/1234.run"
        var outputs = diskutilOutputs
        outputs[du("/Users/me/Library/Application Support")] = out(
            "50\t/Users/me/Library/Application Support\n", "du: \(locked): Permission denied\n", status: 1)
        let scanner = DiskScanner(
            runner: FakeRunner(outputs),
            paths: FakePaths(matches: ["~/Library/Application Support": ["/Users/me/Library/Application Support"]]))
        let s = try await scanner.scan(
            DiskConfig(categories: [
                DiskCategory(
                    group: "App data", label: "Other apps", source: .paths(["~/Library/Application Support"]))
            ]))
        let note = DiskSummary.partialNote(of: s.categories)
        #expect(note == .unreadable([locked]))
        #expect(
            note?.footer(home: "/Users/me")
                == "not readable by your user: ~/Library/Application Support/Vendor/…/1234.run")
    }

    @Test func diskutilFailureFailsTheScan() async {
        var outputs = diskutilOutputs
        outputs[FakeRunner.key("/usr/sbin/diskutil", ["info", "-plist", "/"])] = out("", "boom", status: 1)
        let scanner = DiskScanner(runner: FakeRunner(outputs), paths: FakePaths(matches: [:]))
        await #expect(throws: ProbeError.self) {
            try await scanner.scan(DiskConfig(categories: []))
        }
    }

    @Test func aCancelledScanStopsBeforeMeasuring() async {
        let fake = runner()
        let scanner = DiskScanner(runner: fake, paths: paths)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner.scan(config)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!fake.calls.contains { $0.hasPrefix("/usr/bin/du") })
    }
}

/// A clock that advances by a fixed step at each reading: the scan's duration is deterministic.
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        current = start
        self.step = step
    }

    var next: @Sendable () -> Date {
        { [self] in
            lock.withLock {
                defer { current = current.addingTimeInterval(step) }
                return current
            }
        }
    }
}

@Suite struct GlobPathResolverTests {
    @Test func expandsTildeAndGlobsAndSkipsMissingPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("soho-glob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Dropbox", "Dropbox (Team)", "OneDrive"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Cloud/\(name)"), withIntermediateDirectories: true)
        }
        let home = root.path
        let resolver = GlobPathResolver(home: home)
        #expect(resolver.resolve("~/Cloud/Dropbox*") == ["\(home)/Cloud/Dropbox", "\(home)/Cloud/Dropbox (Team)"])
        #expect(resolver.resolve("~/Cloud/OneDrive") == ["\(home)/Cloud/OneDrive"])
        #expect(resolver.resolve("~/Cloud/Missing").isEmpty)
        #expect(resolver.resolve("~/Nope*").isEmpty)
    }
}

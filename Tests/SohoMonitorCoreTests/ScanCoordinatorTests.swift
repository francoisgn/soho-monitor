import Foundation
import Testing

@testable import SohoMonitorCore

/// A scanner that blocks until the test opens its gate: lets a test hold a scan "in flight".
private actor GatedScanner: DiskScanning {
    private var gate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private(set) var runs = 0

    nonisolated func scan(_ config: DiskConfig) async throws -> DiskSnapshot {
        await begin()
        return DiskSnapshot(
            updated: Date(timeIntervalSince1970: 1), duration: 0, volume: "HD", total: 1, used: 0, free: 1,
            categories: [], tops: [])
    }

    private func begin() async {
        runs += 1
        // Only the first scan is held: a second one (a broken lock) returns at once, so the test fails, never hangs.
        guard runs == 1 else { return }
        hasStarted = true
        started?.resume()
        started = nil
        await withCheckedContinuation { gate = $0 }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }

    func open() {
        gate?.resume()
        gate = nil
    }
}

private struct FailingScanner: DiskScanning {
    func scan(_ config: DiskConfig) async throws -> DiskSnapshot {
        throw ProbeError.commandFailed("diskutil exited with 1")
    }
}

@Suite(.timeLimit(.minutes(1))) struct ScanCoordinatorTests {
    @Test func neverRunsTwoScansAtOnce() async {
        let scanner = GatedScanner()
        let coordinator = ScanCoordinator(scanner: scanner)
        let first = Task { await coordinator.scanIfIdle(DiskConfig(categories: [])) }
        await scanner.waitUntilStarted()
        #expect(await coordinator.isScanning)

        let second = await coordinator.scanIfIdle(DiskConfig(categories: []))
        #expect(second == .alreadyRunning)

        await scanner.open()
        guard case .completed = await first.value else {
            Issue.record("the first scan should complete")
            return
        }
        #expect(await scanner.runs == 1)
        #expect(await !coordinator.isScanning)
    }

    @Test func aLockFileKeepsAnotherCoordinatorOut() async throws {
        // Two coordinators stand for the app and `SohoMonitor --scan`: separate processes in real life, separate
        // open file descriptions here, which flock(2) treats the same way.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soho-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("scan.lock")
        let scanner = GatedScanner()
        let app = ScanCoordinator(scanner: scanner, lockURL: lock)
        let headless = ScanCoordinator(scanner: FailingScanner(), lockURL: lock)
        let first = Task { await app.scanIfIdle(DiskConfig(categories: [])) }
        await scanner.waitUntilStarted()

        #expect(await headless.scanIfIdle(DiskConfig(categories: [])) == .alreadyRunning)

        await scanner.open()
        _ = await first.value
        // Released when the scan ends: the other one may run now.
        let other = GatedScanner()
        let later = ScanCoordinator(scanner: other, lockURL: lock)
        let next = Task { await later.scanIfIdle(DiskConfig(categories: [])) }
        await other.waitUntilStarted()
        await other.open()
        guard case .completed = await next.value else {
            Issue.record("the lock should be free after the first scan")
            return
        }
    }

    @Test func aFailureIsReportedAndReleasesTheLock() async {
        let coordinator = ScanCoordinator(scanner: FailingScanner())
        let outcome = await coordinator.scanIfIdle(DiskConfig(categories: []))
        #expect(outcome == .failed("diskutil exited with 1"))
        #expect(await !coordinator.isScanning)
    }
}

@Suite struct SnapshotStoreTests {
    @Test func savesAtomicallyAndLoadsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soho-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        #expect(store.load() == nil)
        let s = DiskSnapshot(
            updated: Date(timeIntervalSince1970: 1_800_000_000), duration: 3, volume: "HD", total: 10, used: 4,
            free: 6, categories: [CategoryUsage(group: "A", label: "A", bytes: 4)],
            tops: [TopFolder(group: "A", path: "/a", bytes: 4)])
        try store.save(s)
        #expect(store.load() == s)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["disk-snapshot.json"])
    }

    @Test func aCorruptCacheIsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soho-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("disk-snapshot.json"))
        #expect(SnapshotStore(directory: dir).load() == nil)
    }
}

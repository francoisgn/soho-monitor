import Darwin
import Foundation

/// Expands a configured path pattern (`~`, globs) to the existing paths it names.
public protocol PathResolving: Sendable {
    func resolve(_ pattern: String) -> [String]
}

/// `~` expansion then `glob(3)`: only existing paths come back, sorted, without a trailing slash.
public struct GlobPathResolver: PathResolving {
    public let home: String

    public init(home: String) {
        self.home = home
    }

    public func resolve(_ pattern: String) -> [String] {
        let expanded = PathDisplay.expandingTilde(pattern, home: home)
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(expanded, 0, nil, &result) == 0 else { return [] }
        var paths: [String] = []
        for index in 0..<Int(result.gl_pathc) {
            guard let cString = result.gl_pathv[index] else { continue }
            let path = PathDisplay.expandingTilde(String(cString: cString), home: home)
            // glob returns a pattern without wildcards as is: check that it exists (without following a final
            // symbolic link, as du does not either).
            var info = stat()
            if lstat(path, &info) == 0 { paths.append(path) }
        }
        return paths.sorted()
    }
}

/// Performs one full scan. A protocol so the scheduling logic is tested without running `du`.
public protocol DiskScanning: Sendable {
    func scan(_ config: DiskConfig) async throws -> DiskSnapshot
}

/// Measures every configured category with `du -k -d 1` (one pass per path gives its total and its direct
/// sub-folders), the iOS runtimes with `simctl`, and the container with `diskutil`.
public struct DiskScanner: DiskScanning {
    static let du = "/usr/bin/du"
    static let xcrun = "/usr/bin/xcrun"
    static let diskutil = "/usr/sbin/diskutil"

    let runner: any CommandRunning
    let paths: any PathResolving
    let now: @Sendable () -> Date

    public init(runner: any CommandRunning, paths: any PathResolving, now: @escaping @Sendable () -> Date = Date.init) {
        self.runner = runner
        self.paths = paths
        self.now = now
    }

    public func scan(_ config: DiskConfig) async throws -> DiskSnapshot {
        let start = now()
        var tally = DiskTally()
        for category in config.categories {
            try Task.checkCancellation()
            tally.startCategory(group: category.group, label: category.label)
            switch category.source {
            case .iosRuntimes:
                let bytes = await runtimeBytes()
                tally.addBytes(bytes ?? 0, partial: bytes == nil)
            case .paths(let patterns):
                for pattern in patterns {
                    for path in paths.resolve(pattern) where !tally.isCounted(path) {
                        try Task.checkCancellation()
                        tally.add(try await measure(path))
                    }
                }
            }
        }
        try Task.checkCancellation()
        let volume = try await volumeInfo()
        let macOS = try await macOSBytes(container: volume.containerReference)
        let (categories, tops) = tally.finish()
        let end = now()
        return DiskSnapshot.assemble(
            categories: categories, tops: tops, volume: volume, macOSBytes: macOS, updated: end,
            duration: max(0, end.timeIntervalSince(start)))
    }

    /// `du` exits with 1 when part of the tree is unreadable: its output is still used (the partial flag says so).
    private func measure(_ path: String) async throws -> DuMeasurement {
        let output = try await runner.run(Self.du, ["-k", "-d", "1", path])
        return DuOutput.parse(
            path: path, stdout: String(decoding: output.stdout, as: UTF8.self),
            stderr: String(decoding: output.stderr, as: UTF8.self))
    }

    /// Nil when simctl is unavailable (no Xcode): the category then shows 0 and is flagged partial.
    private func runtimeBytes() async -> Int64? {
        guard let output = try? await runner.run(Self.xcrun, ["simctl", "runtime", "list", "-j"]),
            output.status == 0
        else { return nil }
        return try? SystemProbeParser.runtimeBytes(fromSimctlJSON: output.stdout)
    }

    private func volumeInfo() async throws -> VolumeInfo {
        let output = try await runner.run(Self.diskutil, ["info", "-plist", "/"])
        guard output.status == 0 else { throw ProbeError.commandFailed("diskutil info exited with \(output.status)") }
        return try SystemProbeParser.volume(fromInfoPlist: output.stdout)
    }

    private func macOSBytes(container: String) async throws -> Int64 {
        let output = try await runner.run(Self.diskutil, ["apfs", "list", "-plist", container])
        guard output.status == 0 else {
            throw ProbeError.commandFailed("diskutil apfs list exited with \(output.status)")
        }
        return try SystemProbeParser.macOSBytes(fromApfsListPlist: output.stdout)
    }
}

/// Outcome of a scan request.
public enum ScanOutcome: Sendable, Equatable {
    case completed(DiskSnapshot)
    case failed(String)
    /// Another scan was in flight: never two at once (a full pass takes many minutes).
    case alreadyRunning
}

/// Serialises scans: a request while one runs is refused, not queued. With a lock file, the refusal also covers
/// another process (the app and `SohoMonitor --scan`).
public actor ScanCoordinator {
    private let scanner: any DiskScanning
    private let lockURL: URL?
    public private(set) var isScanning = false

    public init(scanner: any DiskScanning, lockURL: URL? = nil) {
        self.scanner = scanner
        self.lockURL = lockURL
    }

    public func scanIfIdle(_ config: DiskConfig) async -> ScanOutcome {
        guard !isScanning else { return .alreadyRunning }
        let lock: ScanLock?
        if let lockURL {
            switch ScanLock.acquire(lockURL) {
            case .acquired(let held): lock = held
            case .busy: return .alreadyRunning
            case .failed(let message): return .failed(message)
            }
        } else {
            lock = nil
        }
        // Set before the first suspension point: a re-entrant call sees it.
        isScanning = true
        defer {
            isScanning = false
            lock?.release()
        }
        do {
            return .completed(try await scanner.scan(config))
        } catch is CancellationError {
            return .failed("scan cancelled")
        } catch {
            return .failed(String(describing: error))
        }
    }
}

/// An exclusive, non-blocking `flock(2)` on a lock file. Released by `release()`, or by the kernel if the process
/// dies, so a crash never leaves a stale lock (unlike a lock directory).
final class ScanLock: Sendable {
    enum Attempt {
        case acquired(ScanLock)
        case busy
        case failed(String)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(_ url: URL) -> Attempt {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed("cannot create \(url.deletingLastPathComponent().path): \(error)")
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failed("cannot open \(url.path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            let message = String(cString: strerror(errno))
            close(fd)
            return busy ? .busy : .failed("cannot lock \(url.path): \(message)")
        }
        return .acquired(ScanLock(descriptor: fd))
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// The last snapshot, cached under `~/Library/Caches/soho-monitor/` so the card shows figures at launch.
public struct SnapshotStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("disk-snapshot.json")
    }

    /// Lock file shared by every process that scans, next to the cache.
    public static var defaultLockURL: URL {
        defaultDirectory.appendingPathComponent("scan.lock")
    }

    public static var defaultDirectory: URL {
        URL.cachesDirectory.appendingPathComponent("soho-monitor", isDirectory: true)
    }

    /// Nil when there is no cache yet or it cannot be read (it is rebuilt by the next scan).
    public func load() -> DiskSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? DiskSnapshot.decoder.decode(DiskSnapshot.self, from: data)
    }

    /// Atomic write: a reader never sees a half-written file.
    public func save(_ snapshot: DiskSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DiskSnapshot.encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}

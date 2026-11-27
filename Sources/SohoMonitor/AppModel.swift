import AppKit
import Observation
import SohoMonitorCore

/// UI state of the app: configuration, last snapshot, scan state. Everything heavy runs off the main actor.
@MainActor @Observable
final class AppModel {
    let configURL: URL
    private(set) var configState = ConfigState()
    private(set) var snapshot: DiskSnapshot?
    private(set) var isScanning = false
    private(set) var lastScanError: String?
    var panelVisible: Bool {
        didSet {
            UserDefaults.standard.set(panelVisible, forKey: Self.panelVisibleKey)
            claude.setVisible(panelVisible)
        }
    }
    /// The Claude card's state; refreshed only while the panel is visible.
    let claude = ClaudeUsageModel()

    @ObservationIgnored private let store: SnapshotStore
    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var configFingerprint: FileFingerprint?
    /// End of the last scan attempt, failed ones included: a failure waits one interval before the next try.
    @ObservationIgnored private var lastAttempt: Date?
    /// Categories changed while a scan was running: scan again when it ends.
    @ObservationIgnored private var rescanPending = false

    static let panelVisibleKey = "panel.visible"

    init(
        configURL: URL = ConfigFile.defaultURL(
            environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory()),
        store: SnapshotStore = SnapshotStore(directory: SnapshotStore.defaultDirectory)
    ) {
        self.configURL = configURL
        self.store = store
        coordinator = ScanCoordinator(
            scanner: DiskScanner(runner: ProcessRunner(), paths: GlobPathResolver(home: NSHomeDirectory())),
            lockURL: SnapshotStore.defaultLockURL)
        panelVisible = UserDefaults.standard.object(forKey: Self.panelVisibleKey) as? Bool ?? true
    }

    var disk: DiskConfig { configState.config.disk }

    /// Loads the configuration and the cached snapshot, then schedules scans and watches the file.
    func start() {
        snapshot = store.load()
        reloadConfig()
        claude.setVisible(panelVisible)
        schedule()
        watchConfig()
    }

    func rescanNow() {
        Task { await scan() }
    }

    // MARK: Configuration

    private func reloadConfig() {
        configFingerprint = FileFingerprint(url: configURL)
        let previous = configState.hasValidConfig ? configState.config : nil
        configState.apply(ConfigFile.load(configURL))
        claude.apply(configState.config.claude)
        guard configState.hasValidConfig, ConfigChange.reschedulesDisk(from: previous, to: configState.config) else {
            return
        }
        guard let previous, previous.disk.categories != configState.config.disk.categories else {
            schedule()  // first valid configuration, or only the interval or thresholds changed
            return
        }
        if isScanning { rescanPending = true } else { rescanNow() }
    }

    /// Polls the file's identity every 2 s: it follows a symbolic link (a config kept in a dotfiles repository) and
    /// survives editors that save by replacing the file, which a vnode watcher on the old inode would miss.
    private func watchConfig() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if FileFingerprint(url: self.configURL) != self.configFingerprint { self.reloadConfig() }
            }
        }
    }

    // MARK: Scans

    private func schedule() {
        scheduleTask?.cancel()
        let next = ScanSchedule.nextScan(
            lastUpdated: snapshot?.updated, lastAttempt: lastAttempt, intervalMinutes: disk.scanIntervalMinutes,
            now: .now)
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            await self.scanIfDue()
        }
    }

    /// Automatic scans only: adopt a newer cache first (written by `SohoMonitor --scan`), then scan only if it is
    /// still due.
    private func scanIfDue() async {
        if let cached = store.load(), cached.updated > (snapshot?.updated ?? .distantPast) { snapshot = cached }
        let next = ScanSchedule.nextScan(
            lastUpdated: snapshot?.updated, lastAttempt: lastAttempt, intervalMinutes: disk.scanIntervalMinutes,
            now: .now)
        if next.timeIntervalSinceNow > 1 {
            schedule()
        } else {
            await scan()
        }
    }

    private func scan() async {
        guard configState.hasValidConfig, !isScanning else { return }
        isScanning = true
        let outcome = await coordinator.scanIfIdle(disk)
        isScanning = false
        lastAttempt = .now
        switch outcome {
        case .completed(let result):
            snapshot = result
            lastScanError = nil
            let store = store
            let saved = await Task.detached(priority: .background) { () -> String? in
                do {
                    try store.save(result)
                    return nil
                } catch {
                    return "cannot write the cache \(store.url.path): \(error.localizedDescription)"
                }
            }.value
            if let saved { lastScanError = saved }
        case .failed(let message):
            lastScanError = message
        case .alreadyRunning:
            // Another process (`SohoMonitor --scan`) holds the lock. Its result is adopted from the shared cache by
            // the next automatic scan (`scanIfDue`), one interval from now.
            lastScanError = "another scan is running (SohoMonitor --scan); its result will be picked up"
        }
        if rescanPending {
            rescanPending = false
            rescanNow()
        } else {
            schedule()
        }
    }

    // MARK: Presentation

    var menuSummary: String {
        snapshot.map(DiskSummary.menuLine(of:)) ?? (isScanning ? "First scan in progress…" : "No disk data yet")
    }

    var freeLevel: FreeSpaceLevel {
        guard let snapshot else { return .normal }
        return FreeSpaceLevel(
            free: snapshot.free, total: snapshot.total, warningPercent: disk.freeWarningPercent,
            criticalPercent: disk.freeCriticalPercent)
    }
}

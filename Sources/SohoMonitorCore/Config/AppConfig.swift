import Foundation

/// The whole configuration file (`~/.config/soho-monitor/config.yaml`). Modules add their section here.
public struct AppConfig: Sendable, Equatable {
    public var disk: DiskConfig
    /// `claude:` section; without it the Claude card is off.
    public var claude: ClaudeConfig
    /// `synology:` section; nil when absent (the NAS card is off).
    public var synology: SynologyConfig?

    public init(disk: DiskConfig, claude: ClaudeConfig = .disabled, synology: SynologyConfig? = nil) {
        self.disk = disk
        self.claude = claude
        self.synology = synology
    }

    /// Used until a valid file has been read: no category, defaults everywhere.
    public static let empty = AppConfig(disk: DiskConfig(categories: []))
}

/// `disk:` section: categories measured by the scanner, scan interval and free-space thresholds.
public struct DiskConfig: Sendable, Equatable {
    public static let defaultScanIntervalMinutes = 30
    public static let defaultFreeWarningPercent = 20.0
    public static let defaultFreeCriticalPercent = 10.0

    public var scanIntervalMinutes: Int
    /// Free space below this share of the disk turns the pill orange.
    public var freeWarningPercent: Double
    /// Free space below this share of the disk turns the pill red.
    public var freeCriticalPercent: Double
    /// In order: a path counted by an earlier category is subtracted from the paths that contain it.
    public var categories: [DiskCategory]

    public init(
        scanIntervalMinutes: Int = defaultScanIntervalMinutes,
        freeWarningPercent: Double = defaultFreeWarningPercent,
        freeCriticalPercent: Double = defaultFreeCriticalPercent,
        categories: [DiskCategory]
    ) {
        self.scanIntervalMinutes = scanIntervalMinutes
        self.freeWarningPercent = freeWarningPercent
        self.freeCriticalPercent = freeCriticalPercent
        self.categories = categories
    }
}

/// One line of the detail: a label inside a group (the group is one colour in the bar).
public struct DiskCategory: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Paths as written in the file (`~` and globs `*`, `?`, `[...]` allowed), measured with `du`.
        case paths([String])
        /// iOS simulator runtimes, stored outside the home folder; size reported by `xcrun simctl runtime list -j`.
        case iosRuntimes
    }

    public var group: String
    public var label: String
    public var source: Source

    public init(group: String, label: String, source: Source) {
        self.group = group
        self.label = label
        self.source = source
    }
}

/// One validation problem or warning, located in the file when the parser knows the line.
public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
    public var line: Int?
    /// Dotted path of the key, e.g. `disk.categories[2].paths`.
    public var keyPath: String
    public var message: String

    public init(line: Int?, keyPath: String, message: String) {
        self.line = line
        self.keyPath = keyPath
        self.message = message
    }

    public var description: String {
        let location = line.map { "line \($0): " } ?? ""
        return "\(location)\(keyPath): \(message)"
    }
}

/// The file could not be used: every problem found, in file order.
public struct ConfigError: Error, Sendable, Equatable {
    public var issues: [ConfigIssue]

    public init(issues: [ConfigIssue]) {
        self.issues = issues
    }
}

/// A valid configuration, with the warnings (unknown keys) found while reading it.
public struct ConfigLoadResult: Sendable, Equatable {
    public var config: AppConfig
    public var warnings: [ConfigIssue]

    public init(config: AppConfig, warnings: [ConfigIssue]) {
        self.config = config
        self.warnings = warnings
    }
}

/// What the app runs with: the last valid configuration, and the problems of the last reload, if any.
public struct ConfigState: Sendable, Equatable {
    public private(set) var config: AppConfig = .empty
    public private(set) var hasValidConfig = false
    /// Errors of the last reload (empty when it succeeded); the previous valid configuration stays in use.
    public private(set) var errors: [ConfigIssue] = []
    public private(set) var warnings: [ConfigIssue] = []

    public init() {}

    public mutating func apply(_ result: Result<ConfigLoadResult, ConfigError>) {
        switch result {
        case .success(let loaded):
            config = loaded.config
            hasValidConfig = true
            errors = []
            warnings = loaded.warnings
        case .failure(let error):
            errors = error.issues
        }
    }
}

/// Identity of the configuration file as `stat(2)` sees it through symbolic links: device, inode, size and
/// modification time. Compared every few seconds to reload the file: it catches in-place edits, atomic saves (new
/// inode) and a link retargeted in a dotfiles repository, which a watcher on the original inode would miss.
public struct FileFingerprint: Sendable, Equatable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    /// Nil when the file does not exist (or cannot be reached).
    public init?(url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}

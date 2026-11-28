import Foundation

/// Byte counts in decimal units (1 GB = 10⁹ bytes), like Finder and System Settings › Storage.
public enum ByteFormat {
    public static func short(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        // Thresholds on the rounded value: 999.96 GB reads "1.00 TB", never "1000.0 GB".
        if b >= 999.95e9 { return String(format: "%.2f TB", b / 1e12) }
        if b >= 999.5e6 { return String(format: "%.1f GB", b / 1e9) }
        return String(format: "%.0f MB", (b / 1e6).rounded())
    }
}

/// "Updated N min ago" style ages.
public enum RelativeAge {
    public static func string(from date: Date, now: Date) -> String {
        let minutes = Int((now.timeIntervalSince(date) / 60).rounded())
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 48 { return "\(hours) h ago" }
        return "\(Int((Double(hours) / 24).rounded())) d ago"
    }
}

/// Paths as written in the configuration and as shown in the UI.
public enum PathDisplay {
    /// `/Users/me/Git` → `~/Git`.
    public static func abbreviated(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// A long path cut in the middle for one line: `~`-relative, the first three components and the leaf kept
    /// (`~/Library/Application Support/Vendor/…/x.run`); a path of five components or fewer is left whole.
    public static func short(_ path: String, home: String) -> String {
        let display = abbreviated(path, home: home)
        let root = display.hasPrefix("~/") ? "~/" : display.hasPrefix("/") ? "/" : ""
        let parts = display.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 4, let leaf = parts.last else { return display }
        return root + parts.prefix(3).joined(separator: "/") + "/…/" + leaf
    }

    /// `~` and `~/x` → absolute; a trailing slash is dropped (`du` echoes the path as given). `~user` is left as is.
    public static func expandingTilde(_ path: String, home: String) -> String {
        var result = path
        if result == "~" {
            result = home
        } else if result.hasPrefix("~/") {
            result = home + result.dropFirst(1)
        }
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// Colour of a group in the bar: a palette entry by rank, or the fixed greys of the computed groups.
public enum ColorSlot: Sendable, Equatable {
    case palette(Int)
    case macOS
    case other
}

/// A group of categories as the card shows it: one bar segment and one legend chip.
public struct DiskGroup: Sendable, Equatable, Identifiable {
    public var name: String
    public var bytes: Int64
    public var partial: Bool
    /// Why the group is partial, nil when it is complete.
    public var note: PartialNote? = nil
    /// Non-empty categories of the group, biggest first.
    public var items: [CategoryUsage]
    public var colorSlot: ColorSlot

    public var id: String { name }

    /// Hover text: the group total, then each category when there are several.
    public var detail: String {
        var lines = ["\(name): \(ByteFormat.short(bytes))"]
        if items.count > 1 {
            lines += items.map { "  \($0.label): \(ByteFormat.short($0.bytes))" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Why a scan is partial, and what the card says about it.
public enum PartialNote: Sendable, Equatable {
    /// macOS privacy refused some folders: Full Disk Access fixes it. POSIX-unreadable folders, if any, come along.
    case fullDiskAccess(unreadable: [String])
    /// Only POSIX permissions refused: these folders are not readable by the user, whatever the privacy settings.
    case unreadable([String])
    /// Partial for another reason (no `simctl`): no permission fixes it.
    case incomplete

    static let posixHeading =
        "Folders not readable by your user (POSIX permissions; Full Disk Access does not change them):"

    /// The footer text (one line): the Full Disk Access request only when that is what is missing.
    public func footer(home: String) -> String {
        switch self {
        case .fullDiskAccess: "partial: grant Full Disk Access to SohoMonitor"
        case .incomplete: "partial: some sizes could not be measured"
        case .unreadable(let folders):
            "not readable by your user: \(folders.first.map { PathDisplay.short($0, home: home) } ?? "")"
                + (folders.count > 1 ? " +\(folders.count - 1) more" : "")
        }
    }

    /// The hover detail: every unreadable folder, `~`-relative and in full.
    public func detail(home: String) -> String {
        func listing(_ folders: [String]) -> [String] {
            folders.isEmpty ? [] : [Self.posixHeading] + folders.map { PathDisplay.abbreviated($0, home: home) }
        }
        let lines: [String] =
            switch self {
            case .fullDiskAccess(let folders): ["Some folders need Full Disk Access to be measured."] + listing(folders)
            case .unreadable(let folders): listing(folders)
            case .incomplete: ["Some sizes could not be measured (iOS runtimes need Xcode's simctl)."]
            }
        return lines.joined(separator: "\n")
    }

    /// Shown in the warning colour: something the user can act on, or a size that is unknown. POSIX-unreadable
    /// folders alone are not: the figure is a lower bound by a few locked folders, and nothing in the app can fix it.
    public var isWarning: Bool {
        if case .unreadable = self { return false }
        return true
    }
}

/// Free-space colour of the pill.
public enum FreeSpaceLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    public init(free: Int64, total: Int64, warningPercent: Double, criticalPercent: Double) {
        guard total > 0 else {
            self = .normal
            return
        }
        let percent = Double(free) / Double(total) * 100
        if percent < criticalPercent {
            self = .critical
        } else if percent < warningPercent {
            self = .warning
        } else {
            self = .normal
        }
    }
}

/// Presentation rules of the card, kept out of SwiftUI so they are tested.
public enum DiskSummary {
    /// Non-empty groups by size, `macOS` then `Other` last (as in System Settings › Storage).
    public static func groups(of snapshot: DiskSnapshot) -> [DiskGroup] {
        var order: [String] = []
        var byName: [String: DiskGroup] = [:]
        let categoriesByGroup = Dictionary(grouping: snapshot.categories, by: \.group)
        for category in snapshot.categories {
            if byName[category.group] == nil {
                order.append(category.group)
                byName[category.group] = DiskGroup(
                    name: category.group, bytes: 0, partial: false, items: [], colorSlot: .palette(0))
            }
            byName[category.group]?.bytes += category.bytes
            if category.partial { byName[category.group]?.partial = true }
            if category.bytes > 0 { byName[category.group]?.items.append(category) }
        }
        func rank(_ name: String) -> Int {
            name == DiskSnapshot.otherGroup ? 2 : name == DiskSnapshot.macOSGroup ? 1 : 0
        }
        let sorted = order.compactMap { byName[$0] }
            .filter { $0.bytes > 0 }
            .sorted {
                rank($0.name) != rank($1.name)
                    ? rank($0.name) < rank($1.name)
                    : $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name
            }
        return sorted.enumerated().map { index, group in
            var g = group
            g.items.sort { $0.bytes > $1.bytes }
            g.note = partialNote(of: categoriesByGroup[g.name] ?? [])
            switch g.name {
            case DiskSnapshot.macOSGroup: g.colorSlot = .macOS
            case DiskSnapshot.otherGroup: g.colorSlot = .other
            default: g.colorSlot = .palette(index)
            }
            return g
        }
    }

    /// Why the scan of these categories is partial, nil when it is complete. A Full Disk Access refusal wins (it is
    /// the one the user can fix), with the POSIX-unreadable folders still carried for the detail.
    public static func partialNote(of categories: [CategoryUsage]) -> PartialNote? {
        guard categories.contains(where: \.partial) else { return nil }
        var unreadable: [String] = []
        for folder in categories.flatMap(\.unreadable) where !unreadable.contains(folder) { unreadable.append(folder) }
        if categories.contains(where: \.fullDiskAccessDenied) { return .fullDiskAccess(unreadable: unreadable) }
        return unreadable.isEmpty ? .incomplete : .unreadable(unreadable)
    }

    /// Width of the full bar in bytes: the disk size, or more when `du` counted clones in full.
    public static func barScale(of snapshot: DiskSnapshot, groups: [DiskGroup]) -> Int64 {
        max(snapshot.total, groups.reduce(0) { $0 + $1.bytes } + snapshot.free)
    }

    /// The card's large figure, as on the CPU and memory cards; nil without a disk size (the card shows a dash).
    public static func usedFraction(of snapshot: DiskSnapshot) -> Double? {
        snapshot.total > 0 ? Double(snapshot.used) / Double(snapshot.total) : nil
    }

    /// Menu bar summary line.
    public static func menuLine(of snapshot: DiskSnapshot) -> String {
        "\(snapshot.volume): \(ByteFormat.short(snapshot.free)) free of \(ByteFormat.short(snapshot.total))"
    }
}

/// When the next automatic scan runs.
public enum ScanSchedule {
    /// Now without any snapshot or attempt, otherwise one interval after the later of the last snapshot and the last
    /// attempt (a failed scan waits one interval instead of starting a long `du` pass again at once), and at most one
    /// interval from now, should the clock have moved backwards.
    public static func nextScan(lastUpdated: Date?, lastAttempt: Date? = nil, intervalMinutes: Int, now: Date) -> Date {
        guard let reference = [lastUpdated, lastAttempt].compactMap(\.self).max() else { return now }
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
        let due = reference.addingTimeInterval(interval)
        return min(max(due, now), now.addingTimeInterval(interval))
    }
}

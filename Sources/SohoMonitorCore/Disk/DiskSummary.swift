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
            switch g.name {
            case DiskSnapshot.macOSGroup: g.colorSlot = .macOS
            case DiskSnapshot.otherGroup: g.colorSlot = .other
            default: g.colorSlot = .palette(index)
            }
            return g
        }
    }

    /// Width of the full bar in bytes: the disk size, or more when `du` counted clones in full.
    public static func barScale(of snapshot: DiskSnapshot, groups: [DiskGroup]) -> Int64 {
        max(snapshot.total, groups.reduce(0) { $0 + $1.bytes } + snapshot.free)
    }

    /// Menu bar summary line.
    public static func menuLine(of snapshot: DiskSnapshot) -> String {
        "\(snapshot.volume): \(ByteFormat.short(snapshot.free)) free of \(ByteFormat.short(snapshot.total))"
    }
}

/// When the next automatic scan runs.
public enum ScanSchedule {
    /// Now without any snapshot, otherwise one interval after the last one (at most one interval from now, should
    /// the clock have moved backwards).
    public static func nextScan(lastUpdated: Date?, intervalMinutes: Int, now: Date) -> Date {
        guard let lastUpdated else { return now }
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
        let due = lastUpdated.addingTimeInterval(interval)
        return min(max(due, now), now.addingTimeInterval(interval))
    }
}

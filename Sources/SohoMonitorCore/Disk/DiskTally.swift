import Foundation

/// One line of `du` output: a path and its size in bytes.
public struct DuEntry: Sendable, Equatable {
    public var path: String
    public var bytes: Int64

    public init(path: String, bytes: Int64) {
        self.path = path
        self.bytes = bytes
    }
}

/// What one `du -k -d 1 <path>` pass tells: the total, the direct sub-folders, and whether some of it was unreadable.
public struct DuMeasurement: Sendable, Equatable {
    public var path: String
    public var bytes: Int64
    public var children: [DuEntry]
    /// Some of the tree could not be read: the total is a lower bound.
    public var partial: Bool
    /// `Operation not permitted`: macOS privacy (TCC) refused, which only Full Disk Access lifts.
    public var fullDiskAccessDenied: Bool
    /// Folders refused with `Permission denied` (POSIX permissions, e.g. root-owned): Full Disk Access does not help.
    public var unreadable: [String]

    public init(
        path: String, bytes: Int64, children: [DuEntry], partial: Bool, fullDiskAccessDenied: Bool = false,
        unreadable: [String] = []
    ) {
        self.path = path
        self.bytes = bytes
        self.children = children
        self.partial = partial
        self.fullDiskAccessDenied = fullDiskAccessDenied
        self.unreadable = unreadable
    }
}

/// Parser of `du -k -d 1` output (BSD and GNU): `<KiB>\t<path>` per line, the measured path itself included.
public enum DuOutput {
    /// EPERM, what `du` prints when macOS privacy (TCC) refuses a folder: missing Full Disk Access.
    static let fullDiskAccessMarker = "Operation not permitted"
    /// EACCES, what `du` prints when POSIX permissions refuse a folder (owned by another user, e.g. root).
    static let permissionDeniedMarker = "Permission denied"

    public static func parse(path: String, stdout: String, stderr: String) -> DuMeasurement {
        var total: Int64 = 0
        var children: [DuEntry] = []
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            // Only the first tab separates the size: a tab inside a file name stays in the path.
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let size = line[..<tab]
            let entryPath = String(line[line.index(after: tab)...])
            guard !entryPath.isEmpty, !size.isEmpty, size.allSatisfy(\.isASCII), let kib = Int64(size) else {
                continue
            }
            let bytes = kib.multipliedReportingOverflow(by: 1024)
            guard !bytes.overflow else { continue }
            if entryPath == path {
                total = bytes.partialValue
            } else {
                children.append(DuEntry(path: entryPath, bytes: bytes.partialValue))
            }
        }
        var fullDiskAccessDenied = false
        var posixDenied = false
        var unreadable: [String] = []
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains(fullDiskAccessMarker) {
                fullDiskAccessDenied = true
            } else if line.contains(permissionDeniedMarker) {
                posixDenied = true
                if let folder = deniedPath(in: line), !unreadable.contains(folder) { unreadable.append(folder) }
            }
        }
        return DuMeasurement(
            path: path, bytes: total, children: children, partial: fullDiskAccessDenied || posixDenied,
            fullDiskAccessDenied: fullDiskAccessDenied, unreadable: unreadable)
    }

    /// The folder of a `Permission denied` line: BSD `du: <path>: Permission denied`, GNU
    /// `du: cannot read directory '<path>': Permission denied`. Nil when the line names no absolute path (the scanner
    /// only passes absolute paths, so every folder `du` reports is one).
    static func deniedPath(in line: Substring) -> String? {
        let suffix = ": " + permissionDeniedMarker
        guard line.hasSuffix(suffix) else { return nil }
        var body = line.dropLast(suffix.count)
        if body.hasPrefix("du: ") { body = body.dropFirst(4) }
        if body.hasPrefix("cannot "), let open = body.firstIndex(of: "'"), let close = body.lastIndex(of: "'"),
            open < close
        {
            body = body[body.index(after: open)..<close]
        }
        return body.hasPrefix("/") ? String(body) : nil
    }
}

/// The counting rules of the disk module, applied path after path in configuration order:
/// - a path already counted (itself or a folder containing it) adds nothing;
/// - a path containing folders counted earlier adds its size minus their **net** values (never subtracted twice),
///   clamped at 0 (APFS clones are counted in full by `du`);
/// - the top-3 candidates of a group are the direct sub-folders of its paths, each net of what was counted at or
///   below it, or the path itself when it has no sub-folder.
public struct DiskTally: Sendable {
    private struct Category {
        var group: String
        var label: String
        var bytes: Int64 = 0
        var partial = false
        var fullDiskAccessDenied = false
        var unreadable: [String] = []
    }

    /// Unreadable folders kept per category: enough to name them, bounded so that a tree full of locked folders does
    /// not bloat the cache; the rest are dropped (the category stays partial).
    public static let unreadableLimit = 50

    private var categories: [Category] = []
    /// Net bytes of each counted path.
    private var counted: [String: Int64] = [:]
    private var candidates: [TopFolder] = []
    private var groupOrder: [String] = []

    public init() {}

    public mutating func startCategory(group: String, label: String) {
        categories.append(Category(group: group, label: label))
        if !groupOrder.contains(group) { groupOrder.append(group) }
    }

    /// True when `path`, or a folder containing it, has already been counted: measuring it again is useless.
    public func isCounted(_ path: String) -> Bool {
        counted.keys.contains { $0 == path || path.hasPrefix(Self.folderPrefix($0)) }
    }

    /// Adds one measured path to the current category.
    public mutating func add(_ m: DuMeasurement) {
        guard !categories.isEmpty, !isCounted(m.path) else { return }
        let group = categories[categories.count - 1].group
        let net = max(0, m.bytes - countedBelow(m.path))
        if m.children.isEmpty {
            if net > 0 { candidates.append(TopFolder(group: group, path: m.path, bytes: net)) }
        } else {
            for child in m.children {
                let childNet = child.bytes - countedAtOrBelow(child.path)
                if childNet > 0 { candidates.append(TopFolder(group: group, path: child.path, bytes: childNet)) }
            }
        }
        counted[m.path] = net
        categories[categories.count - 1].bytes += net
        if m.partial { categories[categories.count - 1].partial = true }
        if m.fullDiskAccessDenied { categories[categories.count - 1].fullDiskAccessDenied = true }
        for folder in m.unreadable {
            let current = categories[categories.count - 1].unreadable
            guard current.count < Self.unreadableLimit else { break }
            if !current.contains(folder) { categories[categories.count - 1].unreadable.append(folder) }
        }
    }

    /// Adds bytes that do not come from `du` (iOS runtimes) to the current category.
    public mutating func addBytes(_ bytes: Int64, partial: Bool) {
        guard !categories.isEmpty else { return }
        categories[categories.count - 1].bytes += max(0, bytes)
        if partial { categories[categories.count - 1].partial = true }
    }

    /// Categories in configuration order, and the three biggest candidates of each group (by group order, then
    /// size, then path for a stable result).
    public func finish() -> (categories: [CategoryUsage], tops: [TopFolder]) {
        let usages = categories.map {
            CategoryUsage(
                group: $0.group, label: $0.label, bytes: $0.bytes, partial: $0.partial,
                fullDiskAccessDenied: $0.fullDiskAccessDenied, unreadable: $0.unreadable)
        }
        let byGroup = Dictionary(grouping: candidates, by: \.group)
        let tops = groupOrder.flatMap { group in
            (byGroup[group] ?? [])
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
                .prefix(3)
        }
        return (usages, tops)
    }

    private static func folderPrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private func countedBelow(_ path: String) -> Int64 {
        let prefix = Self.folderPrefix(path)
        return counted.reduce(0) { $0 + ($1.key.hasPrefix(prefix) ? $1.value : 0) }
    }

    private func countedAtOrBelow(_ path: String) -> Int64 {
        (counted[path] ?? 0) + countedBelow(path)
    }
}

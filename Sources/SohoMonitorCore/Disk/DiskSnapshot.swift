import Foundation

/// Bytes counted for one configured category (net of earlier categories), or for the computed `macOS` / `Other`.
public struct CategoryUsage: Codable, Sendable, Equatable {
    public var group: String
    public var label: String
    public var bytes: Int64
    /// True when `du` could not read part of the category (no Full Disk Access): the figure is a lower bound.
    public var partial: Bool

    public init(group: String, label: String, bytes: Int64, partial: Bool = false) {
        self.group = group
        self.label = label
        self.bytes = bytes
        self.partial = partial
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decode(String.self, forKey: .group)
        label = try c.decode(String.self, forKey: .label)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        partial = try c.decodeIfPresent(Bool.self, forKey: .partial) ?? false
    }
}

/// One of the biggest sub-folders of a group, net of what more specific categories counted below it.
public struct TopFolder: Codable, Sendable, Equatable {
    public var group: String
    /// Absolute path (the UI abbreviates the home folder to `~`).
    public var path: String
    public var bytes: Int64

    public init(group: String, path: String, bytes: Int64) {
        self.group = group
        self.path = path
        self.bytes = bytes
    }
}

/// Figures of the startup volume's APFS container, from `diskutil info -plist /`.
public struct VolumeInfo: Sendable, Equatable {
    public var name: String
    public var total: Int64
    public var free: Int64
    public var containerReference: String

    public init(name: String, total: Int64, free: Int64, containerReference: String) {
        self.name = name
        self.total = total
        self.free = free
        self.containerReference = containerReference
    }
}

/// Result of one full disk scan: what the card shows, cached on disk between launches.
public struct DiskSnapshot: Codable, Sendable, Equatable {
    /// Group names computed by the app, reserved in the configuration.
    public static let macOSGroup = "macOS"
    public static let otherGroup = "Other"

    public var updated: Date
    /// Scan duration, in seconds.
    public var duration: TimeInterval
    public var volume: String
    public var total: Int64
    public var used: Int64
    public var free: Int64
    /// Configured categories in configuration order, then `macOS` and `Other`.
    public var categories: [CategoryUsage]
    public var tops: [TopFolder]

    public init(
        updated: Date, duration: TimeInterval, volume: String, total: Int64, used: Int64, free: Int64,
        categories: [CategoryUsage], tops: [TopFolder]
    ) {
        self.updated = updated
        self.duration = duration
        self.volume = volume
        self.total = total
        self.used = used
        self.free = free
        self.categories = categories
        self.tops = tops
    }

    public init(from decoder: any Decoder) throws {
        // Tolerant decoding: a field added later must be optional here, so that older caches keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updated = try c.decode(Date.self, forKey: .updated)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        volume = try c.decodeIfPresent(String.self, forKey: .volume) ?? ""
        total = try c.decode(Int64.self, forKey: .total)
        used = try c.decode(Int64.self, forKey: .used)
        free = try c.decode(Int64.self, forKey: .free)
        categories = try c.decodeIfPresent([CategoryUsage].self, forKey: .categories) ?? []
        tops = try c.decodeIfPresent([TopFolder].self, forKey: .tops) ?? []
    }

    /// Adds `macOS` (non-Data volumes of the container) and `Other` (used − macOS − counted, at least 0).
    public static func assemble(
        categories: [CategoryUsage], tops: [TopFolder], volume: VolumeInfo, macOSBytes: Int64, updated: Date,
        duration: TimeInterval
    ) -> DiskSnapshot {
        let used = max(0, volume.total - volume.free)
        let counted = categories.reduce(Int64(0)) { $0 + $1.bytes }
        let other = max(0, used - macOSBytes - counted)
        return DiskSnapshot(
            updated: updated, duration: duration, volume: volume.name, total: volume.total, used: used,
            free: volume.free,
            categories: categories + [
                CategoryUsage(group: macOSGroup, label: macOSGroup, bytes: macOSBytes),
                CategoryUsage(group: otherGroup, label: otherGroup, bytes: other),
            ],
            tops: tops)
    }

    /// JSON coding used by the cache: dates as Unix seconds, like the widget's `usage.json`.
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

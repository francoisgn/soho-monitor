import Foundation

/// Fixed-capacity history, oldest first: appending past the capacity drops the oldest element. Storage is allocated
/// once, so a sparkline history costs `capacity` elements whatever the uptime.
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    /// Index of the oldest element once the storage is full.
    private var head = 0

    /// A capacity below 1 is raised to 1.
    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Every element, oldest first.
    public var elements: [Element] { Array(storage[head...] + storage[..<head]) }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var last: Element? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }
}

extension RingBuffer: Sendable where Element: Sendable {}
extension RingBuffer: Equatable where Element: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elements == rhs.elements
    }
}

/// Colour state of a figure and its bar: normal (metric accent), warning (orange), critical (red).
public enum MetricLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    /// Higher is worse. A missing or non-finite value is `normal`: the card shows a dash, not an alarm.
    public init(fraction: Double?, warning: Double, critical: Double) {
        guard let fraction, fraction.isFinite else {
            self = .normal
            return
        }
        if fraction >= critical {
            self = .critical
        } else if fraction >= warning {
            self = .warning
        } else {
            self = .normal
        }
    }
}

/// Values shown as a share (0...1) of a bar or a percentage.
public enum MetricFraction {
    /// Clamped into 0...1; nil for NaN or an infinity, which the card shows as a dash rather than a fake figure.
    public static func clamped(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}

/// The large figure of a card.
public enum PercentFormat {
    /// `0.234` → "23%"; nil or NaN → "—" (never a fake 0 %).
    public static func whole(_ fraction: Double?) -> String {
        guard let fraction, let clamped = MetricFraction.clamped(fraction) else { return "—" }
        return "\(Int((clamped * 100).rounded()))%"
    }
}

/// Memory sizes in binary units (1 GB = 2³⁰ bytes), so a 16 GiB Mac reads "16.0 GB" as on its spec sheet; disk sizes
/// stay decimal (`ByteFormat`), as Finder shows them.
public enum MemoryFormat {
    public static func short(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1_048_576
        // Thresholds on the rounded value: 1023.5 MiB reads "1.0 GB", never "1024 MB".
        if mib < 1023.5 { return "\(Int(mib.rounded())) MB" }
        let gib = mib / 1024
        if gib >= 99.95 { return "\(Int(gib.rounded())) GB" }
        return String(format: "%.1f GB", gib)
    }
}

/// Maps a history to 0...1 heights for the sparkline.
public enum SparklineScale {
    public enum Domain: Sendable {
        /// Values already are shares (CPU, memory): clamped into 0...1, non-finite → 0.
        case unit
        /// Stretched from the lowest to the highest value; a flat history sits in the middle.
        case auto
    }

    public static func normalized(_ values: [Double], domain: Domain) -> [Double] {
        switch domain {
        case .unit:
            return values.map { MetricFraction.clamped($0) ?? 0 }
        case .auto:
            let finite = values.filter(\.isFinite)
            guard let low = finite.min(), let high = finite.max(), high > low else {
                return values.map { _ in 0.5 }
            }
            return values.map { $0.isFinite ? ($0 - low) / (high - low) : 0.5 }
        }
    }
}

import Darwin
import Dispatch
import Synchronization

/// Page counts of `vm_statistics64` (`mach/vm_statistics.h`) used by the memory card.
public struct VMPageCounts: Sendable, Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    /// Pages occupied by the compressor (`compressor_page_count`), not the pages it holds.
    public var compressed: UInt64
    public var purgeable: UInt64
    /// File-backed pages (`external_page_count`).
    public var external: UInt64

    public init(
        free: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64, compressed: UInt64,
        purgeable: UInt64, external: UInt64
    ) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
    }
}

/// Swap file usage (`vm.swapusage`, `struct xsw_usage` in `sys/sysctl.h`).
public struct SwapUsage: Sendable, Equatable {
    public var total: UInt64
    public var used: UInt64

    public init(total: UInt64, used: UInt64) {
        self.total = total
        self.used = used
    }
}

/// Memory pressure as the kernel reports it to dispatch sources.
public enum MemoryPressure: Sendable, Equatable {
    case normal
    case warning
    case critical

    /// `DISPATCH_MEMORYPRESSURE_NORMAL` (0x01), `_WARN` (0x02), `_CRITICAL` (0x04) (`dispatch/source.h`); the
    /// `kern.memorystatus_vm_pressure_level` sysctl returns the same values (xnu `bsd/kern/kern_memorystatus_notify.c`,
    /// `sysctl_memorystatus_vm_pressure_level`, which calls `convert_internal_pressure_level_to_dispatch_level`).
    /// Anything else is unknown: nil.
    public init?(dispatchLevel: Int) {
        switch dispatchLevel {
        case 0x01: self = .normal
        case 0x02: self = .warning
        case 0x04: self = .critical
        default: return nil
        }
    }

    /// Text of the pressure pill in the full layout; hover text of the compact one.
    public var label: String {
        switch self {
        case .normal: "Pressure normal"
        case .warning: "Pressure warning"
        case .critical: "Pressure critical"
        }
    }

    /// Text of the pill in the compact memory card, where the long label and the swap pill do not fit on one line;
    /// the long label stays in the pill's hover text.
    public var shortLabel: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// Latest pressure level, fed by dispatch memory-pressure events: a level stays until another event replaces it.
public struct MemoryPressureTracker: Sendable, Equatable {
    public private(set) var level: MemoryPressure?

    public init(initial: MemoryPressure?) {
        level = initial
    }

    /// One event's mask (`DispatchSource.data`): the most severe flag set wins; a mask with no known flag changes
    /// nothing.
    public mutating func apply(eventMask: Int) {
        if eventMask & 0x04 != 0 {
            level = .critical
        } else if eventMask & 0x02 != 0 {
            level = .warning
        } else if eventMask & 0x01 != 0 {
            level = .normal
        }
    }
}

/// One memory sample, in bytes.
public struct MemoryReading: Sendable, Equatable {
    public var total: UInt64
    /// App + wired + compressed (see `init`).
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File cache and purgeable memory: reclaimable, not counted as used.
    public var cached: UInt64
    /// Nil when `vm.swapusage` could not be read: the swap pill is omitted.
    public var swap: SwapUsage?
    /// Nil when unknown: the pressure pill is hidden, never shown as normal.
    public var pressure: MemoryPressure?

    /// `used = active + inactive + speculative + wired + compressed − purgeable − external`, `app = used − wired −
    /// compressed`, `cached = purgeable + external`: the Activity Monitor-like split used by Stats
    /// (github.com/exelban/stats, `Modules/RAM/readers.swift` lines 48-95 at fa77c17). Clamped to 0...total.
    public init(pages: VMPageCounts, pageSize: UInt64, total: UInt64, swap: SwapUsage?, pressure: MemoryPressure?) {
        let resident = pages.active + pages.inactive + pages.speculative + pages.wired + pages.compressed
        let reclaimable = pages.purgeable + pages.external
        let usedPages = resident > reclaimable ? resident - reclaimable : 0
        let used = min(total, usedPages.multipliedReportingOverflow(by: pageSize).partialValue)
        let pinned = (pages.wired + pages.compressed) * pageSize
        self.total = total
        self.used = used
        app = used > pinned ? used - pinned : 0
        wired = pages.wired * pageSize
        compressed = pages.compressed * pageSize
        cached = reclaimable * pageSize
        self.swap = swap
        self.pressure = pressure
    }

    /// Used share of the physical memory, 0...1.
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// Pressure when known (a full cache is not a problem, pressure is); otherwise the used share against 85 % / 95 %.
    public var level: MetricLevel {
        switch pressure {
        case .normal: .normal
        case .warning: .warning
        case .critical: .critical
        case nil: MetricLevel(fraction: usedFraction, warning: 0.85, critical: 0.95)
        }
    }

    /// "6.0 GB of 16.0 GB".
    public var usedOfTotal: String { "\(MemoryFormat.short(used)) of \(MemoryFormat.short(total))" }

    /// Hover text of the figure: where the used memory goes, and the reclaimable cache.
    public var breakdown: String {
        [("App", app), ("Wired", wired), ("Compressed", compressed), ("Cached", cached)]
            .map { "\($0.0) \(MemoryFormat.short($0.1))" }
            .joined(separator: " · ")
    }

    /// "Swap 7.0 GB", or nil when swap is unknown.
    public var swapText: String? { swap.map { "Swap \(MemoryFormat.short($0.used))" } }
}

/// Collector of `MemoryReading`: a gauge, so every sample has a value. The pressure comes from a
/// `MemoryPressureMonitor` (event driven): nothing is polled for it.
public final class MemoryCollector: MetricCollector {
    private let readPages: @Sendable () throws(ProbeError) -> (VMPageCounts, UInt64)
    private let total: UInt64?
    private let swap: @Sendable () -> SwapUsage?
    private let pressure: @Sendable () -> MemoryPressure?

    public init(
        readPages: @escaping @Sendable () throws(ProbeError) -> (VMPageCounts, UInt64) = { () throws(ProbeError) in
            try MachMemory.pages()
        },
        total: UInt64? = SystemSysctl().uint64("hw.memsize"),
        swap: @escaping @Sendable () -> SwapUsage? = { MachMemory.swapUsage() },
        pressure: @escaping @Sendable () -> MemoryPressure?
    ) {
        self.readPages = readPages
        self.total = total
        self.swap = swap
        self.pressure = pressure
    }

    public func sample() async throws -> MemoryReading? {
        guard let total, total > 0 else { throw ProbeError.unreadable("hw.memsize: unknown physical memory size") }
        let (pages, pageSize) = try readPages()
        return MemoryReading(pages: pages, pageSize: pageSize, total: total, swap: swap(), pressure: pressure())
    }

    public func reset() async {}
}

/// Mach and sysctl calls for memory (public API: `mach/host_info.h`, `mach/vm_statistics.h`, `sys/sysctl.h`).
public enum MachMemory {
    private static let host = mach_host_self()

    /// `host_statistics64(HOST_VM_INFO64)` and the kernel page size (`host_page_size`), which the counts are in.
    public static func pages() throws(ProbeError) -> (VMPageCounts, UInt64) {
        var pageSize: vm_size_t = 0
        let sized = host_page_size(host, &pageSize)
        guard sized == KERN_SUCCESS, pageSize > 0 else {
            throw .unreadable("host_page_size: \(String(cString: mach_error_string(sized)))")
        }
        var stats = vm_statistics64_data_t()
        // HOST_VM_INFO64_COUNT, a macro Swift does not import.
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw .unreadable("host_statistics64: \(String(cString: mach_error_string(result)))")
        }
        let pages = VMPageCounts(
            free: UInt64(stats.free_count), active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count), speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count), compressed: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count), external: UInt64(stats.external_page_count))
        return (pages, UInt64(pageSize))
    }

    /// `vm.swapusage`; nil when the key is missing or its size is not `xsw_usage`'s.
    public static func swapUsage() -> SwapUsage? {
        SystemSysctl().value("vm.swapusage", as: xsw_usage.self, initial: xsw_usage())
            .map { SwapUsage(total: $0.xsu_total, used: $0.xsu_used) }
    }

    /// `kern.memorystatus_vm_pressure_level`: the current level, read once to seed the monitor.
    public static func pressureLevel() -> MemoryPressure? {
        SystemSysctl().int("kern.memorystatus_vm_pressure_level").flatMap(MemoryPressure.init(dispatchLevel:))
    }
}

/// Follows the memory pressure with a dispatch source (event driven, no polling), seeded with the sysctl's current
/// level. Kept registered for the whole life of the app: it costs nothing between events.
public final class MemoryPressureMonitor: Sendable {
    private let tracker: Mutex<MemoryPressureTracker>
    private let source: any DispatchSourceMemoryPressure

    public init(initial: MemoryPressure? = MachMemory.pressureLevel()) {
        let tracker = Mutex(MemoryPressureTracker(initial: initial))
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        self.tracker = tracker
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = Int(self.source.data.rawValue)
            self.tracker.withLock { $0.apply(eventMask: mask) }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }

    /// The latest level, nil while unknown.
    public var level: MemoryPressure? { tracker.withLock { $0.level } }
}

import Darwin
import Synchronization

/// Cumulative scheduler ticks of one core since boot, as `processor_cpu_load_info` reports them.
public struct CoreTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// One raw reading of every core.
public struct CPUTicks: Sendable, Equatable {
    public var cores: [CoreTicks]

    public init(cores: [CoreTicks]) {
        self.cores = cores
    }
}

/// CPU usage between two readings, as shares (0...1) of the elapsed ticks of all cores.
public struct CPUUsage: Sendable, Equatable {
    /// (user + system + nice) / (user + system + idle + nice), all cores together.
    public var total: Double
    public var user: Double
    public var system: Double
    /// Same formula per core, in core order.
    public var perCore: [Double]

    public init(total: Double, user: Double, system: Double, perCore: [Double]) {
        self.total = total
        self.user = user
        self.system = system
        self.perCore = perCore
    }

    /// Orange from 70 %, red from 90 % (constants until the configuration defines them).
    public var level: MetricLevel { MetricLevel(fraction: total, warning: 0.7, critical: 0.9) }

    /// Nil when the pair cannot give a usage: a counter went backwards or wrapped (32-bit), the core count changed,
    /// or no tick elapsed. The caller discards that sample.
    public static func between(_ old: CPUTicks, _ new: CPUTicks) -> CPUUsage? {
        guard !new.cores.isEmpty, old.cores.count == new.cores.count else { return nil }
        var busy: UInt64 = 0
        var all: UInt64 = 0
        var user: UInt64 = 0
        var system: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(new.cores.count)
        for (before, after) in zip(old.cores, new.cores) {
            guard after.user >= before.user, after.system >= before.system, after.idle >= before.idle,
                after.nice >= before.nice
            else { return nil }
            let u = UInt64(after.user - before.user)
            let s = UInt64(after.system - before.system)
            let n = UInt64(after.nice - before.nice)
            let coreAll = u + s + n + UInt64(after.idle - before.idle)
            busy += u + s + n
            all += coreAll
            user += u
            system += s
            perCore.append(coreAll > 0 ? Double(u + s + n) / Double(coreAll) : 0)
        }
        guard all > 0 else { return nil }
        return CPUUsage(
            total: Double(busy) / Double(all), user: Double(user) / Double(all), system: Double(system) / Double(all),
            perCore: perCore)
    }
}

/// Collector of `CPUUsage`: keeps the previous reading to compute the delta; the first reading (and the first after
/// `reset`, or after a discarded pair) yields no value.
public final class CPUCollector: MetricCollector {
    private let read: @Sendable () throws(ProbeError) -> CPUTicks
    private let previous = Mutex<CPUTicks?>(nil)

    public init(
        read: @escaping @Sendable () throws(ProbeError) -> CPUTicks = { () throws(ProbeError) in
            try MachCPU.ticks()
        }
    ) {
        self.read = read
    }

    public func sample() async throws -> CPUUsage? {
        let current = try read()
        return previous.withLock { previous in
            defer { previous = current }
            return previous.flatMap { CPUUsage.between($0, current) }
        }
    }

    public func reset() async {
        previous.withLock { $0 = nil }
    }
}

/// Mach host calls for the CPU (public API: `mach/host_info.h`, `mach/processor_info.h`).
public enum MachCPU {
    /// The host port, fetched once: every `mach_host_self()` call adds a send right to release.
    private static let host = mach_host_self()

    /// Per-core ticks from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. The kernel allocates the array in this
    /// task: it is released with `vm_deallocate` on every path.
    public static func ticks() throws(ProbeError) -> CPUTicks {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            throw .unreadable("host_processor_info: \(String(cString: mach_error_string(result)))")
        }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(count) * stride else {
            throw .unreadable("host_processor_info: \(infoCount) values for \(count) processors")
        }
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let base = index * stride
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            cores.append(
                CoreTicks(
                    user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE),
                    nice: tick(CPU_STATE_NICE)))
        }
        return CPUTicks(cores: cores)
    }
}

/// What the CPU card shows besides the usage: chip name and core counts, read once (they do not change).
public struct CPUInfo: Sendable, Equatable {
    /// `machdep.cpu.brand_string`: "Apple M4", or the Intel model string.
    public var name: String?
    public var physicalCores: Int?
    public var logicalCores: Int?
    /// Core count and name of each performance level (`hw.perflevelN.*`), level 0 first; empty when the Mac has a
    /// single level or the keys are missing.
    public var levels: [(count: Int, name: String)]

    public init(name: String?, physicalCores: Int?, logicalCores: Int?, levels: [(count: Int, name: String)]) {
        self.name = name
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.levels = levels
    }

    public static func == (lhs: CPUInfo, rhs: CPUInfo) -> Bool {
        lhs.name == rhs.name && lhs.physicalCores == rhs.physicalCores && lhs.logicalCores == rhs.logicalCores
            && lhs.levels.map(\.count) == rhs.levels.map(\.count) && lhs.levels.map(\.name) == rhs.levels.map(\.name)
    }

    /// Reads the keys documented in `sysctl(3)` and the `hw.perflevel` keys of Apple silicon; a missing key leaves
    /// its field nil (its pill is then omitted).
    public static func read(_ sysctl: some SysctlReading = SystemSysctl()) -> CPUInfo {
        var levels: [(count: Int, name: String)] = []
        if let count = sysctl.int("hw.nperflevels"), count > 1 {
            for level in 0..<count {
                guard let cores = sysctl.int("hw.perflevel\(level).logicalcpu"),
                    let name = sysctl.string("hw.perflevel\(level).name")
                else {
                    levels = []
                    break
                }
                levels.append((cores, name))
            }
        }
        return CPUInfo(
            name: sysctl.string("machdep.cpu.brand_string"), physicalCores: sysctl.int("hw.physicalcpu"),
            logicalCores: sysctl.int("hw.logicalcpu"), levels: levels)
    }

    /// "10 cores" (or "8 physical cores", "16 logical cores" with SMT) and the split per level, e.g. "4P + 6E"
    /// (initial of each level's name).
    public var pills: [String] {
        var pills: [String] = []
        switch (physicalCores, logicalCores) {
        case (let physical?, let logical?) where physical == logical: pills.append("\(physical) cores")
        case (let physical?, let logical?): pills += ["\(physical) physical cores", "\(logical) logical cores"]
        case (let physical?, nil): pills.append("\(physical) physical cores")
        case (nil, let logical?): pills.append("\(logical) logical cores")
        case (nil, nil): break
        }
        if !levels.isEmpty {
            pills.append(levels.map { "\($0.count)\($0.name.prefix(1).uppercased())" }.joined(separator: " + "))
        }
        return pills
    }
}

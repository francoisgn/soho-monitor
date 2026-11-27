import Darwin

/// Reads `sysctl(3)` values by name. Injected so that tests play back a Mac without some keys.
public protocol SysctlReading: Sendable {
    /// A string value (`machdep.cpu.brand_string`), nil when the key does not exist.
    func string(_ name: String) -> String?
    /// An integer value (`hw.logicalcpu`), nil when the key does not exist.
    func int(_ name: String) -> Int?
}

/// `sysctlbyname(3)` on this Mac.
public struct SystemSysctl: SysctlReading {
    public init() {}

    public func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    public func int(_ name: String) -> Int? {
        // Integer keys are 4 bytes (`hw.logicalcpu`) or 8 bytes (`hw.memsize`): read into 8, use the size returned.
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size: return Int(Int32(truncatingIfNeeded: value))
        case MemoryLayout<Int64>.size: return Int(value)
        default: return nil
        }
    }

    /// An unsigned 64-bit value (`hw.memsize`).
    public func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<UInt64>.size else { return nil }
        return value
    }

    /// A C structure (`vm.swapusage` → `xsw_usage`): nil unless the kernel returns exactly its size.
    public func value<T: BitwiseCopyable>(_ name: String, as type: T.Type, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }
}

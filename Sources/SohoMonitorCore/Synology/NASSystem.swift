import Foundation

/// Load and identity of the NAS: `SYNO.Core.System.Utilization` `get` v1 (CPU, memory, disk activity) and, optional,
/// `SYNO.Core.System` `info` v1 (model, DSM version, temperature, uptime). Fields as recorded on a real NAS (DSM
/// 7.1.1, 2026-11-27); percentages are whole numbers from 0 to 100 there, stored here as fractions.
public struct NASSystem: Sendable, Equatable {
    /// `cpu.user_load + system_load + other_load`, as py-synologydsm-api's `cpu_total_load` adds them
    /// (src/synology_dsm/api/core/utilization.py:86-92 at 5c486c4). Nil if one of the three is missing.
    public var cpu: Double?
    /// `memory.real_usage` (py-synologydsm-api `memory_real_usage`, same file :115-117).
    public var memory: Double?
    /// `disk.total.utilization`: how busy the disks were, in %; in the recording it is the mean of the drives' own
    /// `utilization` (35, 25, 91, 86 → 59).
    public var diskActivity: Double?
    public var model: String?
    /// `firmware_ver`, e.g. "DSM 7.1.1-42962 Update 9".
    public var dsmVersion: String?
    /// `sys_temp`, °C.
    public var temperature: Int?
    /// DSM's own flag (`temperature_warning` or `sys_tempwarn`), so no threshold is guessed here.
    public var temperatureWarning: Bool
    /// Seconds, from `up_time`.
    public var uptime: TimeInterval?

    public init(
        cpu: Double? = nil, memory: Double? = nil, diskActivity: Double? = nil, model: String? = nil,
        dsmVersion: String? = nil, temperature: Int? = nil, temperatureWarning: Bool = false,
        uptime: TimeInterval? = nil
    ) {
        self.cpu = cpu
        self.memory = memory
        self.diskActivity = diskActivity
        self.model = model
        self.dsmVersion = dsmVersion
        self.temperature = temperature
        self.temperatureWarning = temperatureWarning
        self.uptime = uptime
    }

    /// The Mac's own CPU card thresholds (70 % / 90 %, `CPUUsage.level`).
    public var cpuLevel: MetricLevel { MetricLevel(fraction: cpu, warning: 0.7, critical: 0.9) }
    /// The Mac's memory card thresholds without pressure (85 % / 95 %, `MemoryReading.level`).
    public var memoryLevel: MetricLevel { MetricLevel(fraction: memory, warning: 0.85, critical: 0.95) }
    /// As the CPU: a disk busy most of the time slows everything down.
    public var diskActivityLevel: MetricLevel { MetricLevel(fraction: diskActivity, warning: 0.7, critical: 0.9) }

    /// From the response bodies; `info` nil (not fetched or failed) leaves its fields empty.
    public static func decode(utilization: Data, info: Data?) throws(DSMError) -> NASSystem {
        let load = try DSMEnvelope.data(Utilization.self, from: utilization, api: "SYNO.Core.System.Utilization")
        var system = NASSystem()
        if let cpu = load.cpu, let user = cpu.user, let kernel = cpu.system, let other = cpu.other {
            system.cpu = percent(user + kernel + other)
        }
        system.memory = load.memory?.realUsage.map(percent)
        system.diskActivity = load.disk?.total?.utilization.map(percent)
        if let info, let details = try? DSMEnvelope.data(Info.self, from: info, api: "SYNO.Core.System") {
            system.model = details.model
            system.dsmVersion = details.firmware
            system.temperature = details.temperature
            system.temperatureWarning = details.temperatureWarning == true || details.legacyWarning == true
            system.uptime = details.upTime.flatMap(uptime)
        }
        return system
    }

    /// `up_time` read as "hours:minutes:seconds": the recorded "1856:6:43" fits only that reading (no day field,
    /// minutes and seconds below 60). Inferred from the recording, not documented by Synology: to check against DSM's
    /// own uptime display.
    public static func uptime(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let hours = parts[0], let minutes = parts[1], let seconds = parts[2], hours >= 0,
            (0..<60).contains(minutes), (0..<60).contains(seconds)
        else { return nil }
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    private static func percent(_ value: Int) -> Double { Double(min(max(value, 0), 100)) / 100 }

    private struct Utilization: Decodable {
        struct CPU: Decodable {
            var user: Int?
            var system: Int?
            var other: Int?
            enum CodingKeys: String, CodingKey {
                case user = "user_load"
                case system = "system_load"
                case other = "other_load"
            }
        }
        struct Memory: Decodable {
            var realUsage: Int?
            enum CodingKeys: String, CodingKey { case realUsage = "real_usage" }
        }
        struct Disks: Decodable {
            struct Total: Decodable {
                var utilization: Int?
            }
            var total: Total?
        }
        var cpu: CPU?
        var memory: Memory?
        var disk: Disks?
    }

    private struct Info: Decodable {
        var model: String?
        var firmware: String?
        var temperature: Int?
        var temperatureWarning: Bool?
        var legacyWarning: Bool?
        var upTime: String?
        enum CodingKeys: String, CodingKey {
            case model
            case firmware = "firmware_ver"
            case temperature = "sys_temp"
            case temperatureWarning = "temperature_warning"
            case legacyWarning = "sys_tempwarn"
            case upTime = "up_time"
        }
    }
}

/// `SYNO.Core.Upgrade.Server` `check` v1: whether DSM has an update, and which. Read-only: nothing is downloaded.
public struct NASUpdate: Sendable, Equatable {
    public var available: Bool
    public var version: String?

    public init(available: Bool, version: String?) {
        self.available = available
        self.version = version
    }

    /// What the card's badge says; nil when up to date (no badge).
    public var badge: String? {
        guard available else { return nil }
        return version.flatMap { $0.isEmpty ? nil : $0 } ?? "update available"
    }

    public static func decode(_ body: Data) throws(DSMError) -> NASUpdate {
        struct Check: Decodable {
            var available: Bool?
            var version: String?
        }
        let check = try DSMEnvelope.data(Check.self, from: body, api: "SYNO.Core.Upgrade.Server")
        return NASUpdate(available: check.available ?? false, version: check.version)
    }
}

public enum NASFormat {
    /// "DSM 7.1.1-42962 Update 9" → "DSM 7.1.1": the build and update number go to the tooltip.
    public static func shortVersion(_ version: String) -> String {
        String(version.prefix { $0 != "-" }).trimmingCharacters(in: .whitespaces)
    }

    /// "77 d 8 h", "12 h 30 min", "10 min", "< 1 min".
    public static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let days = total / 86_400
        let hours = total % 86_400 / 3600
        let minutes = total % 3600 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "< 1 min"
    }
}

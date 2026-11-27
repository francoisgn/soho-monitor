import Foundation

/// A DSM health string (volume, storage pool or disk `status`). `normal` and `attention` are the values recorded on a
/// DS416play (DSM 7.1.1, 2026-11-27); `degraded` and `crashed` are the states DSM's Storage Manager names, not seen on
/// the device yet. Anything else is kept verbatim and never shown as healthy.
public enum NASHealth: Sendable, Equatable, Hashable {
    case normal
    case attention
    case degraded
    case crashed
    case unknown(String)

    public init(dsm text: String) {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "normal": self = .normal
        case "attention": self = .attention
        case "degraded": self = .degraded
        case "crashed": self = .crashed
        default: self = .unknown(text)
        }
    }

    /// Normal is green, attention and unknown strings orange, degraded and crashed red.
    public var level: MetricLevel {
        switch self {
        case .normal: .normal
        case .attention, .unknown: .warning
        case .degraded, .crashed: .critical
        }
    }

    /// Higher is worse; ties keep the first one found.
    var severity: Int {
        switch self {
        case .normal: 0
        case .unknown: 1
        case .attention: 2
        case .degraded: 3
        case .crashed: 4
        }
    }

    public var label: String {
        switch self {
        case .normal: "Healthy"
        case .attention: "Attention"
        case .degraded: "Degraded"
        case .crashed: "Crashed"
        case .unknown(let text): text.isEmpty ? "unknown" : text
        }
    }
}

/// The worst health among several parts, and the part that has it (nil when all are normal).
public struct NASHealthSummary: Sendable, Equatable {
    public var health: NASHealth
    public var subject: String?

    public init(health: NASHealth, subject: String?) {
        self.health = health
        self.subject = subject
    }
}

public struct NASVolume: Sendable, Equatable {
    /// `vol_path` without its slash ("volume1"), else the id.
    public var name: String
    public var total: UInt64?
    public var used: UInt64?
    public var health: NASHealth
    /// `space_status.detail` when DSM gives one ("fs_almost_full"), for the tooltip.
    public var detail: String?

    public init(name: String, total: UInt64?, used: UInt64?, health: NASHealth, detail: String?) {
        self.name = name
        self.total = total
        self.used = used
        self.health = health
        self.detail = detail
    }

    /// "almost full" for the one detail recorded (`fs_almost_full`), else the health's label.
    public var statusText: String {
        if health != .normal, detail == "fs_almost_full" { return "almost full" }
        return health.label
    }

    public var usedFraction: Double? {
        guard let total, let used, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
}

public struct NASPool: Sendable, Equatable {
    /// `desc` ("SHR", "RAID 5"), else the id.
    public var name: String
    public var health: NASHealth

    public init(name: String, health: NASHealth) {
        self.name = name
        self.health = health
    }
}

public struct NASDisk: Sendable, Equatable {
    /// "Drive 1": the slot, never the model or serial.
    public var name: String
    public var health: NASHealth
    /// °C.
    public var temperature: Int?

    public init(name: String, health: NASHealth, temperature: Int?) {
        self.name = name
        self.health = health
        self.temperature = temperature
    }
}

/// `SYNO.Storage.CGI.Storage` `load_info` v1, the call DSM's Storage Manager makes. Only the fields below are decoded:
/// serials, models and uuids are never read.
public struct NASStorage: Sendable, Equatable {
    public var volumes: [NASVolume]
    public var pools: [NASPool]
    public var disks: [NASDisk]

    public init(volumes: [NASVolume], pools: [NASPool], disks: [NASDisk]) {
        self.volumes = volumes
        self.pools = pools
        self.disks = disks
    }

    /// Pools first, then disks: the worst of them, named ("Pool SHR", "Drive 2").
    public var hardware: NASHealthSummary {
        let parts = pools.map { ($0.health, "Pool \($0.name)") } + disks.map { ($0.health, $0.name) }
        var worst = NASHealthSummary(health: .normal, subject: nil)
        for (health, name) in parts where health.severity > worst.health.severity {
            worst = NASHealthSummary(health: health, subject: name)
        }
        return worst
    }

    public var maxDiskTemperature: Int? { disks.compactMap(\.temperature).max() }

    /// From the whole response body (the DSM envelope).
    public static func decode(_ body: Data) throws(DSMError) -> NASStorage {
        let data = try DSMEnvelope.data(Response.self, from: body, api: "SYNO.Storage.CGI.Storage")
        return NASStorage(
            volumes: (data.volumes ?? []).map { volume in
                let path = volume.volPath.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
                return NASVolume(
                    name: path.flatMap { $0.isEmpty ? nil : $0 } ?? volume.id ?? "volume",
                    total: volume.size?.total?.value, used: volume.size?.used?.value,
                    health: NASHealth(dsm: volume.status ?? ""),
                    detail: volume.spaceStatus?.detail.flatMap { $0.isEmpty ? nil : $0 })
            },
            pools: (data.storagePools ?? []).map { pool in
                NASPool(name: pool.desc ?? pool.id ?? "pool", health: NASHealth(dsm: pool.status ?? ""))
            },
            disks: (data.disks ?? []).map { disk in
                NASDisk(
                    name: disk.name ?? disk.id ?? "disk", health: NASHealth(dsm: disk.status ?? ""),
                    temperature: disk.temp)
            })
    }

    private struct Response: Decodable {
        var volumes: [Volume]?
        var storagePools: [Pool]?
        var disks: [Disk]?
    }

    private struct Volume: Decodable {
        struct Size: Decodable {
            var total: FlexibleUInt64?
            var used: FlexibleUInt64?
        }
        struct SpaceStatus: Decodable {
            var detail: String?
        }
        var id: String?
        var volPath: String?
        var status: String?
        var size: Size?
        var spaceStatus: SpaceStatus?

        enum CodingKeys: String, CodingKey {
            case id, status, size
            case volPath = "vol_path"
            case spaceStatus = "space_status"
        }
    }

    private struct Pool: Decodable {
        var id: String?
        var desc: String?
        var status: String?
    }

    private struct Disk: Decodable {
        var id: String?
        var name: String?
        var status: String?
        var temp: Int?
    }
}

/// DSM sends sizes as decimal strings ("7670124396544"); a number is accepted too. Anything else decodes as nil.
struct FlexibleUInt64: Decodable {
    var value: UInt64?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = UInt64(text)
        } else if let number = try? container.decode(UInt64.self) {
            value = number
        } else {
            value = nil
        }
    }
}

/// The `data` object of a body whose envelope `DSMClient.call` already checked (`success: true`).
enum DSMEnvelope {
    private struct Envelope<T: Decodable>: Decodable {
        var data: T
    }

    static func data<T: Decodable>(_ type: T.Type, from body: Data, api: String) throws(DSMError) -> T {
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: body).data
        } catch {
            throw .invalidResponse("\(api): unexpected data")
        }
    }
}

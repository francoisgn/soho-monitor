import Foundation

/// A container's state as the card shows it. From Docker's `State.Status` ("created", "running", "paused",
/// "restarting", "removing", "exited", "dead") and `State.Health.Status` ("none", "starting", "healthy",
/// "unhealthy"), Docker Engine API v1.43, ContainerState and Health
/// (https://docs.docker.com/reference/api/engine/version/v1.43.yaml, read 2026-11-27).
public enum NASContainerState: Sendable, Equatable, Hashable {
    /// Running, healthy, starting its health check, or without one.
    case running
    case unhealthy
    case restarting
    case paused
    /// Exited, or created and never started.
    case stopped(exitCode: Int?)
    /// Anything else ("dead", "removing", an unknown string), verbatim.
    case other(String)

    public init(status: String, health: String?, exitCode: Int?) {
        switch status.lowercased() {
        case "running":
            self = health?.lowercased() == "unhealthy" ? .unhealthy : .running
        case "restarting": self = .restarting
        case "paused": self = .paused
        // "stopped": a fallback for DSM's top-level `status`, whose only recorded value is "running".
        case "exited", "created", "stopped": self = .stopped(exitCode: exitCode)
        default: self = .other(status)
        }
    }

    public var label: String {
        switch self {
        case .running: "running"
        case .unhealthy: "unhealthy"
        case .restarting: "restarting"
        case .paused: "paused"
        case .stopped(let code?) where code != 0: "exited (\(code))"
        case .stopped: "stopped"
        case .other(let text): text.isEmpty ? "unknown" : text
        }
    }
}

/// Name, image and state only: `cmd`, environment, mounts, ports and labels may hold secrets and are never decoded.
public struct NASContainer: Sendable, Equatable {
    public var name: String
    public var image: String?
    public var state: NASContainerState
    /// Listed in `synology.expected_stopped`: stopped is its normal state.
    public var expectedStopped: Bool

    public init(name: String, image: String?, state: NASContainerState, expectedStopped: Bool) {
        self.name = name
        self.image = image
        self.state = state
        self.expectedStopped = expectedStopped
    }

    /// Red: unhealthy or exited with an error. Orange: stopped without being expected to, restarting, paused or
    /// unknown. Running, or stopped as expected: normal.
    public var level: MetricLevel {
        switch state {
        case .running: return .normal
        case .unhealthy: return .critical
        case .stopped(let code):
            if expectedStopped { return .normal }
            if let code, code != 0 { return .critical }
            return .warning
        case .restarting, .paused, .other: return .warning
        }
    }
}

/// `SYNO.Docker.Container` `list` v1 (`limit=-1`: the whole list in one answer, measured on the NAS on 2026-11-27).
public struct NASContainerList: Sendable, Equatable {
    /// Problems first (red, then orange), then by name.
    public var containers: [NASContainer]
    /// `total` as DSM reports it; more than `containers.count` when the answer was cut.
    public var total: Int

    public var running: Int { containers.count { $0.state == .running || $0.state == .unhealthy } }

    public static func decode(_ body: Data, expectedStopped: Set<String>) throws(DSMError) -> NASContainerList {
        let list = try DSMEnvelope.data(Response.self, from: body, api: "SYNO.Docker.Container")
        let containers = (list.containers ?? []).compactMap { item -> NASContainer? in
            guard let name = item.name, !name.isEmpty else { return nil }
            let state = NASContainerState(
                status: item.state?.status ?? item.status ?? "", health: item.state?.health?.status,
                exitCode: item.state?.exitCode)
            return NASContainer(
                name: name, image: item.image, state: state, expectedStopped: expectedStopped.contains(name))
        }
        let sorted = containers.sorted { left, right in
            let (l, r) = (rank(left.level), rank(right.level))
            return l != r ? l > r : left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return NASContainerList(containers: sorted, total: max(list.total ?? containers.count, containers.count))
    }

    private static func rank(_ level: MetricLevel) -> Int {
        switch level {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    private struct Response: Decodable {
        var containers: [Item]?
        var total: Int?
    }

    private struct Item: Decodable {
        struct State: Decodable {
            struct Health: Decodable {
                var status: String?
                enum CodingKeys: String, CodingKey { case status = "Status" }
            }
            var status: String?
            var exitCode: Int?
            var health: Health?
            enum CodingKeys: String, CodingKey {
                case status = "Status"
                case exitCode = "ExitCode"
                case health = "Health"
            }
        }
        var name: String?
        var image: String?
        var status: String?
        var state: State?
        enum CodingKeys: String, CodingKey {
            case name, image, status
            case state = "State"
        }
    }
}

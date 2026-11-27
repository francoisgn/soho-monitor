import Foundation

/// One part of the NAS card.
public enum NASSection<Value: Sendable & Equatable>: Sendable, Equatable {
    /// Not in `synology.sections`: never fetched, not shown.
    case off
    /// The API is not on this NAS (the Docker package is not installed): hidden, no error.
    case absent
    case value(Value)
    /// Why it is missing ("no permission for SYNO.Storage.CGI.Storage"); the other sections still show.
    case unavailable(String)
}

/// What one polling cycle brought back.
public struct NASSnapshot: Sendable, Equatable {
    public var system: NASSection<NASSystem>
    public var storage: NASSection<NASStorage>
    public var update: NASSection<NASUpdate>
    public var containers: NASSection<NASContainerList>
    /// TLS state of the connection, for the card's warning.
    public var trust: TLSTrustState?

    public init(
        system: NASSection<NASSystem> = .off, storage: NASSection<NASStorage> = .off,
        update: NASSection<NASUpdate> = .off, containers: NASSection<NASContainerList> = .off,
        trust: TLSTrustState? = nil
    ) {
        self.system = system
        self.storage = storage
        self.update = update
        self.containers = containers
        self.trust = trust
    }
}

/// One polling cycle of the NAS card, for `RemotePoller`: the enabled sections one after the other (a small NAS gets
/// one request at a time), through one `DSMClient` whose login is reused from cycle to cycle.
///
/// A failure ends the whole cycle (the card shows it instead of the data) when it concerns every section: no saved
/// password, refused credentials, or no answer at all yet (unreachable, TLS refused). Once the NAS has answered, a
/// failing call costs only its section. An API the account may not use, or that the NAS lacks, is not asked again
/// until the configuration or the credentials change (a new fetcher): each refusal would cost a fresh login.
public actor NASFetcher {
    private let config: SynologyConfig
    private let client: DSMClient
    private let trust: @Sendable () -> TLSTrustState?
    private let now: @Sendable () -> Date

    private var lastUpdateCheck: (at: Date, section: NASSection<NASUpdate>)?
    /// APIs refused for good in this session, with the section's text.
    private var refused: [String: NASRefusal] = [:]
    /// Set during a cycle once the NAS has answered a call.
    private var answered = false
    /// The TLS refusal behind the last failed cycle, for the fingerprint to pin; nil after a success.
    public private(set) var lastTLSFailure: TLSFailure?

    public init(
        config: SynologyConfig, client: DSMClient, trust: @escaping @Sendable () -> TLSTrustState?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.client = client
        self.trust = trust
        self.now = now
    }

    static let utilization = "SYNO.Core.System.Utilization"
    static let system = "SYNO.Core.System"
    static let storage = "SYNO.Storage.CGI.Storage"
    static let upgrade = "SYNO.Core.Upgrade.Server"
    static let docker = "SYNO.Docker.Container"

    public func fetch() async -> Result<NASSnapshot, RemoteFailure> {
        answered = false
        do throws(RemoteFailure) {
            var snapshot = NASSnapshot()
            if config.sections.contains(.system) { snapshot.system = try await fetchSystem() }
            if config.sections.contains(.storage) {
                snapshot.storage = try await section(Self.storage) { () async throws(DSMError) in
                    try NASStorage.decode(try await self.client.call(Self.storage, version: 1, method: "load_info"))
                }
            }
            if config.sections.contains(.update) { snapshot.update = try await fetchUpdate() }
            if config.sections.contains(.docker) {
                let expected = config.expectedStopped
                snapshot.containers = try await section(Self.docker, absentHides: true) { () async throws(DSMError) in
                    let body = try await self.client.call(
                        Self.docker, version: 1, method: "list",
                        parameters: ["limit": .int(-1), "offset": .int(0), "type": .string("all")])
                    return try NASContainerList.decode(body, expectedStopped: expected)
                }
            }
            snapshot.trust = trust()
            lastTLSFailure = nil
            return .success(snapshot)
        } catch {
            return .failure(error)
        }
    }

    /// Ends the session on the NAS (the card is going away).
    public func close() async {
        await client.logout()
    }

    // MARK: Sections

    private func fetchSystem() async throws(RemoteFailure) -> NASSection<NASSystem> {
        let load = try await section(Self.utilization) { () async throws(DSMError) in
            try await self.client.call(Self.utilization, version: 1, method: "get")
        }
        guard case .value(let utilization) = load else { return Self.retyped(load) }
        // Optional: model, version, temperature and uptime; the load shows without them.
        let info = try await section(Self.system) { () async throws(DSMError) in
            try await self.client.call(Self.system, version: 1, method: "info")
        }
        let infoBody: Data? = if case .value(let body) = info { body } else { nil }
        do {
            return .value(try NASSystem.decode(utilization: utilization, info: infoBody))
        } catch {
            return .unavailable(error.message)
        }
    }

    private func fetchUpdate() async throws(RemoteFailure) -> NASSection<NASUpdate> {
        let interval = TimeInterval(config.updateIntervalHours) * 3600
        if let last = lastUpdateCheck, now().timeIntervalSince(last.at) < interval { return last.section }
        let result = try await section(Self.upgrade) { () async throws(DSMError) in
            try NASUpdate.decode(try await self.client.call(Self.upgrade, version: 1, method: "check"))
        }
        // Only an answer is kept for the interval: a failed check is tried again at the next cycle.
        if case .value = result { lastUpdateCheck = (now(), result) }
        return result
    }

    /// Runs one section's calls. A failure that concerns every section is thrown (ends the cycle); any other
    /// becomes the section's text.
    private func section<T: Sendable & Equatable>(
        _ api: String, absentHides: Bool = false, _ work: () async throws(DSMError) -> T
    ) async throws(RemoteFailure) -> NASSection<T> {
        if let refusal = refused[api] { return refusal.section(absentHides: absentHides) }
        do throws(DSMError) {
            let value = try await work()
            answered = true
            return .value(value)
        } catch {
            if Self.endsCycle(error, answered: answered) {
                if case .tls(let failure) = error { lastTLSFailure = failure }
                throw error.remoteFailure
            }
            answered = answered || Self.isAnswer(error)
            switch error {
            case .permissionDenied:
                refused[api] = .permission(api)
            case .apiUnavailable:
                refused[api] = .missing(error.message)
            default:
                break
            }
            return refused[api]?.section(absentHides: absentHides) ?? .unavailable(error.message)
        }
    }

    /// Credentials problems always end the cycle; no answer at all yet (unreachable, TLS) too.
    static func endsCycle(_ error: DSMError, answered: Bool) -> Bool {
        switch error {
        case .needsSetup, .keychain, .sessionLost: return true
        case .permissionDenied: return false
        case .unreachable, .tls: return !answered
        default: return error.isAuthFailure
        }
    }

    /// The NAS replied (with an error code or an unexpected body): it is reachable.
    private static func isAnswer(_ error: DSMError) -> Bool {
        switch error {
        case .unreachable, .tls, .needsSetup, .keychain: false
        default: true
        }
    }

    private static func retyped<A: Sendable & Equatable, B: Sendable & Equatable>(_ section: NASSection<A>)
        -> NASSection<B>
    {
        switch section {
        case .off: .off
        case .absent: .absent
        case .unavailable(let reason): .unavailable(reason)
        case .value: .unavailable("unexpected")
        }
    }
}

/// An API that will not answer during this session.
enum NASRefusal: Sendable, Equatable {
    case permission(String)
    case missing(String)

    func section<T: Sendable & Equatable>(absentHides: Bool) -> NASSection<T> {
        switch self {
        case .permission(let api): .unavailable("no permission for \(api)")
        case .missing(let message): absentHides ? .absent : .unavailable(message)
        }
    }
}

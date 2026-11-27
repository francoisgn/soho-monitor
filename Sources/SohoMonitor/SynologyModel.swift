import Foundation
import Network
import Observation
import SohoMonitorCore

/// State of the NAS module: its configuration, whether its password is in the Keychain, and the card's data. Once a
/// password is saved, a `RemotePoller` runs `NASFetcher` cycles every `interval_seconds`, only while the desktop
/// panel is visible and the network path is up; everything network runs off the main actor (poller and fetcher are
/// actors).
@MainActor @Observable
final class SynologyModel {
    enum Credentials: Equatable {
        case unknown
        case missing
        case saved
        case unavailable(String)
    }

    private(set) var config: SynologyConfig?
    private(set) var credentials: Credentials = .unknown
    /// TLS state of the last successful test, for its warning.
    private(set) var lastTrust: TLSTrustState?
    /// `Test Saved Password`, shared by the card and the credential window; reset on a config change, save or
    /// removal, which drops the result of a test still running.
    private var savedTestState = SavedPasswordTest()
    var savedTest: SavedPasswordTest.Phase { savedTestState.phase }

    /// The card's data; nil while there is nothing to poll (no configuration or no saved password).
    private(set) var nas: RemoteState<NASSnapshot>?
    /// The certificate refusal behind a failed cycle, for the fingerprint row.
    private(set) var tlsFailure: TLSFailure?

    /// Opens the credential window; set by the app delegate.
    @ObservationIgnored var presentSetup: () -> Void = {}
    /// Session cache in front of the Keychain: a secret is read at most once per session.
    @ObservationIgnored let secrets: SecretCache

    @ObservationIgnored private var poller: RemotePoller<NASSnapshot, ContinuousClock>?
    @ObservationIgnored private var fetcher: NASFetcher?
    /// Bumped at each rebuild: updates from an older poller are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    /// Demand changes run one after the other (acquire and release are actor calls).
    @ObservationIgnored private var demandChain: Task<Void, Never>?
    @ObservationIgnored private var held: (poller: RemotePoller<NASSnapshot, ContinuousClock>, token: RemoteDemand)?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// `SOHO_MONITOR_NAS_DEMO`: a folder of recorded DSM answers played back instead of the NAS (screenshots, demos);
    /// no Keychain read and no network then.
    @ObservationIgnored private let demoDirectory = ProcessInfo.processInfo.environment["SOHO_MONITOR_NAS_DEMO"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    init(store: any SecretStore = KeychainSecretStore()) {
        secrets = SecretCache(store: store)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.setPathSatisfied(satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "soho-monitor.synology.path", qos: .utility))
    }

    /// The desktop panel is shown or hidden: the poller runs only while it is shown.
    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        updateDemand()
    }

    private func setPathSatisfied(_ satisfied: Bool) {
        guard satisfied != pathSatisfied else { return }
        pathSatisfied = satisfied
        guard let poller else { return }
        Task { await poller.setPathSatisfied(satisfied) }
    }

    /// A new poller for the current configuration and password (or none), replacing the old one: its demand is
    /// released and its DSM session closed.
    private func rebuildPoller() {
        generation += 1
        observeTask?.cancel()
        observeTask = nil
        let old = fetcher
        poller = nil
        fetcher = nil
        tlsFailure = nil
        updateDemand(closing: old)
        guard let config, credentials == .saved else {
            nas = nil
            return
        }
        let transport: any HTTPTransport =
            demoDirectory.map { NASReplayTransport(directory: $0) } ?? SynologyConnection.transport(for: config)
        let password =
            demoDirectory == nil
            ? SynologyConnection.password(item: config.keychainItem, secrets: secrets) : Self.demoPassword()
        let client = DSMClient(
            baseURL: config.baseURL, account: config.user, password: password, transport: transport)
        let fetcher = NASFetcher(config: config, client: client, trust: { transport.trustState })
        let poller = RemotePoller<NASSnapshot, ContinuousClock>(
            policy: RemotePollPolicy(interval: .seconds(config.intervalSeconds)), clock: ContinuousClock(),
            fetch: { await fetcher.fetch() })
        self.poller = poller
        self.fetcher = fetcher
        nas = .loading
        let generation = generation
        let satisfied = pathSatisfied
        observeTask = Task { [weak self] in
            await poller.setPathSatisfied(satisfied)
            for await state in await poller.updates() {
                guard let self, self.generation == generation else { return }
                await self.receive(state, from: fetcher, generation: generation)
            }
        }
        updateDemand()
    }

    private func receive(_ state: RemoteState<NASSnapshot>, from fetcher: NASFetcher, generation: Int) async {
        var failure: TLSFailure?
        switch state {
        case .failed, .stale: failure = await fetcher.lastTLSFailure
        default: break
        }
        guard generation == self.generation else { return }
        nas = state
        tlsFailure = failure
        // The TLS warning follows each successful cycle (a renewed or expired pinned certificate).
        if case .ok(let snapshot, _) = state, let trust = snapshot.trust { lastTrust = trust }
    }

    /// Holds a demand on the current poller while the panel is visible; releases the old one (and logs out of its
    /// session) after a rebuild.
    private func updateDemand(closing old: NASFetcher? = nil) {
        let want = visible
        let current = poller
        let previous = demandChain
        demandChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let held = self.held, !(want && held.poller === current) {
                self.held = nil
                await held.poller.release(held.token)
            }
            if let old { await old.close() }
            if want, self.held == nil, let current {
                let token = await current.acquire()
                // Rebuilt or hidden while acquiring: give it back at once.
                if current === self.poller, self.visible {
                    self.held = (current, token)
                } else {
                    await current.release(token)
                }
            }
        }
    }

    var isEnabled: Bool { config != nil }

    func apply(_ config: SynologyConfig?) {
        guard config != self.config else { return }
        let itemChanged = config?.keychainItem != self.config?.keychainItem
        let hostChanged =
            config?.host != self.config?.host || config?.port != self.config?.port || config?.tls != self.config?.tls
        self.config = config
        savedTestState.reset()
        // The TLS state is known only after a connection (Test, Save; the data cards' polling, #27, will refresh it
        // at each cycle); it stays valid while the host and its policy do not change.
        if hostChanged { lastTrust = nil }
        // A new item: its existence check rebuilds the poller once known.
        if itemChanged { refreshCredentials() } else { rebuildPoller() }
    }

    /// Checks that the item exists without reading the secret (no Keychain prompt), off the main actor.
    func refreshCredentials() {
        guard let item = config?.keychainItem else {
            credentials = .unknown
            rebuildPoller()
            return
        }
        if demoDirectory != nil {
            credentials = .saved
            rebuildPoller()
            return
        }
        let secrets = secrets
        Task {
            let found = await Task.detached(priority: .utility) { () -> Credentials in
                do throws(SecretStoreError) {
                    return try secrets.contains(item) ? .saved : .missing
                } catch {
                    return .unavailable(error.message)
                }
            }.value
            guard self.config?.keychainItem == item else { return }
            self.credentials = found
            self.rebuildPoller()
        }
    }

    /// `Test connection`: discovery, login with the typed password, logout. Nothing is saved.
    func test(password: String) async -> Result<TLSTrustState, DSMError> {
        guard let config else { return .failure(.needsSetup) }
        let result = await Self.test(config: config, password: password)
        if case .success(let state) = result { lastTrust = state }
        return result
    }

    /// `Save`: the same test, then the Keychain only if it passed.
    func save(password: String) async -> CredentialSetupOutcome {
        guard let config else { return .testFailed(.needsSetup) }
        let outcome = await Self.testThenSave(config: config, password: password, secrets: secrets)
        if case .saved(let state) = outcome {
            lastTrust = state
            credentials = .saved
            savedTestState.reset()
            rebuildPoller()
        }
        return outcome
    }

    func remove() async -> SecretStoreError? {
        guard let item = config?.keychainItem else { return nil }
        let secrets = secrets
        let error = await Task.detached(priority: .utility) { () -> SecretStoreError? in
            do throws(SecretStoreError) {
                try secrets.remove(item)
                return nil
            } catch {
                return error
            }
        }.value
        if error == nil {
            credentials = .missing
            savedTestState.reset()
            rebuildPoller()
        }
        return error
    }

    /// `Test Saved Password`: reads the password from the Keychain (the macOS access prompt the first time, where
    /// the user chooses Always Allow), then the same test as a typed password.
    @discardableResult
    func testSavedPassword() async -> SavedPasswordTestReply {
        guard let config else { return .done(.failure(.needsSetup)) }
        guard let ticket = savedTestState.begin() else { return .alreadyRunning }
        let result = await Self.testSaved(config: config, secrets: secrets)
        let reply = savedTestState.finish(ticket, with: result)
        guard reply != .overtaken else { return reply }
        switch result {
        case .success(let state):
            lastTrust = state
            credentials = .saved
            // Polling stopped on a refused or missing password: it works now, start again.
            if poller == nil || nas.map(Self.waitsForCredentials) == true { rebuildPoller() }
        case .failure(let error):
            // The item vanished since the existence check: the card goes back to "Needs setup".
            if error == .needsSetup {
                credentials = .missing
                rebuildPoller()
            }
        }
        return reply
    }

    private nonisolated static func demoPassword() -> @Sendable () async -> Result<String, DSMError> {
        { .success("demo") }
    }

    private static func waitsForCredentials(_ state: RemoteState<NASSnapshot>) -> Bool {
        switch state {
        case .authFailed, .needsSetup: true
        default: false
        }
    }

    // Off the main actor: the network exchange and the Keychain read or write (which may prompt).
    private nonisolated static func test(config: SynologyConfig, password: String) async
        -> Result<TLSTrustState, DSMError>
    {
        await SynologyConnection.test(
            config: config, password: password, transport: SynologyConnection.transport(for: config))
    }

    private nonisolated static func testSaved(config: SynologyConfig, secrets: SecretCache) async
        -> Result<TLSTrustState, DSMError>
    {
        await CredentialSetup.testSaved(
            item: config.keychainItem, secrets: secrets,
            test: { saved in
                await SynologyConnection.test(
                    config: config, password: saved, transport: SynologyConnection.transport(for: config))
            })
    }

    private nonisolated static func testThenSave(config: SynologyConfig, password: String, secrets: SecretCache)
        async -> CredentialSetupOutcome
    {
        await CredentialSetup.testThenSave(
            password: password, item: config.keychainItem, store: secrets,
            test: { typed in
                await SynologyConnection.test(
                    config: config, password: typed, transport: SynologyConnection.transport(for: config))
            })
    }
}

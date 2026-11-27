import Foundation
import Observation
import SohoMonitorCore

/// State of the NAS module in this lot: its configuration and whether its password is in the Keychain. The data
/// cards (#23–#27) will poll through `RemotePoller` with the same Keychain cache and transport.
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
    /// The last `Test Saved Password`, shown on the card and in the credential window.
    private(set) var savedTest: SavedPasswordTest = .idle

    enum SavedPasswordTest: Equatable {
        case idle
        case testing
        case passed(TLSTrustState)
        case failed(DSMError)
    }

    /// Opens the credential window; set by the app delegate.
    @ObservationIgnored var presentSetup: () -> Void = {}
    /// Session cache in front of the Keychain: a secret is read at most once per session.
    @ObservationIgnored let secrets: SecretCache

    init(store: any SecretStore = KeychainSecretStore()) {
        secrets = SecretCache(store: store)
    }

    var isEnabled: Bool { config != nil }

    func apply(_ config: SynologyConfig?) {
        guard config != self.config else { return }
        let itemChanged = config?.keychainItem != self.config?.keychainItem
        let hostChanged =
            config?.host != self.config?.host || config?.port != self.config?.port || config?.tls != self.config?.tls
        self.config = config
        savedTest = .idle
        // The TLS state is known only after a connection (Test, Save; the data cards' polling, #27, will refresh it
        // at each cycle); it stays valid while the host and its policy do not change.
        if hostChanged { lastTrust = nil }
        if itemChanged { refreshCredentials() }
    }

    /// Checks that the item exists without reading the secret (no Keychain prompt), off the main actor.
    func refreshCredentials() {
        guard let item = config?.keychainItem else {
            credentials = .unknown
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
            savedTest = .idle
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
            savedTest = .idle
        }
        return error
    }

    /// `Test Saved Password`: reads the password from the Keychain (the macOS access prompt the first time, where
    /// the user chooses Always Allow), then the same test as a typed password. Nil when a test is already running,
    /// or when the configuration changed meanwhile (the result belongs to the previous NAS).
    @discardableResult
    func testSavedPassword() async -> Result<TLSTrustState, DSMError>? {
        guard let config else { return .failure(.needsSetup) }
        guard savedTest != .testing else { return nil }
        savedTest = .testing
        let result = await Self.testSaved(config: config, secrets: secrets)
        guard self.config == config else { return nil }
        switch result {
        case .success(let state):
            lastTrust = state
            credentials = .saved
            savedTest = .passed(state)
        case .failure(let error):
            // The item vanished since the existence check: the card goes back to "Needs setup".
            if error == .needsSetup { credentials = .missing }
            savedTest = .failed(error)
        }
        return result
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

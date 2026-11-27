import Foundation

/// What Save in the credential sheet did.
public enum CredentialSetupOutcome: Sendable, Equatable {
    /// The test passed and the password is in the Keychain; the connection's TLS state, for its warning.
    case saved(TLSTrustState)
    /// The test failed: nothing was saved.
    case testFailed(DSMError)
    /// The test passed but the Keychain refused the write.
    case saveFailed(SecretStoreError)
}

/// The rules of the credential sheet: Save is enabled only with a password, and saves only after a successful
/// connection test with it (a wrong password never replaces a good one).
public enum CredentialSetup {
    /// Never trimmed: spaces may be part of a password.
    public static func canSubmit(password: String) -> Bool {
        !password.isEmpty
    }

    /// Runs `test` with the typed password, then saves it only if the test passed. Runs off the main actor (the
    /// Keychain may prompt).
    public static func testThenSave(
        password: String, item: String, store: any SecretStore,
        test: @Sendable (String) async -> Result<TLSTrustState, DSMError>
    ) async -> CredentialSetupOutcome {
        switch await test(password) {
        case .failure(let error):
            return .testFailed(error)
        case .success(let state):
            do {
                try store.save(password, for: item)
                return .saved(state)
            } catch {
                return .saveFailed(error)
            }
        }
    }

    /// `Test Saved Password`: reads the saved secret afresh from the store (the first read of an item another app
    /// created brings the macOS access prompt), then runs the same `test` as a typed password. No item is
    /// `.needsSetup` and a Keychain error is `.keychain`: `test` is not run, nothing is sent. Runs off the main actor.
    public static func testSaved(
        item: String, secrets: SecretCache,
        test: @Sendable (String) async -> Result<TLSTrustState, DSMError>
    ) async -> Result<TLSTrustState, DSMError> {
        secrets.forget(item)
        let saved: String?
        do {
            saved = try secrets.secret(for: item)
        } catch {
            return .failure(.keychain(error))
        }
        guard let saved else { return .failure(.needsSetup) }
        return await test(saved)
    }
}

/// What a `Test Saved Password` request came to.
public enum SavedPasswordTestReply: Sendable, Equatable {
    case done(Result<TLSTrustState, DSMError>)
    /// Another test of the saved password was running (from the card or the window): its result shows there.
    case alreadyRunning
    /// A configuration change, save or removal overtook it: the result was about a previous password or NAS.
    case overtaken
}

/// The state of `Test Saved Password`, shared by the NAS card and the credential window: one test at a time, and a
/// result arriving after a `reset` (configuration change, save, removal) is dropped.
public struct SavedPasswordTest: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case testing
        case passed(TLSTrustState)
        case failed(DSMError)
    }

    public private(set) var phase: Phase = .idle
    private var generation = 0

    public init() {}

    /// A ticket for `finish`, or nil when a test is already running.
    public mutating func begin() -> Int? {
        guard phase != .testing else { return nil }
        phase = .testing
        return generation
    }

    /// Records the result of the test that `ticket` started, unless a `reset` overtook it.
    public mutating func finish(_ ticket: Int, with result: Result<TLSTrustState, DSMError>) -> SavedPasswordTestReply {
        guard ticket == generation, phase == .testing else { return .overtaken }
        switch result {
        case .success(let state): phase = .passed(state)
        case .failure(let error): phase = .failed(error)
        }
        return .done(result)
    }

    /// Back to idle; the result of a test still running will be dropped.
    public mutating func reset() {
        phase = .idle
        generation &+= 1
    }
}

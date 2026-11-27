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
}

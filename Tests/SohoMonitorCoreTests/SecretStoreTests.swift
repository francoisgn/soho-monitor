import Foundation
import Security
import Testing

@testable import SohoMonitorCore

@Suite struct SecretStoreTests {
    @Test func fakeStoreRoundTripsSaveReadUpdateDelete() throws {
        let store = InMemorySecretStore()
        #expect(try store.secret(for: "synology") == nil)
        #expect(try store.contains("synology") == false)
        try store.save("first", for: "synology")
        #expect(try store.secret(for: "synology") == "first")
        #expect(try store.contains("synology"))
        try store.save("second", for: "synology")  // an update, not a second item
        #expect(try store.secret(for: "synology") == "second")
        #expect(store.count == 1)
        try store.remove("synology")
        #expect(try store.secret(for: "synology") == nil)
        try store.remove("synology")  // removing a missing item is not an error
    }

    @Test func keychainQueriesUseTheAppServiceAndThisDeviceOnly() {
        let query = KeychainSecretStore(service: "soho-monitor").baseQuery(for: "synology")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "soho-monitor")
        #expect(query[kSecAttrAccount as String] as? String == "synology")
        let attributes = KeychainSecretStore.addedAttributes
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test func keychainStatusesBecomeExplainedErrors() {
        #expect(SecretStoreError(status: errSecAuthFailed) == .accessDenied)
        #expect(SecretStoreError(status: errSecUserCanceled) == .accessDenied)
        #expect(SecretStoreError(status: errSecInteractionNotAllowed) == .locked)
        #expect(SecretStoreError(status: -1).message.contains("-1"))
        #expect(SecretStoreError.accessDenied.message.contains("Always Allow"))
    }

    @Test func cacheReadsTheStoreOnceAndForgetsOnChange() throws {
        let store = InMemorySecretStore()
        try store.save("s3cret", for: "synology")
        let cache = SecretCache(store: store)
        #expect(try cache.secret(for: "synology") == "s3cret")
        #expect(try cache.secret(for: "synology") == "s3cret")
        #expect(store.reads == 1)
        try cache.save("new", for: "synology")
        #expect(try cache.secret(for: "synology") == "new")
        try cache.remove("synology")
        #expect(try cache.secret(for: "synology") == nil)
    }

    @Test func cacheDoesNotRememberAFailure() throws {
        let store = InMemorySecretStore()
        store.failure = .accessDenied
        let cache = SecretCache(store: store)
        #expect(throws: SecretStoreError.accessDenied) { try cache.secret(for: "synology") }
        store.failure = nil
        try store.save("later", for: "synology")
        #expect(try cache.secret(for: "synology") == "later")
    }
}

@Suite struct CredentialSetupTests {
    @Test func saveNeedsAPassword() {
        #expect(CredentialSetup.canSubmit(password: "") == false)
        #expect(CredentialSetup.canSubmit(password: " ") == true)  // a password is never trimmed
    }

    @Test func aFailedTestSavesNothing() async throws {
        let store = InMemorySecretStore()
        let outcome = await CredentialSetup.testThenSave(
            password: "wrong", item: "synology", store: store,
            test: { _ in .failure(.invalidCredentials) })
        #expect(outcome == .testFailed(.invalidCredentials))
        #expect(try store.secret(for: "synology") == nil)
    }

    @Test func aPassingTestSavesThePassword() async throws {
        let store = InMemorySecretStore()
        let tested = TestedPasswords()
        let outcome = await CredentialSetup.testThenSave(
            password: "right", item: "synology", store: store,
            test: { password in
                await tested.append(password)
                return .success(.trusted)
            })
        #expect(outcome == .saved(.trusted))
        #expect(try store.secret(for: "synology") == "right")
        #expect(await tested.values == ["right"])
    }

    @Test func aKeychainErrorAfterAPassingTestIsReported() async {
        let store = InMemorySecretStore()
        store.failure = .accessDenied
        let outcome = await CredentialSetup.testThenSave(
            password: "right", item: "synology", store: store, test: { _ in .success(.pinned) })
        #expect(outcome == .saveFailed(.accessDenied))
    }

    @Test func testingTheSavedPasswordReadsTheKeychainAndRunsTheSameTest() async throws {
        let store = InMemorySecretStore()
        try store.save("saved", for: "synology")
        let tested = TestedPasswords()
        let result = await CredentialSetup.testSaved(
            item: "synology", secrets: SecretCache(store: store),
            test: { password in
                await tested.append(password)
                return .success(.pinnedExpired)
            })
        #expect(result == .success(.pinnedExpired))
        #expect(await tested.values == ["saved"])
        #expect(store.reads == 1)
    }

    @Test func testingTheSavedPasswordRereadsTheKeychainInsteadOfTheSessionCopy() async throws {
        let store = InMemorySecretStore()
        try store.save("old", for: "synology")
        let cache = SecretCache(store: store)
        #expect(try cache.secret(for: "synology") == "old")
        // Changed outside the app (Keychain Access, `security`): the test must use what the Keychain holds now.
        try store.save("new", for: "synology")
        let tested = TestedPasswords()
        _ = await CredentialSetup.testSaved(
            item: "synology", secrets: cache,
            test: { password in
                await tested.append(password)
                return .success(.trusted)
            })
        #expect(await tested.values == ["new"])
        #expect(store.reads == 2)
        #expect(try cache.secret(for: "synology") == "new")
        #expect(store.reads == 2)
    }

    @Test func aSavedPasswordThatVanishedNeedsSetupAndSendsNothing() async {
        let tested = TestedPasswords()
        let result = await CredentialSetup.testSaved(
            item: "synology", secrets: SecretCache(store: InMemorySecretStore()),
            test: { password in
                await tested.append(password)
                return .success(.trusted)
            })
        #expect(result == .failure(.needsSetup))
        #expect(await tested.values.isEmpty)
    }

    @Test(arguments: [SecretStoreError.accessDenied, .locked, .unreadable])
    func aKeychainErrorOnTheSavedPasswordIsReportedOnce(error: SecretStoreError) async throws {
        let store = InMemorySecretStore()
        try store.save("saved", for: "synology")
        store.failure = error
        let tested = TestedPasswords()
        let result = await CredentialSetup.testSaved(
            item: "synology", secrets: SecretCache(store: store),
            test: { password in
                await tested.append(password)
                return .success(.trusted)
            })
        #expect(result == .failure(.keychain(error)))
        #expect(await tested.values.isEmpty)
    }

    @Test func aFailedTestOfTheSavedPasswordKeepsItsDSMError() async throws {
        let store = InMemorySecretStore()
        try store.save("saved", for: "synology")
        let result = await CredentialSetup.testSaved(
            item: "synology", secrets: SecretCache(store: store),
            test: { _ in .failure(.unreachable("timed out")) })
        #expect(result == .failure(.unreachable("timed out")))
        #expect(store.count == 1)
    }

    private actor TestedPasswords {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }
}

@Suite struct SavedPasswordTestTests {
    @Test func aTestRunsOnceAtATime() {
        var state = SavedPasswordTest()
        let ticket = state.begin()
        #expect(ticket != nil)
        #expect(state.phase == .testing)
        #expect(state.begin() == nil)
        if let ticket {
            #expect(state.finish(ticket, with: .success(.pinnedExpired)) == .done(.success(.pinnedExpired)))
        }
        #expect(state.phase == .passed(.pinnedExpired))
        #expect(state.begin() != nil)
    }

    @Test func aFailureIsKept() throws {
        var state = SavedPasswordTest()
        let ticketTicket = state.begin()
        let ticket = try #require(ticketTicket)
        #expect(
            state.finish(ticket, with: .failure(.keychain(.accessDenied))) == .done(.failure(.keychain(.accessDenied))))
        #expect(state.phase == .failed(.keychain(.accessDenied)))
    }

    @Test func aResultOvertakenByAResetIsDropped() throws {
        var state = SavedPasswordTest()
        let staleTicket = state.begin()
        let stale = try #require(staleTicket)
        state.reset()  // config change, save or remove
        #expect(state.phase == .idle)
        let freshTicket = state.begin()
        let fresh = try #require(freshTicket)
        #expect(state.finish(stale, with: .failure(.invalidCredentials)) == .overtaken)
        #expect(state.phase == .testing)
        #expect(state.finish(fresh, with: .success(.trusted)) == .done(.success(.trusted)))
        #expect(state.phase == .passed(.trusted))
    }

    @Test func aResultAfterAResetWithoutANewTestIsDropped() throws {
        var state = SavedPasswordTest()
        let staleTicket = state.begin()
        let stale = try #require(staleTicket)
        state.reset()
        #expect(state.finish(stale, with: .success(.trusted)) == .overtaken)
        #expect(state.phase == .idle)
    }
}

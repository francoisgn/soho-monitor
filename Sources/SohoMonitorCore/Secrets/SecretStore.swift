import Foundation
import Security
import Synchronization

/// Where module secrets (NAS password, controller API key) live: never in the configuration, logs or UI. An item is
/// named by the `keychain_item` of its module's section. Calls may block (Keychain access prompt): never on the main
/// actor.
public protocol SecretStore: Sendable {
    /// Nil when there is no such item.
    func secret(for item: String) throws(SecretStoreError) -> String?
    /// True when the item exists, without reading the secret (no access prompt).
    func contains(_ item: String) throws(SecretStoreError) -> Bool
    /// Creates the item, or updates it when it exists (never a duplicate).
    func save(_ secret: String, for item: String) throws(SecretStoreError)
    /// Removing a missing item is not an error.
    func remove(_ item: String) throws(SecretStoreError)
}

/// A Keychain failure, explained for the UI. Never carries the secret.
public enum SecretStoreError: Error, Sendable, Equatable {
    /// The user refused access, or cancelled the prompt.
    case accessDenied
    /// The Keychain is locked or cannot prompt now.
    case locked
    /// The item exists but does not hold UTF-8 text.
    case unreadable
    case unexpected(OSStatus)

    public init(status: OSStatus) {
        switch status {
        case errSecAuthFailed, errSecUserCanceled: self = .accessDenied
        case errSecInteractionNotAllowed, errSecNotAvailable: self = .locked
        default: self = .unexpected(status)
        }
    }

    public var message: String {
        switch self {
        case .accessDenied:
            "Keychain access denied: allow soho-monitor when macOS asks (Always Allow), or check the item in "
                + "Keychain Access"
        case .locked: "the Keychain is locked: unlock it, then try again"
        case .unreadable: "the Keychain item does not hold a text password: remove it and save it again"
        case .unexpected(let status): "Keychain error \(status)"
        }
    }
}

/// The login Keychain, items of class generic password: service `soho-monitor`, account = the item name. Readable
/// after the first unlock, on this Mac only (never synchronised).
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "soho-monitor"

    let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    func baseQuery(for item: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item,
        ]
    }

    static var addedAttributes: [String: Any] {
        [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecAttrLabel as String: "soho-monitor",
        ]
    }

    public func secret(for item: String) throws(SecretStoreError) -> String? {
        var query = baseQuery(for: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw .unreadable
        }
        return text
    }

    public func contains(_ item: String) throws(SecretStoreError) -> Bool {
        var query = baseQuery(for: item)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        return true
    }

    public func save(_ secret: String, for item: String) throws(SecretStoreError) {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(
            baseQuery(for: item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError(status: update) }
        var add = baseQuery(for: item).merging(Self.addedAttributes) { _, new in new }
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        // Added by someone else between the two calls: update it instead of failing.
        if status == errSecDuplicateItem {
            let retry = SecItemUpdate(
                baseQuery(for: item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard retry == errSecSuccess else { throw SecretStoreError(status: retry) }
            return
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func remove(_ item: String) throws(SecretStoreError) {
        let status = SecItemDelete(baseQuery(for: item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }
}

/// In memory, for tests and previews; `failure` makes every call fail.
public final class InMemorySecretStore: SecretStore {
    private struct State {
        var items: [String: String] = [:]
        var failure: SecretStoreError?
        var reads = 0
    }

    private let state = Mutex(State())

    public init(_ items: [String: String] = [:]) {
        state.withLock { $0.items = items }
    }

    public var failure: SecretStoreError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    /// Number of `secret(for:)` calls that reached the store.
    public var reads: Int { state.withLock { $0.reads } }
    public var count: Int { state.withLock { $0.items.count } }

    public func secret(for item: String) throws(SecretStoreError) -> String? {
        try state.withLock { state throws(SecretStoreError) in
            if let failure = state.failure { throw failure }
            state.reads += 1
            return state.items[item]
        }
    }

    public func contains(_ item: String) throws(SecretStoreError) -> Bool {
        try state.withLock { state throws(SecretStoreError) in
            if let failure = state.failure { throw failure }
            return state.items[item] != nil
        }
    }

    public func save(_ secret: String, for item: String) throws(SecretStoreError) {
        try state.withLock { state throws(SecretStoreError) in
            if let failure = state.failure { throw failure }
            state.items[item] = secret
        }
    }

    public func remove(_ item: String) throws(SecretStoreError) {
        try state.withLock { state throws(SecretStoreError) in
            if let failure = state.failure { throw failure }
            state.items[item] = nil
        }
    }
}

/// Reads each secret lazily, once per session, and keeps it in memory; a save or a removal through the cache
/// replaces or forgets it. A failed read is not remembered: the next call asks the store again.
public final class SecretCache: Sendable {
    private let store: any SecretStore
    private let cached = Mutex<[String: String]>([:])

    public init(store: any SecretStore) {
        self.store = store
    }

    public func secret(for item: String) throws(SecretStoreError) -> String? {
        if let hit = cached.withLock({ $0[item] }) { return hit }
        let value = try store.secret(for: item)
        if let value { cached.withLock { $0[item] = value } }
        return value
    }

    public func contains(_ item: String) throws(SecretStoreError) -> Bool {
        if cached.withLock({ $0[item] }) != nil { return true }
        return try store.contains(item)
    }

    public func save(_ secret: String, for item: String) throws(SecretStoreError) {
        cached.withLock { _ = $0.removeValue(forKey: item) }
        try store.save(secret, for: item)
        cached.withLock { $0[item] = secret }
    }

    public func remove(_ item: String) throws(SecretStoreError) {
        cached.withLock { _ = $0.removeValue(forKey: item) }
        try store.remove(item)
    }

    /// Forgets every cached secret (the item may have been changed outside the app).
    public func forgetAll() {
        cached.withLock { $0.removeAll() }
    }
}

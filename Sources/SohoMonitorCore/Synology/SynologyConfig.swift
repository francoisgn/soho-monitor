import Foundation
import Yams

/// `synology:` section: one NAS reached through the DSM Web API, over HTTPS only. The password is never in the file:
/// it lives in the Keychain under `keychain_item` (`SecretStore`).
public struct SynologyConfig: Sendable, Equatable {
    public static let defaultPort = 5001
    public static let defaultKeychainItem = "synology"
    /// Polling floor: a small NAS must not be woken up or loaded more often than this.
    public static let minimumIntervalSeconds = 60
    public static let maximumIntervalSeconds = 86_400

    public var host: String
    public var port: Int
    /// The dedicated DSM account (read-only, no 2-factor authentication).
    public var user: String
    /// Account name of the Keychain item (service `soho-monitor`) that holds the password.
    public var keychainItem: String
    public var tls: TLSPolicy
    public var intervalSeconds: Int

    public init(
        host: String, port: Int = defaultPort, user: String, keychainItem: String = defaultKeychainItem,
        tls: TLSPolicy = .systemTrust, intervalSeconds: Int = minimumIntervalSeconds
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.keychainItem = keychainItem
        self.tls = tls
        self.intervalSeconds = intervalSeconds
    }

    /// `https://host:port`; the host was validated when the file was read.
    public var baseURL: URL {
        Self.baseURL(host: host, port: port) ?? URL(fileURLWithPath: "/")
    }

    static func baseURL(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        return components.url
    }
}

extension Reader {
    /// Keys that would put a secret in the file: refused with an error, so that the value is removed rather than
    /// silently ignored. The value itself is never echoed.
    static let secretKeys: Set<String> = ["password", "passwd", "pass", "secret", "token", "api_key"]

    mutating func readSynology(_ node: Node) -> SynologyConfig? {
        guard case .mapping(let mapping) = node else {
            error(node, "synology", "expected a mapping (host, port, user, keychain_item, tls, interval_seconds)")
            return nil
        }
        for (key, _) in mapping {
            if let name = key.scalar?.string, Self.secretKeys.contains(name.lowercased()) {
                error(
                    key, "synology.\(name)",
                    "secrets go in the Keychain, never in this file: remove this key (see config/example.yaml)")
            }
        }
        // The secret keys count as known here: already reported as errors above, not again as unknown.
        let keys = entries(
            mapping, at: "synology",
            known: Self.secretKeys.union(["host", "port", "user", "keychain_item", "tls", "interval_seconds"]))
        let errorCount = errors.count

        let host = nonEmptyString(keys["host"])
        if let host {
            if !Self.isPlainHost(host) {
                error(
                    keys["host"], "synology.host",
                    "must be a host name or IP address only (no scheme, port or path): the app always uses https")
            }
        } else {
            error(keys["host"] ?? node, "synology.host", "required: the NAS host name or IP address")
        }
        var port = SynologyConfig.defaultPort
        if let node = keys["port"] {
            if let value = wholeNumber(node), (1...65_535).contains(value) {
                port = value
            } else {
                error(node, "synology.port", "must be a port number between 1 and 65535 (DSM https: 5001)")
            }
        }
        let user = nonEmptyString(keys["user"])
        if user == nil {
            error(keys["user"] ?? node, "synology.user", "required: the dedicated DSM account (a non-empty string)")
        }
        var keychainItem = SynologyConfig.defaultKeychainItem
        if let node = keys["keychain_item"] {
            if let value = nonEmptyString(node) {
                keychainItem = value
            } else {
                error(node, "synology.keychain_item", "must be a non-empty string")
            }
        }
        var interval = SynologyConfig.minimumIntervalSeconds
        if let node = keys["interval_seconds"] {
            let range = SynologyConfig.minimumIntervalSeconds...SynologyConfig.maximumIntervalSeconds
            if let value = wholeNumber(node), range.contains(value) {
                interval = value
            } else {
                error(
                    node, "synology.interval_seconds",
                    "must be a whole number of seconds, at least 60 (polling floor) and at most 86400")
            }
        }
        let tls = keys["tls"].map { readTLS($0, at: "synology.tls") } ?? .systemTrust

        guard errors.count == errorCount, let host, let user, let tls else { return nil }
        return SynologyConfig(
            host: host, port: port, user: user, keychainItem: keychainItem, tls: tls, intervalSeconds: interval)
    }

    /// `tls:` of a LAN host: `pin_sha256` or `allow_self_signed`, not both; neither (or an empty mapping) is system
    /// trust. Nil after an error.
    mutating func readTLS(_ node: Node, at keyPath: String) -> TLSPolicy? {
        if node.null != nil { return .systemTrust }  // `tls:` with nothing under it
        guard case .mapping(let mapping) = node else {
            error(node, keyPath, "expected a mapping (pin_sha256 or allow_self_signed)")
            return nil
        }
        let keys = entries(mapping, at: keyPath, known: ["pin_sha256", "allow_self_signed"])
        var pin: CertificateFingerprint?
        var valid = true
        if let pinNode = keys["pin_sha256"] {
            pin = pinNode.scalar.flatMap { CertificateFingerprint($0.string) }
            if pin == nil {
                valid = false
                error(
                    pinNode, "\(keyPath).pin_sha256",
                    "must be a SHA-256 fingerprint: 64 hexadecimal digits, `:` allowed "
                        + "(openssl x509 -noout -fingerprint -sha256)")
            }
        }
        var allowSelfSigned = false
        if let allowNode = keys["allow_self_signed"] {
            if let value = allowNode.bool {
                allowSelfSigned = value
            } else {
                valid = false
                error(allowNode, "\(keyPath).allow_self_signed", "must be true or false")
            }
        }
        guard valid else { return nil }
        if keys["pin_sha256"] != nil, allowSelfSigned {
            error(node, keyPath, "use either pin_sha256 or allow_self_signed, not both")
            return nil
        }
        if let pin { return .pinned(pin) }
        return allowSelfSigned ? .allowSelfSigned : .systemTrust
    }

    /// A host name or an IPv4 address, as `URLComponents` accepts it: no scheme, user, port, path or spaces.
    static func isPlainHost(_ host: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "/:@?#[]% ").union(.whitespacesAndNewlines)
        guard host.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }
        return SynologyConfig.baseURL(host: host, port: SynologyConfig.defaultPort) != nil
    }
}

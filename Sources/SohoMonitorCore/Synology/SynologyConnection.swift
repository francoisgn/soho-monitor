import Foundation

/// Glue between the configuration, the Keychain and `DSMClient`.
public enum SynologyConnection {
    /// The password for `DSMClient`, read through the session cache at login time: no item is `.needsSetup` (and
    /// the client sends nothing), a Keychain error is reported as such.
    public static func password(item: String, secrets: SecretCache) -> @Sendable () async -> Result<String, DSMError> {
        {
            do throws(SecretStoreError) {
                guard let secret = try secrets.secret(for: item) else { return .failure(.needsSetup) }
                return .success(secret)
            } catch {
                return .failure(.keychain(error))
            }
        }
    }

    /// `Test connection` of the credential sheet: discovery, login with the typed password, logout. On success, the
    /// TLS state of the connection (for its warning).
    public static func test(config: SynologyConfig, password: String, transport: any HTTPTransport) async
        -> Result<TLSTrustState, DSMError>
    {
        let client = DSMClient(
            baseURL: config.baseURL, account: config.user, password: { .success(password) }, transport: transport)
        do {
            try await client.login()
        } catch {
            return .failure(error)
        }
        await client.logout()
        return .success(transport.trustState ?? .trusted)
    }

    /// A transport for this NAS: its host, port and TLS policy.
    public static func transport(for config: SynologyConfig) -> URLSessionTransport {
        URLSessionTransport(host: config.host, port: config.port, policy: config.tls)
    }
}

import CryptoKit
import Foundation
import Security
import Synchronization

/// How the certificate of one configured host is trusted (`tls:` of its configuration section). Shared by the LAN
/// modules (Synology, UniFi). Applies to that host only, never globally: no App Transport Security exception.
public enum TLSPolicy: Sendable, Equatable {
    /// Default: the system's trust store and the usual checks (name, dates, chain).
    case systemTrust
    /// `pin_sha256`: only the leaf certificate with this SHA-256 fingerprint is accepted, even self-signed or
    /// expired (an expired one is shown as a warning). A different certificate is refused, never re-pinned.
    case pinned(CertificateFingerprint)
    /// `allow_self_signed: true`: any certificate is accepted. Encrypted, but anyone on the LAN can impersonate the
    /// host; the UI shows a permanent warning. `pin_sha256` is the safe way to trust a self-signed certificate.
    case allowSelfSigned
}

/// SHA-256 of a certificate's DER encoding, what `openssl x509 -noout -fingerprint -sha256` prints.
public struct CertificateFingerprint: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// Accepts 64 hexadecimal digits, in either case, optionally grouped by `:` or spaces.
    public init?(_ text: String) {
        let digits = text.filter { $0 != ":" && !$0.isWhitespace }
        guard digits.count == 64, digits.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.bytes = bytes
    }

    public init(sha256Of der: Data) {
        bytes = Array(SHA256.hash(data: der))
    }

    /// Upper-case pairs separated by `:`, as `openssl` prints them.
    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// An accepted connection, as the UI shows it. Every state but `.trusted` and `.pinned` carries a warning.
public enum TLSTrustState: Sendable, Equatable {
    /// System trust succeeded.
    case trusted
    /// The pinned certificate was presented.
    case pinned
    /// The pinned certificate was presented, but it has expired: accepted, with a warning.
    case pinnedExpired
    /// `allow_self_signed`: whatever was presented was accepted.
    case insecure

    /// Shown next to the module's data; nil when nothing needs saying.
    public var warning: String? {
        switch self {
        case .trusted, .pinned: nil
        case .pinnedExpired: "certificate expired, pinned"
        case .insecure: "TLS not verified (allow_self_signed): pin the certificate instead"
        }
    }
}

/// A refused certificate. The connection is cancelled before any request is sent.
public enum TLSFailure: Error, Sendable, Equatable {
    /// System trust, and the leaf has expired.
    case certificateExpired(presented: CertificateFingerprint)
    /// System trust failed for another reason (self-signed, unknown authority, wrong name).
    case untrusted(reason: String, presented: CertificateFingerprint)
    /// A pin is configured and another certificate was presented (rotated, or an impostor).
    case certificateMismatch(presented: CertificateFingerprint)
    /// No certificate could be read from the challenge.
    case noCertificate

    /// The fingerprint the host presented, to fill `pin_sha256` after checking it on the device.
    public var presented: CertificateFingerprint? {
        switch self {
        case .certificateExpired(let fingerprint), .untrusted(_, let fingerprint),
            .certificateMismatch(let fingerprint):
            fingerprint
        case .noCertificate: nil
        }
    }

    public var message: String {
        switch self {
        case .certificateExpired: "certificate expired; renew it in DSM or pin its fingerprint"
        case .untrusted(let reason, _): "certificate not trusted (\(reason)); pin its fingerprint if it is yours"
        case .certificateMismatch(let presented): "pinned certificate changed: the host now presents \(presented)"
        case .noCertificate: "no certificate presented"
        }
    }
}

/// Applies a `TLSPolicy` to the `SecTrust` of one server-trust challenge.
public struct TLSTrustEvaluator: Sendable {
    let host: String
    let policy: TLSPolicy
    let now: @Sendable () -> Date

    public init(host: String, policy: TLSPolicy, now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.policy = policy
        self.now = now
    }

    public func evaluate(_ trust: SecTrust) -> Result<TLSTrustState, TLSFailure> {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return .failure(.noCertificate)
        }
        let presented = CertificateFingerprint(sha256Of: SecCertificateCopyData(leaf) as Data)
        let date = now()
        let expired = SecCertificateCopyNotValidAfterDate(leaf).map { ($0 as Date) < date } ?? false
        switch policy {
        case .allowSelfSigned:
            return .success(.insecure)
        case .pinned(let pin):
            // The pin is the whole identity check: name, chain and dates are not required.
            guard presented == pin else { return .failure(.certificateMismatch(presented: presented)) }
            return .success(expired ? .pinnedExpired : .pinned)
        case .systemTrust:
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            SecTrustSetVerifyDate(trust, date as CFDate)
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) { return .success(.trusted) }
            if expired { return .failure(.certificateExpired(presented: presented)) }
            let reason = error.map { CFErrorCopyDescription($0) as String } ?? "evaluation failed"
            return .failure(.untrusted(reason: reason, presented: presented))
        }
    }
}

/// `URLSession` delegate for the session of one configured host: applies its `TLSPolicy` to that host and port
/// only (every other challenge gets the default handling), and refuses redirects (credentials and the session id
/// never follow a redirect to another place). Keeps the outcome of the last evaluation for the UI.
public final class HostTrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let host: String
    private let port: Int
    private let evaluator: TLSTrustEvaluator
    private let last = Mutex<Result<TLSTrustState, TLSFailure>?>(nil)

    public init(host: String, port: Int, policy: TLSPolicy, now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host.lowercased()
        self.port = port
        evaluator = TLSTrustEvaluator(host: host, policy: policy, now: now)
    }

    /// State of the last accepted connection; nil before the first one or after a refusal.
    public var lastState: TLSTrustState? {
        guard case .success(let state) = last.withLock({ $0 }) else { return nil }
        return state
    }

    /// Why the last connection was refused; nil when it was accepted.
    public var lastFailure: TLSFailure? {
        guard case .failure(let failure) = last.withLock({ $0 }) else { return nil }
        return failure
    }

    /// Called before each request: a reused connection raises no new challenge, so an older refusal must not be
    /// taken for the reason of a later error (a cancelled task).
    public func forgetFailure() {
        last.withLock { if case .failure = $0 { $0 = nil } }
    }

    /// nil: not ours, default handling. `.useCredential` or `.cancel` otherwise.
    func disposition(for challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition? {
        answer(for: challenge).map(\.0)
    }

    private func answer(for challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?)?
    {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            space.host.lowercased() == host, space.port == port
        else { return nil }
        guard let trust = space.serverTrust else {
            last.withLock { $0 = .failure(.noCertificate) }
            return (.cancelAuthenticationChallenge, nil)
        }
        let result = evaluator.evaluate(trust)
        last.withLock { $0 = result }
        switch result {
        case .success: return (.useCredential, URLCredential(trust: trust))
        case .failure: return (.cancelAuthenticationChallenge, nil)
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        answer(for: challenge) ?? (.performDefaultHandling, nil)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        answer(for: challenge) ?? (.performDefaultHandling, nil)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

import Foundation

/// One form POST. Its descriptions show the method and path only: the fields may hold a password or a session id,
/// so a request can be logged or printed in a test failure without leaking them.
public struct HTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var url: URL
    public var method = "POST"
    /// In order; sent as `application/x-www-form-urlencoded`.
    public var fields: [(name: String, value: String)]

    public init(url: URL, fields: [(String, String)]) {
        self.url = url
        self.fields = fields.map { (name: $0.0, value: $0.1) }
    }

    /// The value of the first field with this name.
    public subscript(name: String) -> String? {
        fields.first { $0.name == name }?.value
    }

    public var body: Data { Self.formBody(fields.map { ($0.name, $0.value) }) }

    public var description: String { "\(method) \(url.path)" }
    public var debugDescription: String { description }

    /// Percent-encodes every byte but the unreserved characters of RFC 3986 (`A-Z a-z 0-9 - . _ ~`), so that `&`,
    /// `=`, `+` or `%` in a password reach the server unchanged.
    public static func formBody(_ fields: [(String, String)]) -> Data {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum TransportError: Error, Sendable, Equatable {
    /// DNS failure, refused, timeout, no route or no network, with a short reason.
    case unreachable(String)
    /// The certificate was refused by the host's `TLSPolicy`: the request was never sent.
    case tls(TLSFailure)
    case failed(String)

    /// The reason of `unreachable` when macOS Local Network privacy denies the app (TN3179,
    /// https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
    public static let localNetworkDenied =
        "blocked by macOS Local Network privacy: allow SohoMonitor in System Settings › Privacy & Security › Local "
        + "Network"
}

/// Sends requests to one host. A protocol so that clients are tested with a stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse
    /// The TLS state of the last accepted connection, for the UI's warning; nil before one.
    var trustState: TLSTrustState? { get }
}

/// `URLSession` for one configured host: ephemeral (no cookie, cache or credential storage), short timeouts, the
/// host's `TLSPolicy` through `HostTrustDelegate`, redirects refused.
public final class URLSessionTransport: HTTPTransport {
    public let trust: HostTrustDelegate
    private let session: URLSession
    private let timeout: TimeInterval
    private let host: String

    public init(host: String, port: Int, policy: TLSPolicy, timeout: TimeInterval = 10) {
        trust = HostTrustDelegate(host: host, port: port, policy: policy)
        self.timeout = timeout
        self.host = host
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 1.5
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public var trustState: TLSTrustState? { trust.lastState }

    public func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        var urlRequest = URLRequest(
            url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = request.body
        trust.forgetFailure()
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPResponse(status: status, body: data)
        } catch {
            throw Self.map(error, host: host, tlsFailure: trust.lastFailure)
        }
    }

    /// True for a dotted-quad IPv4 or an IPv6 address (brackets and zone allowed), never for a name.
    static func isIPLiteral(_ host: String) -> Bool {
        var literal = Substring(host)
        if literal.hasPrefix("["), literal.hasSuffix("]") { literal = literal.dropFirst().dropLast() }
        if let zone = literal.firstIndex(of: "%") { literal = literal[..<zone] }
        var v4 = in_addr()
        var v6 = in6_addr()
        return String(literal).withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    /// A refusal by the policy surfaces as a cancelled or certificate error: report the policy's reason instead.
    static func map(_ error: any Error, host: String, tlsFailure: TLSFailure?) -> TransportError {
        guard let error = error as? URLError else { return .failed(String(describing: type(of: error))) }
        let tlsCodes: Set<URLError.Code> = [
            .cancelled, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
        ]
        if let tlsFailure, tlsCodes.contains(error.code) { return .tls(tlsFailure) }
        switch error.code {
        case .timedOut: return .unreachable("timed out")
        case .cannotFindHost, .dnsLookupFailed:
            // An IP literal needs no lookup: macOS reports Local Network privacy denial this way (no DNS record).
            return .unreachable(isIPLiteral(host) ? TransportError.localNetworkDenied : "host not found")
        case .cannotConnectToHost: return .unreachable("connection refused")
        case .networkConnectionLost: return .unreachable("connection lost")
        case .notConnectedToInternet: return .unreachable("no network")
        case .internationalRoamingOff, .dataNotAllowed, .callIsActive: return .unreachable("no network")
        case .secureConnectionFailed: return .failed("TLS handshake failed")
        default: return .failed("network error \(error.code.rawValue)")
        }
    }
}

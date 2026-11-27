import Foundation

/// One API as `SYNO.API.Info` describes it.
public struct DSMAPI: Sendable, Equatable, Decodable {
    public var path: String
    public var minVersion: Int
    public var maxVersion: Int
    /// `"JSON"`: every parameter value is sent JSON-encoded (guide p. 4, 14).
    public var requestFormat: String?

    public init(path: String, minVersion: Int, maxVersion: Int, requestFormat: String?) {
        self.path = path
        self.minVersion = minVersion
        self.maxVersion = maxVersion
        self.requestFormat = requestFormat
    }
}

/// A parameter value; encoded raw or as JSON depending on the API's `requestFormat`.
public enum DSMParameter: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case strings([String])

    func encoded(json: Bool) -> String {
        switch self {
        case .string(let value):
            guard json else { return value }
            return Self.json(value)
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .strings(let values):
            guard json else { return values.joined(separator: ",") }
            return "[" + values.map(Self.json).joined(separator: ",") + "]"
        }
    }

    private static func json(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// A read-only client of the DSM Web API, after Synology's "DSM Login Web API Guide" (2023-04-19): discovery with
/// `SYNO.API.Info` (always at `/webapi/entry.cgi`, p. 5), login with `SYNO.API.Auth` (`format=sid`, p. 15-16), every
/// call with `_sid` and, when the login returned one, the CSRF token (p. 4, 11, 17). Everything is a form POST: the
/// password and the session id travel in the encrypted body, never in a URL (which servers and proxies log).
///
/// The token goes in the `X-SYNO-TOKEN` header, not in the body. The guide calls it a "request parameter" and shows
/// it only in GET query strings (p. 11, 17); a DSM 7 NAS measured on 2026-11-27 (curl, same session,
/// `SYNO.Core.System` info) answered error 119 to `SynoToken` in a POST body, and success to the header (or to a query
/// string, which would put the secrets in the URL).
///
/// The session lives in memory only. A session error (105, 106, 107, 119) gets one fresh login and one retry; an
/// auth error never retries. Concurrent calls share one login.
public actor DSMClient {
    public static let infoPath = "entry.cgi"
    /// The version the guide recommends (p. 15), used when the NAS supports it.
    static let preferredAuthVersion = 6
    static let minimumAuthVersion = 3
    /// Seconds a login may take: a DS416play answered a v6 login in 3.8 s (a v7 one in 29 s), above what other calls
    /// need.
    public static let loginTimeout: TimeInterval = 30

    private struct Session: Equatable {
        var sid: String
        var synoToken: String?
    }

    private let baseURL: URL
    private let account: String
    private let password: @Sendable () async -> Result<String, DSMError>
    private let transport: any HTTPTransport
    private let sessionName: String

    private var apis: [String: DSMAPI] = [:]
    private var session: Session?
    private var loginTask: Task<Session, any Error>?

    /// `password` is asked for at each login only (lazily: no Keychain read before a request is needed).
    public init(
        baseURL: URL, account: String, password: @escaping @Sendable () async -> Result<String, DSMError>,
        transport: any HTTPTransport, sessionName: String = "soho-monitor"
    ) {
        self.baseURL = baseURL
        self.account = account
        self.password = password
        self.transport = transport
        self.sessionName = sessionName
    }

    /// The descriptions of these APIs, from the cache or one `SYNO.API.Info` query for the missing ones. An API the
    /// NAS does not list is absent from the result.
    public func apis(_ names: [String]) async throws(DSMError) -> [String: DSMAPI] {
        let missing = names.filter { apis[$0] == nil }
        if !missing.isEmpty {
            let request = HTTPRequest(
                url: url(path: Self.infoPath),
                fields: [
                    ("api", "SYNO.API.Info"), ("version", "1"), ("method", "query"),
                    ("query", missing.joined(separator: ",")),
                ])
            let data = try await send(request, api: "SYNO.API.Info")
            let found: [String: DSMAPI]
            do {
                found = try JSONDecoder().decode(DataEnvelope<[String: DSMAPI]>.self, from: data).data
            } catch {
                throw .invalidResponse("SYNO.API.Info: unexpected data")
            }
            apis.merge(found) { _, new in new }
        }
        return apis.filter { names.contains($0.key) }
    }

    /// Logs in now if there is no session (`Test connection`).
    public func login() async throws(DSMError) {
        _ = try await currentSession()
    }

    /// Ends the session on the NAS (best effort) and forgets it.
    public func logout() async {
        guard let ended = session else { return }
        session = nil
        guard let auth = try? await authAPI() else { return }
        let request = sessionRequest(
            url: url(path: auth.path),
            fields: [("api", "SYNO.API.Auth"), ("version", String(auth.version)), ("method", "logout")], ended)
        _ = try? await send(request, api: "SYNO.API.Auth")
    }

    /// Calls a method and returns the raw response body (the documented envelope, `success: true`).
    public func call(_ api: String, version: Int, method: String, parameters: [String: DSMParameter] = [:])
        async throws(DSMError) -> Data
    {
        // The session first: without a saved password nothing at all is sent, not even the discovery.
        let first = try await currentSession()
        let description = try await resolve(api, version: version)
        do throws(DSMError) {
            return try await send(api, description, version: version, method: method, parameters, first)
        } catch .api(_, let code) where DSMError.sessionCodes.contains(code) {
            let fresh = try await renewSession(replacing: first)
            do throws(DSMError) {
                return try await send(api, description, version: version, method: method, parameters, fresh)
            } catch .api(_, let again) where DSMError.sessionCodes.contains(again) {
                throw again == 105 ? .permissionDenied : .sessionLost(code: again)
            }
        }
    }

    /// Calls a method and decodes its `data` object.
    public func call<T: Decodable>(
        _ api: String, version: Int, method: String, parameters: [String: DSMParameter] = [:], as type: T.Type
    ) async throws(DSMError) -> T {
        let body = try await call(api, version: version, method: method, parameters: parameters)
        do {
            return try JSONDecoder().decode(DataEnvelope<T>.self, from: body).data
        } catch {
            throw .invalidResponse("\(api) \(method): unexpected data")
        }
    }

    // MARK: Session

    private func currentSession() async throws(DSMError) -> Session {
        if let session { return session }
        return try await renewSession(replacing: nil)
    }

    /// A new session, unless another call already replaced `stale` (compare-and-set, L35): then that one.
    private func renewSession(replacing stale: Session?) async throws(DSMError) -> Session {
        if let session, session != stale { return session }
        session = nil
        let task: Task<Session, any Error>
        if let loginTask {
            task = loginTask
        } else {
            task = Task { try await self.performLogin() }
            loginTask = task
        }
        let result = await task.result
        if loginTask == task { loginTask = nil }
        switch result {
        case .success(let fresh):
            session = fresh
            return fresh
        case .failure(let error):
            throw (error as? DSMError) ?? .invalidResponse("login failed")
        }
    }

    private func performLogin() async throws(DSMError) -> Session {
        let password = try await self.password().get()
        let auth = try await authAPI()
        var fields = [
            ("api", "SYNO.API.Auth"), ("version", String(auth.version)), ("method", "login"), ("account", account),
            ("passwd", password), ("session", sessionName), ("format", "sid"),
        ]
        if auth.version >= 6 { fields.append(("enable_syno_token", "yes")) }
        var request = HTTPRequest(url: url(path: auth.path), fields: fields)
        request.timeout = Self.loginTimeout
        let data: Data
        do throws(DSMError) {
            data = try await send(request, api: "SYNO.API.Auth")
        } catch .api(_, let code) {
            throw DSMError.login(code: code)
        }
        struct LoginData: Decodable {
            var sid: String
            var synotoken: String?
        }
        guard let login = try? JSONDecoder().decode(DataEnvelope<LoginData>.self, from: data).data,
            !login.sid.isEmpty
        else { throw .invalidResponse("SYNO.API.Auth login: no session id") }
        return Session(sid: login.sid, synoToken: login.synotoken.flatMap { $0.isEmpty ? nil : $0 })
    }

    private func authAPI() async throws(DSMError) -> (path: String, version: Int) {
        guard let auth = try await apis(["SYNO.API.Auth"])["SYNO.API.Auth"] else {
            throw .apiUnavailable("SYNO.API.Auth")
        }
        let range = auth.minVersion...auth.maxVersion
        if range.contains(Self.preferredAuthVersion) { return (auth.path, Self.preferredAuthVersion) }
        guard auth.maxVersion >= Self.minimumAuthVersion else { throw .apiUnavailable("SYNO.API.Auth v3+") }
        return (auth.path, auth.maxVersion)
    }

    /// `_sid` in the body, the token in its header: DSM ignores a body `SynoToken` (type doc).
    private func sessionRequest(url: URL, fields: [(String, String)], _ session: Session) -> HTTPRequest {
        var request = HTTPRequest(url: url, fields: fields + [("_sid", session.sid)])
        if let token = session.synoToken { request.headers = [(name: Self.tokenHeader, value: token)] }
        return request
    }

    static let tokenHeader = "X-SYNO-TOKEN"

    // MARK: Requests

    private func resolve(_ api: String, version: Int) async throws(DSMError) -> DSMAPI {
        guard let description = try await apis([api])[api] else { throw .apiUnavailable(api) }
        guard (description.minVersion...description.maxVersion).contains(version) else {
            throw .apiUnavailable("\(api) v\(version)")
        }
        return description
    }

    private func send(
        _ api: String, _ description: DSMAPI, version: Int, method: String, _ parameters: [String: DSMParameter],
        _ session: Session
    ) async throws(DSMError) -> Data {
        let json = description.requestFormat?.uppercased() == "JSON"
        let encoded = parameters.sorted { $0.key < $1.key }.map { ($0.key, $0.value.encoded(json: json)) }
        let request = sessionRequest(
            url: url(path: description.path),
            fields: [("api", api), ("version", String(version)), ("method", method)] + encoded, session)
        return try await send(request, api: api)
    }

    /// Sends and checks the envelope; returns the whole body. `success: false` becomes `.api(name, code)`.
    private func send(_ request: HTTPRequest, api: String) async throws(DSMError) -> Data {
        let response: HTTPResponse
        do throws(TransportError) {
            response = try await transport.send(request)
        } catch {
            switch error {
            case .unreachable(let reason): throw .unreachable(reason)
            case .tls(let failure): throw .tls(failure)
            case .failed(let reason): throw .unreachable(reason)
            }
        }
        guard response.status == 200 else { throw .invalidResponse("HTTP \(response.status)") }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.body) else {
            throw .invalidResponse("\(api): not JSON")
        }
        guard envelope.success else {
            guard let code = envelope.error?.code else { throw .invalidResponse("\(api): failure without a code") }
            throw .api(name: api, code: code)
        }
        return response.body
    }

    private func url(path: String) -> URL {
        baseURL.appending(path: "webapi").appending(path: path)
    }

    private struct Envelope: Decodable {
        struct Failure: Decodable {
            var code: Int
        }

        var success: Bool
        var error: Failure?
    }

    private struct DataEnvelope<T: Decodable>: Decodable {
        var data: T
    }
}

extension DSMError {
    /// How the poller treats it: stop on credentials (or a Keychain that refuses: no prompt storm), back off on the
    /// rest.
    public var remoteFailure: RemoteFailure {
        switch self {
        case .needsSetup: return .needsSetup
        case .unreachable(let reason): return .unreachable(reason)
        case .keychain: return .authFailed(message)
        default: return isAuthFailure ? .authFailed(message) : .failed(message)
        }
    }
}

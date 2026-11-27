import Foundation
import Synchronization
import Testing

@testable import SohoMonitorCore

/// Answers each request with the next scripted response for its API and method, and records every request.
final class StubTransport: HTTPTransport {
    struct Reply: Sendable {
        var status = 200
        var body: String
    }

    private struct State {
        var replies: [String: [Result<Reply, TransportError>]] = [:]
        var requests: [HTTPRequest] = []
    }

    private let state = Mutex(State())
    let trustState: TLSTrustState? = .trusted

    /// `key`: `"<api> <method>"`, e.g. `"SYNO.API.Auth login"`. The last reply repeats.
    func on(_ key: String, _ replies: Result<Reply, TransportError>...) {
        state.withLock { $0.replies[key, default: []].append(contentsOf: replies) }
    }

    func on(_ key: String, json: String...) {
        state.withLock { $0.replies[key, default: []].append(contentsOf: json.map { .success(Reply(body: $0)) }) }
    }

    /// Replaces the scripted replies of `key`.
    func replace(_ key: String, _ replies: Result<Reply, TransportError>...) {
        state.withLock { $0.replies[key] = replies }
    }

    func replace(_ key: String, json: String...) {
        state.withLock { $0.replies[key] = json.map { .success(Reply(body: $0)) } }
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }

    func requests(_ key: String) -> [HTTPRequest] {
        requests.filter { "\($0["api"] ?? "") \($0["method"] ?? "")" == key }
    }

    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        let reply = state.withLock { state -> Result<Reply, TransportError>? in
            state.requests.append(request)
            let key = "\(request["api"] ?? "") \(request["method"] ?? "")"
            guard var queue = state.replies[key], !queue.isEmpty else { return nil }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            state.replies[key] = queue
            return next
        }
        switch reply {
        case .success(let reply): return HTTPResponse(status: reply.status, body: Data(reply.body.utf8))
        case .failure(let error): throw error
        case nil: throw .failed("no stubbed reply for \(request)")
        }
    }
}

/// Behaves like the DSM 7 NAS measured on 2026-11-27 (curl, same session, `SYNO.Core.System` info): a session call
/// whose token is a `SynoToken` field of the POST body gets error 119; with the `X-SYNO-TOKEN` header it succeeds.
/// Discovery and login need no token.
final class CSRFCheckingTransport: HTTPTransport {
    let stub = StubTransport()
    var trustState: TLSTrustState? { stub.trustState }

    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        let response = try await stub.send(request)
        let needsToken = request["_sid"] != nil
        guard needsToken, request["SynoToken"] != nil || request.header("X-SYNO-TOKEN") != "TOKEN0" else {
            return response
        }
        return HTTPResponse(status: 200, body: Data(DSMFixtures.error(119).utf8))
    }
}

/// Recorded on a DSM 7.1 NAS (`SYNO.API.Info` needs no login and carries no identifying data).
enum DSMFixtures {
    static let info = """
        {"data":{"SYNO.API.Auth":{"maxVersion":7,"minVersion":1,"path":"entry.cgi"},\
        "SYNO.Core.System":{"maxVersion":3,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},\
        "SYNO.Core.System.Utilization":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},\
        "SYNO.Storage.CGI.Storage":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},\
        "SYNO.Docker.Container":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"}},\
        "success":true}
        """
    /// The shape of the guide's example (p. 17), with made-up values.
    static func login(sid: String, token: String = "TOKEN0") -> String {
        #"{"data":{"did":"DEVICE0","is_portal_port":false,"sid":"\#(sid)","synotoken":"\#(token)"},"success":true}"#
    }
    static func error(_ code: Int) -> String { #"{"error":{"code":\#(code)},"success":false}"# }
    static let system = #"{"data":{"model":"DS-TEST","temperature":41},"success":true}"#
    static let ok = #"{"success":true}"#
}

@Suite(.timeLimit(.minutes(1))) struct DSMClientTests {
    private let base = URL(string: "https://nas.example.test:5001")!

    private func client(_ transport: any HTTPTransport, password: Result<String, DSMError> = .success("pw&=+ %"))
        -> DSMClient
    {
        DSMClient(baseURL: base, account: "<user>", password: { password }, transport: transport)
    }

    private struct System: Decodable, Equatable {
        var model: String
        var temperature: Int
    }

    @Test func discoveryResolvesPathsAndVersionsFromAPIInfo() async throws {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        let apis = try await client(transport).apis(["SYNO.API.Auth", "SYNO.Core.System"])
        #expect(apis["SYNO.API.Auth"] == DSMAPI(path: "entry.cgi", minVersion: 1, maxVersion: 7, requestFormat: nil))
        #expect(
            apis["SYNO.Core.System"] == DSMAPI(path: "entry.cgi", minVersion: 1, maxVersion: 3, requestFormat: "JSON"))
        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://nas.example.test:5001/webapi/entry.cgi")
        #expect(request["query"] == "SYNO.API.Auth,SYNO.Core.System")
        #expect(request["version"] == "1")
    }

    @Test func loginStoresTheSidAndUsesItForTheNextCall() async throws {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        transport.on("SYNO.Core.System info", json: DSMFixtures.system)
        let client = client(transport)
        let system = try await client.call("SYNO.Core.System", version: 1, method: "info", as: System.self)
        #expect(system == System(model: "DS-TEST", temperature: 41))
        let login = try #require(transport.requests("SYNO.API.Auth login").first)
        #expect(login["version"] == "6")  // recommended by the guide, within the NAS's 1...7
        #expect(login["account"] == "<user>")
        #expect(login["passwd"] == "pw&=+ %")
        #expect(login["session"] == "soho-monitor")
        #expect(login["format"] == "sid")
        // A DS416play took 3.8 s to answer a v6 login (29 s for v7): longer than the 10 s of other calls, so login
        // waits longer; the other calls keep the transport's default.
        #expect(login.timeout == DSMClient.loginTimeout)
        #expect(DSMClient.loginTimeout >= 30)
        #expect(transport.requests("SYNO.API.Info query").allSatisfy { $0.timeout == nil })
        let call = try #require(transport.requests("SYNO.Core.System info").first)
        #expect(call.timeout == nil)
        #expect(call["_sid"] == "SID-1")
        // The token goes in the header DSM reads, not in the body (where DSM 7 answers 119).
        #expect(call.header("X-SYNO-TOKEN") == "TOKEN0")
        #expect(call["SynoToken"] == nil)
        // Credentials and the sid travel in the POST body, never in the URL.
        #expect(transport.requests.allSatisfy { $0.url.query == nil && $0.method == "POST" })
        // One discovery and one login for the session, whatever the number of calls.
        _ = try await client.call("SYNO.Core.System", version: 1, method: "info", as: System.self)
        #expect(transport.requests("SYNO.API.Auth login").count == 1)
        #expect(transport.requests("SYNO.API.Info query").count == 1)
    }

    @Test func aSessionCallSucceedsAgainstANASThatReadsTheTokenOnlyFromTheHeader() async throws {
        let transport = CSRFCheckingTransport()
        transport.stub.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.stub.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        transport.stub.on("SYNO.Core.System info", json: DSMFixtures.system)
        let system = try await client(transport).call("SYNO.Core.System", version: 1, method: "info", as: System.self)
        #expect(system == System(model: "DS-TEST", temperature: 41))
        #expect(transport.stub.requests("SYNO.API.Auth login").count == 1)
        #expect(transport.stub.requests("SYNO.Core.System info").count == 1)
    }

    @Test func withoutATokenFromTheLoginNoTokenIsSent() async throws {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: #"{"data":{"sid":"SID-1"},"success":true}"#)
        transport.on("SYNO.Core.System info", json: DSMFixtures.system)
        transport.on("SYNO.API.Auth logout", json: DSMFixtures.ok)
        let client = client(transport)
        _ = try await client.call("SYNO.Core.System", version: 1, method: "info")
        await client.logout()
        for request in transport.requests {
            #expect(request.headers.isEmpty, "\(request)")
            #expect(request["SynoToken"] == nil, "\(request)")
        }
        #expect(transport.requests("SYNO.Core.System info").first?["_sid"] == "SID-1")
    }

    @Test(arguments: [105, 106, 107, 119])
    func aLostSessionGetsExactlyOneReloginAndOneRetry(code: Int) async throws {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"), DSMFixtures.login(sid: "SID-2"))
        transport.on("SYNO.Core.System info", json: DSMFixtures.error(code), DSMFixtures.system)
        let system = try await client(transport).call("SYNO.Core.System", version: 1, method: "info", as: System.self)
        #expect(system.model == "DS-TEST")
        #expect(transport.requests("SYNO.API.Auth login").count == 2)
        #expect(transport.requests("SYNO.Core.System info").map { $0["_sid"] } == ["SID-1", "SID-2"])
    }

    @Test func aSessionLostAgainAfterTheReloginIsAnErrorWithoutALoop() async {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"), DSMFixtures.login(sid: "SID-2"))
        transport.on("SYNO.Core.System info", json: DSMFixtures.error(106))
        await #expect(throws: DSMError.sessionLost(code: 106)) {
            try await client(transport).call("SYNO.Core.System", version: 1, method: "info")
        }
        #expect(transport.requests("SYNO.API.Auth login").count == 2)
        #expect(transport.requests("SYNO.Core.System info").count == 2)
    }

    @Test func noPermissionAfterAFreshLoginIsPermissionDenied() async {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        transport.on("SYNO.Core.System info", json: DSMFixtures.error(105))
        await #expect(throws: DSMError.permissionDenied) {
            try await client(transport).call("SYNO.Core.System", version: 1, method: "info")
        }
    }

    @Test func wrongCredentialsFailOnceWithoutARetryLoop() async {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.error(400))
        let client = client(transport)
        await #expect(throws: DSMError.invalidCredentials) {
            try await client.call("SYNO.Core.System", version: 1, method: "info")
        }
        #expect(transport.requests("SYNO.API.Auth login").count == 1)
        #expect(transport.requests("SYNO.Core.System info").isEmpty)
        #expect(DSMError.invalidCredentials.isAuthFailure)
    }

    @Test(arguments: [
        (400, DSMError.invalidCredentials), (401, .accountDisabled), (402, .signInNotAllowed), (403, .otpRequired),
        (404, .otpRequired), (406, .otpRequired), (407, .ipBlocked), (408, .passwordExpired),
        (409, .passwordExpired), (410, .passwordExpired), (499, .api(name: "SYNO.API.Auth", code: 499)),
    ])
    func loginCodesFollowTheGuide(code: Int, error: DSMError) {
        #expect(DSMError.login(code: code) == error)
    }

    @Test func aLoginRefusedFor402SaysTheAccountMayNotSignInThroughTheAPI() {
        let message = DSMError.signInNotAllowed.message
        #expect(message.contains("not allowed to sign in through the API"))
        #expect(message.contains("permissions"))
        #expect(DSMError.signInNotAllowed.isAuthFailure)
    }

    @Test func noPasswordMeansNeedsSetupAndNoRequestAtAll() async {
        let transport = StubTransport()
        await #expect(throws: DSMError.needsSetup) {
            try await client(transport, password: .failure(.needsSetup)).login()
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func networkAndTLSFailuresKeepTheirMeaning() async {
        let unreachable = StubTransport()
        unreachable.on("SYNO.API.Info query", .failure(.unreachable("timed out")))
        await #expect(throws: DSMError.unreachable("timed out")) { try await client(unreachable).login() }
        let refused = StubTransport()
        let presented = CertificateFingerprint(sha256Of: Data("x".utf8))
        refused.on("SYNO.API.Info query", .failure(.tls(.certificateMismatch(presented: presented))))
        await #expect(throws: DSMError.tls(.certificateMismatch(presented: presented))) {
            try await client(refused).login()
        }
    }

    @Test func malformedAnswersAreInvalidResponses() async {
        for body in ["<html>", #"{"success":false}"#, #"{"data":{}}"#] {
            let transport = StubTransport()
            transport.on("SYNO.API.Info query", json: body)
            await #expect(throws: DSMError.self) { try await client(transport).login() }
            do {
                try await client(transport).login()
            } catch {
                guard case .invalidResponse = error else {
                    Issue.record("\(body): expected .invalidResponse, got \(error)")
                    continue
                }
            }
        }
        let http = StubTransport()
        http.on("SYNO.API.Info query", .success(StubTransport.Reply(status: 502, body: "")))
        await #expect(throws: DSMError.invalidResponse("HTTP 502")) { try await client(http).login() }
    }

    @Test func aMissingAPIOrVersionIsReported() async {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        let client = client(transport)
        await #expect(throws: DSMError.apiUnavailable("SYNO.Core.System v4")) {
            try await client.call("SYNO.Core.System", version: 4, method: "info")
        }
        transport.on("SYNO.API.Info query", json: #"{"data":{},"success":true}"#)
        await #expect(throws: DSMError.apiUnavailable("SYNO.Foo")) {
            try await client.call("SYNO.Foo", version: 1, method: "get")
        }
    }

    @Test func jsonFormatParametersAreJSONEncoded() async throws {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        transport.on("SYNO.Docker.Container list", json: DSMFixtures.ok)
        _ = try await client(transport).call(
            "SYNO.Docker.Container", version: 1, method: "list",
            parameters: ["limit": .int(-1), "type": .string("all")])
        let request = try #require(transport.requests("SYNO.Docker.Container list").first)
        #expect(request["limit"] == "-1")
        #expect(request["type"] == #""all""#)
    }

    @Test func logoutSendsTheSidOnceAndForgetsIt() async throws {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        transport.on("SYNO.API.Auth logout", json: DSMFixtures.ok)
        let client = client(transport)
        try await client.login()
        await client.logout()
        await client.logout()
        #expect(transport.requests("SYNO.API.Auth logout").map { $0["_sid"] } == ["SID-1"])
        let logout = try #require(transport.requests("SYNO.API.Auth logout").first)
        #expect(logout.header("X-SYNO-TOKEN") == "TOKEN0")
        #expect(logout["SynoToken"] == nil)
        #expect(logout.url.query == nil)
    }

    @Test func concurrentCallsShareOneLogin() async throws {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        transport.on("SYNO.Core.System info", json: DSMFixtures.system)
        let client = client(transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await client.call("SYNO.Core.System", version: 1, method: "info") }
            }
            try await group.waitForAll()
        }
        #expect(transport.requests("SYNO.API.Auth login").count == 1)
    }

    @Test func requestDescriptionsNeverShowTheBody() {
        let request = HTTPRequest(
            url: base.appending(path: "webapi/entry.cgi"),
            fields: [("api", "SYNO.API.Auth"), ("passwd", "hunter2"), ("_sid", "SID-1")])
        #expect(!String(describing: request).contains("hunter2"))
        #expect(!String(describing: request).contains("SID-1"))
        #expect(!String(reflecting: request).contains("hunter2"))
        var withHeader = request
        withHeader.headers = [("X-SYNO-TOKEN", "TOKEN-SECRET")]
        #expect(!String(describing: withHeader).contains("TOKEN-SECRET"))
        #expect(!String(reflecting: withHeader).contains("TOKEN-SECRET"))
    }

    @Test func headerLookupIgnoresCaseAndSurroundingSpaces() {
        var request = HTTPRequest(url: base, fields: [])
        request.headers = [(" x-syno-token ", "T")]
        #expect(request.header("X-SYNO-TOKEN") == "T")
        #expect(request.header("Cookie") == nil)
    }

    @Test func formEncodingEscapesEverythingButUnreservedCharacters() {
        let body = HTTPRequest.formBody([("passwd", "a&b=c+d %é"), ("api", "SYNO.API.Auth")])
        #expect(String(decoding: body, as: UTF8.self) == "passwd=a%26b%3Dc%2Bd%20%25%C3%A9&api=SYNO.API.Auth")
    }

    @Test func dsmErrorsMapToPollerFailures() {
        #expect(DSMError.needsSetup.remoteFailure == .needsSetup)
        #expect(DSMError.invalidCredentials.remoteFailure == .authFailed("wrong user name or password"))
        #expect(DSMError.keychain(.accessDenied).remoteFailure == .authFailed(SecretStoreError.accessDenied.message))
        #expect(DSMError.unreachable("timed out").remoteFailure == .unreachable("timed out"))
        #expect(DSMError.invalidResponse("HTTP 502").remoteFailure == .failed("unexpected answer from DSM (HTTP 502)"))
    }
}

@Suite(.timeLimit(.minutes(1))) struct SynologyConnectionTests {
    private let config = SynologyConfig(host: "nas.example.test", user: "<user>")

    @Test func aMissingKeychainItemIsNeedsSetupWithoutAnyRequest() async {
        let transport = StubTransport()
        let client = DSMClient(
            baseURL: config.baseURL, account: config.user,
            password: SynologyConnection.password(
                item: "synology", secrets: SecretCache(store: InMemorySecretStore())),
            transport: transport)
        await #expect(throws: DSMError.needsSetup) {
            try await client.call("SYNO.Core.System", version: 1, method: "info")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func aKeychainRefusalIsReportedAsSuch() async {
        let store = InMemorySecretStore()
        store.failure = .accessDenied
        let password = SynologyConnection.password(item: "synology", secrets: SecretCache(store: store))
        #expect(await password() == .failure(.keychain(.accessDenied)))
    }

    @Test func testConnectionLogsInAndOutWithTheTypedPassword() async {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        transport.on("SYNO.API.Auth logout", json: DSMFixtures.ok)
        let result = await SynologyConnection.test(config: config, password: "typed", transport: transport)
        #expect(result == .success(.trusted))
        #expect(transport.requests("SYNO.API.Auth login").first?["passwd"] == "typed")
        #expect(transport.requests("SYNO.API.Auth logout").count == 1)
    }

    @Test func testConnectionReportsTheLoginError() async {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: DSMFixtures.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.error(403))
        let result = await SynologyConnection.test(config: config, password: "typed", transport: transport)
        #expect(result == .failure(.otpRequired))
    }
}

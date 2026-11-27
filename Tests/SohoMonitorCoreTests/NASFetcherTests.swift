import Foundation
import Synchronization
import Testing

@testable import SohoMonitorCore

@Suite(.timeLimit(.minutes(1))) struct NASFetcherTests {
    private static let info = """
        {"data":{"SYNO.API.Auth":{"maxVersion":7,"minVersion":1,"path":"entry.cgi"},\
        "SYNO.Core.System":{"maxVersion":3,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},\
        "SYNO.Core.System.Utilization":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},\
        "SYNO.Storage.CGI.Storage":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},\
        "SYNO.Core.Upgrade.Server":{"maxVersion":3,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},\
        "SYNO.Docker.Container":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"}},\
        "success":true}
        """

    /// A NAS answering every card call with the recorded fixtures.
    private func nas() throws -> StubTransport {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", json: Self.info)
        transport.on("SYNO.API.Auth login", json: DSMFixtures.login(sid: "SID-1"))
        transport.on("SYNO.Core.System.Utilization get", json: try NASFixtures.text(NASFixtures.utilization))
        transport.on("SYNO.Core.System info", json: try NASFixtures.text(NASFixtures.info))
        transport.on("SYNO.Storage.CGI.Storage load_info", json: try NASFixtures.text(NASFixtures.storage))
        transport.on("SYNO.Core.Upgrade.Server check", json: try NASFixtures.text(NASFixtures.upgrade))
        transport.on("SYNO.Docker.Container list", json: try NASFixtures.text(NASFixtures.docker))
        return transport
    }

    private func fetcher(
        _ transport: StubTransport, config: SynologyConfig = SynologyConfig(host: "nas.example.test", user: "<user>"),
        password: Result<String, DSMError> = .success("pw"), clock: TestNow = TestNow()
    ) -> NASFetcher {
        let client = DSMClient(
            baseURL: config.baseURL, account: config.user, password: { password }, transport: transport)
        return NASFetcher(config: config, client: client, trust: { transport.trustState }, now: { clock.now })
    }

    private static let cardCalls = [
        "SYNO.Core.System.Utilization get", "SYNO.Core.System info", "SYNO.Storage.CGI.Storage load_info",
        "SYNO.Core.Upgrade.Server check", "SYNO.Docker.Container list",
    ]

    @Test func oneCycleFillsEverySectionWithOneLogin() async throws {
        let transport = try nas()
        let snapshot = try await fetcher(transport).fetch().get()
        #expect(snapshot.system.value?.cpu == 0.79)
        #expect(snapshot.system.value?.temperature == 54)
        #expect(snapshot.storage.value?.volumes.first?.name == "volume1")
        #expect(snapshot.update.value?.badge == "DSM 7.2.2-72806 Update 11")
        #expect(snapshot.containers.value?.containers.count == 6)
        #expect(snapshot.trust == .trusted)
        #expect(transport.requests("SYNO.API.Auth login").count == 1)
        let calls = transport.requests.map { "\($0["api"] ?? "") \($0["method"] ?? "")" }
        #expect(calls.filter { Self.cardCalls.contains($0) } == Self.cardCalls)
    }

    @Test func dockerListAsksForEveryContainerInOnePage() async throws {
        let transport = try nas()
        _ = await fetcher(transport).fetch()
        let list = try #require(transport.requests("SYNO.Docker.Container list").first)
        #expect(list["limit"] == "-1")
        #expect(list["offset"] == "0")
        #expect(list["type"] == "\"all\"")  // JSON-encoded: the API's requestFormat is JSON
    }

    @Test func theNextCycleReusesTheSession() async throws {
        let transport = try nas()
        let fetcher = fetcher(transport)
        _ = await fetcher.fetch()
        _ = await fetcher.fetch()
        #expect(transport.requests("SYNO.API.Auth login").count == 1)
        #expect(transport.requests("SYNO.Core.System.Utilization get").count == 2)
    }

    @Test func onlyConfiguredSectionsAreCalled() async throws {
        let transport = try nas()
        let config = SynologyConfig(host: "nas.example.test", user: "<user>", sections: [.storage])
        let snapshot = try await fetcher(transport, config: config).fetch().get()
        #expect(snapshot.storage.value != nil)
        #expect(snapshot.system == .off)
        #expect(snapshot.update == .off)
        #expect(snapshot.containers == .off)
        let calls = transport.requests.map { "\($0["api"] ?? "") \($0["method"] ?? "")" }
        #expect(calls.filter { Self.cardCalls.contains($0) } == ["SYNO.Storage.CGI.Storage load_info"])
    }

    @Test func updateIsCheckedAgainOnlyAfterItsInterval() async throws {
        let transport = try nas()
        let clock = TestNow()
        let fetcher = fetcher(transport, clock: clock)
        _ = await fetcher.fetch()
        clock.advance(by: 5 * 3600)
        let second = try await fetcher.fetch().get()
        #expect(second.update.value?.available == true)  // the cached answer
        #expect(transport.requests("SYNO.Core.Upgrade.Server check").count == 1)
        clock.advance(by: 3600)
        _ = await fetcher.fetch()
        #expect(transport.requests("SYNO.Core.Upgrade.Server check").count == 2)
    }

    @Test func aFailedSectionShowsItsErrorWhileTheOthersRender() async throws {
        let transport = try nas()
        transport.replace("SYNO.Storage.CGI.Storage load_info", json: DSMFixtures.error(105), DSMFixtures.error(105))
        transport.replace("SYNO.Core.Upgrade.Server check", json: DSMFixtures.error(117))
        let fetcher = fetcher(transport)
        let snapshot = try await fetcher.fetch().get()
        #expect(snapshot.storage == .unavailable("no permission for SYNO.Storage.CGI.Storage"))
        #expect(snapshot.update == .unavailable("SYNO.Core.Upgrade.Server failed (DSM error 117)"))
        #expect(snapshot.system.value != nil)
        #expect(snapshot.containers.value != nil)
        // A refused API is not asked again in this session: each refusal costs a fresh login.
        let logins = transport.requests("SYNO.API.Auth login").count
        let second = try await fetcher.fetch().get()
        #expect(second.storage == .unavailable("no permission for SYNO.Storage.CGI.Storage"))
        #expect(transport.requests("SYNO.Storage.CGI.Storage load_info").count == 2)
        #expect(transport.requests("SYNO.API.Auth login").count == logins)
    }

    @Test func aFailedUpdateCheckIsRetriedNextCycle() async throws {
        let transport = try nas()
        transport.replace(
            "SYNO.Core.Upgrade.Server check", json: DSMFixtures.error(117), try NASFixtures.text(NASFixtures.upgrade))
        let fetcher = fetcher(transport)
        _ = await fetcher.fetch()
        let second = try await fetcher.fetch().get()
        #expect(second.update.value?.available == true)
    }

    @Test func dockerNotInstalledHidesTheSection() async throws {
        let transport = try nas()
        transport.replace(
            "SYNO.API.Info query",
            json: Self.info.replacingOccurrences(
                of:
                    #","SYNO.Docker.Container":{"maxVersion":1,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"}"#,
                with: ""))
        let snapshot = try await fetcher(transport).fetch().get()
        #expect(snapshot.containers == .absent)
        #expect(transport.requests("SYNO.Docker.Container list").isEmpty)
    }

    @Test func otherMissingAPIsSayNotAvailable() async throws {
        let transport = try nas()
        transport.replace(
            "SYNO.API.Info query",
            json: Self.info.replacingOccurrences(
                of:
                    #""SYNO.Core.Upgrade.Server":{"maxVersion":3,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"},"#,
                with: ""))
        let snapshot = try await fetcher(transport).fetch().get()
        #expect(snapshot.update == .unavailable("SYNO.Core.Upgrade.Server is not available on this NAS"))
    }

    @Test func systemInfoFailureKeepsTheLoad() async throws {
        let transport = try nas()
        transport.replace("SYNO.Core.System info", json: DSMFixtures.error(105), DSMFixtures.error(105))
        let system = try #require(try await fetcher(transport).fetch().get().system.value)
        #expect(system.cpu == 0.79)
        #expect(system.temperature == nil)
    }

    @Test func noPasswordIsNeedsSetupAndSendsNothing() async throws {
        let transport = try nas()
        let result = await fetcher(transport, password: .failure(.needsSetup)).fetch()
        #expect(result == .failure(.needsSetup))
        #expect(transport.requests.isEmpty)
    }

    @Test func wrongPasswordStopsTheCycle() async throws {
        let transport = try nas()
        transport.replace("SYNO.API.Auth login", json: DSMFixtures.error(400))
        let result = await fetcher(transport).fetch()
        #expect(result == .failure(.authFailed(DSMError.invalidCredentials.message)))
        #expect(transport.requests("SYNO.API.Auth login").count == 1)
        #expect(transport.requests.allSatisfy { !Self.cardCalls.contains("\($0["api"] ?? "") \($0["method"] ?? "")") })
    }

    @Test func unreachableBeforeAnyAnswerIsTheWholeCard() async throws {
        let transport = StubTransport()
        transport.on("SYNO.API.Info query", .failure(.unreachable("timed out")))
        let result = await fetcher(transport).fetch()
        #expect(result == .failure(.unreachable("timed out")))
        #expect(transport.requests.count == 1)  // no call per section after the first failure
    }

    @Test func aTimeoutAfterAnAnswerOnlyCostsItsSection() async throws {
        let transport = try nas()
        transport.replace("SYNO.Docker.Container list", .failure(.unreachable("timed out")))
        let snapshot = try await fetcher(transport).fetch().get()
        #expect(snapshot.containers == .unavailable("unreachable (timed out)"))
        #expect(snapshot.storage.value != nil)
    }

    @Test func aChangedPinIsReportedWithTheNewFingerprint() async throws {
        let transport = StubTransport()
        let presented = CertificateFingerprint(sha256Of: Data("rotated".utf8))
        transport.on("SYNO.API.Info query", .failure(.tls(.certificateMismatch(presented: presented))))
        let fetcher = fetcher(transport)
        let result = await fetcher.fetch()
        #expect(result == .failure(.failed(TLSFailure.certificateMismatch(presented: presented).message)))
        #expect(await fetcher.lastTLSFailure?.presented == presented)
        #expect(TLSFailure.certificateMismatch(presented: presented).message.contains(presented.description))
    }
}

/// A settable "now" for the update interval.
final class TestNow: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(by seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

extension NASSection {
    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

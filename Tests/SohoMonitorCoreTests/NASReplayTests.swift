import Foundation
import Testing

@testable import SohoMonitorCore

@Suite(.timeLimit(.minutes(1))) struct NASReplayTests {
    private func directory() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/Synology", withExtension: nil))
    }

    @Test func aWholeCycleRunsFromRecordedFilesWithoutNetwork() async throws {
        let transport = NASReplayTransport(directory: try directory())
        let config = SynologyConfig(host: "nas.example.test", user: "demo")
        let client = DSMClient(
            baseURL: config.baseURL, account: config.user, password: { .success("demo") }, transport: transport)
        let snapshot = try await NASFetcher(config: config, client: client, trust: { transport.trustState }).fetch()
            .get()
        guard case .value(let storage) = snapshot.storage, case .value(let list) = snapshot.containers,
            case .value(let system) = snapshot.system, case .value(let update) = snapshot.update
        else {
            Issue.record("a section is missing: \(snapshot)")
            return
        }
        #expect(storage.volumes.first?.name == "volume1")
        #expect(list.total == 6)
        #expect(system.temperature == 54)
        #expect(update.available)
        await client.logout()
    }

    @Test func aMissingFileIsAnAPIErrorNotACrash() async throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "nas-replay-\(UUID().uuidString)")
        let transport = NASReplayTransport(directory: empty)
        let request = HTTPRequest(
            url: try #require(URL(string: "https://nas.example.test:5001/webapi/entry.cgi")),
            fields: [("api", "SYNO.Storage.CGI.Storage"), ("method", "load_info")])
        let response = try await transport.send(request)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"error":{"code":102},"success":false}"#)
    }
}

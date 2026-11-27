import Foundation

/// Answers the NAS card's DSM calls from recorded response files, never from the network: for screenshots and demos
/// of the card (`SOHO_MONITOR_NAS_DEMO`, README), with the anonymised fixtures of the tests. Discovery lists every card
/// API, login and logout always succeed; a call without its file gets DSM's "API does not exist" (102).
public final class NASReplayTransport: HTTPTransport {
    /// `"<api> <method>"` → file name (without `.json`) in the directory, as the fixture recorder named them.
    public static let files = [
        "SYNO.Core.System info": "core-system-info-v1",
        "SYNO.Core.System.Utilization get": "core-system-utilization-get-v1",
        "SYNO.Storage.CGI.Storage load_info": "storage-load-info-v1",
        "SYNO.Core.Upgrade.Server check": "core-upgrade-server-check-v1",
        "SYNO.Docker.Container list": "docker-container-list-v1-paged",
    ]

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var trustState: TLSTrustState? { .trusted }

    public func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        let key = "\(request["api"] ?? "") \(request["method"] ?? "")"
        let body: String
        switch key {
        case "SYNO.API.Info query":
            let apis = (["SYNO.API.Auth"] + Self.files.keys.map { String($0.prefix { $0 != " " }) })
                .map { #""\#($0)":{"maxVersion":7,"minVersion":1,"path":"entry.cgi","requestFormat":"JSON"}"# }
            body = #"{"data":{\#(Set(apis).sorted().joined(separator: ","))},"success":true}"#
        case "SYNO.API.Auth login":
            body = #"{"data":{"sid":"demo-session","synotoken":"demo-token"},"success":true}"#
        case "SYNO.API.Auth logout":
            body = #"{"success":true}"#
        default:
            guard let name = Self.files[key],
                let data = try? Data(contentsOf: directory.appending(path: "\(name).json"))
            else { return HTTPResponse(status: 200, body: Data(#"{"error":{"code":102},"success":false}"#.utf8)) }
            return HTTPResponse(status: 200, body: data)
        }
        return HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

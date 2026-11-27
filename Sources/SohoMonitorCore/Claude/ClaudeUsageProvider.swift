import Foundation

/// Reads the plan usage of one profile. A protocol so that the app's model can be driven by a stub.
public protocol ClaudeUsageFetching: Sendable {
    func fetch(_ account: ClaudeAccount) async -> Result<ClaudeUsage, ClaudeUsageProblem>
}

/// Where `node` and `claude` are. An app started from the Finder has a minimal `PATH`, so it is read once from the
/// user's login shell, then the usual install places are added (ADR 0001).
public struct ClaudeTools: Sendable, Equatable {
    public static let pathMarker = "__SOHO_MONITOR_PATH__="
    static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "/usr/bin", "/bin"]

    public var node: String?
    public var claude: String?
    /// Also the helper's `PATH`.
    public var searchPath: [String]

    public init(node: String?, claude: String?, searchPath: [String]) {
        self.node = node
        self.claude = claude
        self.searchPath = searchPath
    }

    /// The first executable `node` and `claude` along `searchPath`.
    public init(searchPath: [String], isExecutable: (String) -> Bool) {
        func find(_ name: String) -> String? {
            searchPath.lazy.map { ($0 as NSString).appendingPathComponent(name) }.first(where: isExecutable)
        }
        self.init(node: find("node"), claude: find("claude"), searchPath: searchPath)
    }

    /// `-i` too: many people set their `PATH` (nvm, Homebrew) in `.zshrc`, which a login shell alone does not read.
    /// The marker line separates the value from what the startup files print.
    public static func loginShellCommand(shell: String) -> (String, [String]) {
        (shell, ["-ilc", "printf '\\n\(pathMarker)%s\\n' \"$PATH\""])
    }

    public static func path(fromLoginShellOutput data: Data) -> [String] {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard let line = lines.last(where: { $0.hasPrefix(pathMarker) }) else { return [] }
        return unique(line.dropFirst(pathMarker.count).split(separator: ":").map(String.init))
    }

    public static func searchPath(loginPath: [String], home: String) -> [String] {
        unique(loginPath + fallbackDirectories.map { PathDisplay.expandingTilde($0, home: home) })
    }

    /// Reads the login shell's `PATH` (10 s at most: a shell waiting for input must not block the card) and looks
    /// the tools up.
    public static func resolve(runner: any EnvironmentCommandRunning, environment: [String: String], home: String)
        async -> ClaudeTools
    {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let (executable, arguments) = loginShellCommand(shell: shell)
        let output = try? await withTimeout(.seconds(10)) {
            try await runner.run(executable, arguments, environment: environment)
        }
        let loginPath = output.map { path(fromLoginShellOutput: $0.stdout) } ?? []
        return ClaudeTools(
            searchPath: searchPath(loginPath: loginPath, home: home),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Runs the bundled helper (`claude-usage/usage.mjs`) with `node` for one profile, at background quality of service
/// (`ProcessRunner`), with a timeout.
public struct ClaudeUsageProvider: ClaudeUsageFetching {
    /// The only variables of the app's environment passed on: an allowlist, because others (API keys, OAuth tokens,
    /// `ANTHROPIC_BASE_URL`, Bedrock or Vertex switches, custom headers) would make Claude Code use something else
    /// than the profile's own login. Proxy and CA settings stay so that the call works behind a proxy.
    static let passedVariables: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "HTTPS_PROXY", "https_proxy",
        "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy", "NODE_EXTRA_CA_CERTS",
    ]

    let runner: any EnvironmentCommandRunning
    let tools: ClaudeTools
    let helperScript: String?
    let baseEnvironment: [String: String]
    let home: String
    let directoryExists: @Sendable (String) -> Bool
    let timeout: Duration
    let now: @Sendable () -> Date

    /// `helperScript`: nil when the app runs outside its bundle (`swift run`).
    public init(
        runner: any EnvironmentCommandRunning, tools: ClaudeTools, helperScript: String?,
        baseEnvironment: [String: String], home: String,
        directoryExists: @escaping @Sendable (String) -> Bool = { ConfigParser.isDirectory($0) },
        timeout: Duration = .seconds(30), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.tools = tools
        self.helperScript = helperScript
        self.baseEnvironment = baseEnvironment
        self.home = home
        self.directoryExists = directoryExists
        self.timeout = timeout
        self.now = now
    }

    public func fetch(_ account: ClaudeAccount) async -> Result<ClaudeUsage, ClaudeUsageProblem> {
        guard let node = tools.node else { return .failure(.nodeMissing) }
        guard let claude = tools.claude else { return .failure(.claudeMissing) }
        guard let helperScript else { return .failure(.helperMissing) }
        guard directoryExists(account.configDir) else {
            return .failure(.configDirMissing(PathDisplay.abbreviated(account.configDir, home: home)))
        }
        var environment = baseEnvironment.filter { Self.passedVariables.contains($0.key) }
        environment["PATH"] = tools.searchPath.joined(separator: ":")
        environment["CLAUDE_CONFIG_DIR"] = account.configDir
        environment["SOHO_CLAUDE_EXECUTABLE"] = claude
        let (runner, helperEnvironment) = (runner, environment)
        let output: CommandOutput?
        do {
            output = try await withTimeout(timeout) {
                try await runner.run(node, [helperScript], environment: helperEnvironment)
            }
        } catch {
            return .failure(.helperFailed(String(describing: error)))
        }
        guard let output else { return .failure(.timedOut(seconds: Int(timeout.components.seconds))) }
        return ClaudeUsageParser.parse(output, fetchedAt: now())
    }
}

/// The operation's result, or nil when `limit` passes first; the operation is then cancelled (`ProcessRunner`
/// terminates its process).
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws
    -> T?
{
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

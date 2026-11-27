import Foundation
import Synchronization
import Testing

@testable import SohoMonitorCore

/// Records every call and plays back one canned output (or waits until cancelled).
private final class FakeHelperRunner: EnvironmentCommandRunning, Sendable {
    struct Call: Sendable, Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    private let calls = Mutex<[Call]>([])
    private let output: CommandOutput?

    /// `output: nil` never answers: the call ends only when its task is cancelled.
    init(output: CommandOutput?) {
        self.output = output
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws
        -> CommandOutput
    {
        calls.withLock { $0.append(Call(executable: executable, arguments: arguments, environment: environment)) }
        guard let output else {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        return output
    }
}

@Suite(.timeLimit(.minutes(1))) struct ClaudeUsageProviderTests {
    private let account = ClaudeAccount(label: "Work", configDir: "/Users/me/.claude-work")
    private let tools = ClaudeTools(
        node: "/opt/homebrew/bin/node", claude: "/Users/me/.local/bin/claude",
        searchPath: ["/opt/homebrew/bin", "/Users/me/.local/bin", "/usr/bin"])

    private func provider(
        _ runner: FakeHelperRunner, tools: ClaudeTools? = nil,
        helper: String? = "/App/Resources/claude-usage/usage.mjs",
        existing: Bool = true, timeout: Duration = .seconds(30)
    ) -> ClaudeUsageProvider {
        ClaudeUsageProvider(
            runner: runner, tools: tools ?? self.tools, helperScript: helper,
            baseEnvironment: [
                "HOME": "/Users/me", "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "placeholder",
                "ANTHROPIC_AUTH_TOKEN": "placeholder", "CLAUDE_CODE_OAUTH_TOKEN": "placeholder",
                "CLAUDE_CONFIG_DIR": "/Users/me/.claude", "LANG": "en_US.UTF-8",
                "ANTHROPIC_BASE_URL": "https://example.invalid", "CLAUDE_CODE_USE_BEDROCK": "1",
                "HTTPS_PROXY": "http://proxy.invalid:3128",
            ],
            home: "/Users/me", directoryExists: { _ in existing }, timeout: timeout,
            now: { ClaudeFixtures.fetchedAt })
    }

    @Test func runsTheHelperWithTheProfileAndTheInstalledClaude() async throws {
        let runner = FakeHelperRunner(output: ClaudeFixtures.output(ClaudeFixtures.max))
        let usage = try await provider(runner).fetch(account).get()
        #expect(usage.weekly?.percent == 82.5)
        #expect(usage.fetchedAt == ClaudeFixtures.fetchedAt)
        let call = try #require(runner.recorded.first)
        #expect(call.executable == "/opt/homebrew/bin/node")
        #expect(call.arguments == ["/App/Resources/claude-usage/usage.mjs"])
        #expect(call.environment["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-work")
        #expect(call.environment["SOHO_CLAUDE_EXECUTABLE"] == "/Users/me/.local/bin/claude")
        #expect(call.environment["PATH"] == "/opt/homebrew/bin:/Users/me/.local/bin:/usr/bin")
        #expect(call.environment["HOME"] == "/Users/me")
        #expect(call.environment["LANG"] == "en_US.UTF-8")
    }

    /// Claude Code would use a key, a token or another endpoint from the environment instead of the profile login.
    @Test func credentialsFromTheEnvironmentAreNotPassedOn() async throws {
        let runner = FakeHelperRunner(output: ClaudeFixtures.output(ClaudeFixtures.max))
        _ = await provider(runner).fetch(account)
        let environment = try #require(runner.recorded.first).environment
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(environment["CLAUDE_CODE_USE_BEDROCK"] == nil)
        #expect(environment["HTTPS_PROXY"] == "http://proxy.invalid:3128")  // proxies still work
    }

    @Test func missingPiecesAreReportedWithoutRunningAnything() async {
        let runner = FakeHelperRunner(output: ClaudeFixtures.output(ClaudeFixtures.max))
        let noNode = ClaudeTools(node: nil, claude: tools.claude, searchPath: tools.searchPath)
        let noClaude = ClaudeTools(node: tools.node, claude: nil, searchPath: tools.searchPath)
        #expect(await provider(runner, tools: noNode).fetch(account) == .failure(.nodeMissing))
        #expect(await provider(runner, tools: noClaude).fetch(account) == .failure(.claudeMissing))
        #expect(await provider(runner, helper: nil).fetch(account) == .failure(.helperMissing))
        // Claude Code creates a config directory that does not exist: never run it on a typo.
        #expect(
            await provider(runner, existing: false).fetch(account) == .failure(.configDirMissing("~/.claude-work")))
        #expect(runner.recorded.isEmpty)
    }

    @Test func aHelperThatDoesNotAnswerTimesOut() async {
        let runner = FakeHelperRunner(output: nil)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await provider(runner, timeout: .milliseconds(200)).fetch(account)
        #expect(result == .failure(.timedOut(seconds: 0)))
        #expect(clock.now - start < .seconds(10))
    }

    @Test func aRunnerErrorIsAHelperFailure() async {
        struct Failing: EnvironmentCommandRunning {
            func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws
                -> CommandOutput
            {
                throw ProbeError.commandFailed("cannot run node: denied")
            }
        }
        let provider = ClaudeUsageProvider(
            runner: Failing(), tools: tools, helperScript: "/x/usage.mjs", baseEnvironment: [:], home: "/Users/me",
            directoryExists: { _ in true }, timeout: .seconds(5), now: { ClaudeFixtures.fetchedAt })
        #expect(await provider.fetch(account) == .failure(.helperFailed("cannot run node: denied")))
    }

    /// The real runner passes the environment it is given, and only it.
    @Test func processRunnerPassesTheEnvironment() async throws {
        let output = try await ProcessRunner().run(
            "/bin/sh", ["-c", "printf '%s|%s' \"$SOHO_TEST\" \"${HOME:-unset}\""], environment: ["SOHO_TEST": "42"])
        #expect(String(decoding: output.stdout, as: UTF8.self) == "42|unset")
    }
}

@Suite struct ClaudeToolsTests {
    @Test func readsThePathAfterTheMarkerIgnoringWhatStartupFilesPrint() {
        let output = Data("Welcome!\nPATH=/fake\n\(ClaudeTools.pathMarker)/a/bin:/b/bin::/a/bin\nbye\n".utf8)
        #expect(ClaudeTools.path(fromLoginShellOutput: output) == ["/a/bin", "/b/bin"])
        #expect(ClaudeTools.path(fromLoginShellOutput: Data("no marker".utf8)) == [])
    }

    @Test func searchPathAddsTheUsualPlacesOnce() {
        #expect(
            ClaudeTools.searchPath(loginPath: ["/usr/bin", "/opt/homebrew/bin"], home: "/Users/me") == [
                "/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Users/me/.local/bin", "/bin",
            ])
    }

    @Test func findsTheFirstExecutableInOrder() {
        let executables: Set<String> = ["/b/node", "/c/node", "/c/claude"]
        let tools = ClaudeTools(searchPath: ["/a", "/b", "/c"], isExecutable: { executables.contains($0) })
        #expect(tools.node == "/b/node")
        #expect(tools.claude == "/c/claude")
        let none = ClaudeTools(searchPath: ["/a"], isExecutable: { _ in false })
        #expect(none.node == nil && none.claude == nil)
    }

    @Test func loginShellCommandPrintsTheMarker() {
        let (shell, arguments) = ClaudeTools.loginShellCommand(shell: "/bin/zsh")
        #expect(shell == "/bin/zsh")
        #expect(arguments.first == "-ilc")
        #expect(arguments.last?.contains(ClaudeTools.pathMarker) == true)
    }

    /// Runs a real shell: the marker line survives the round trip.
    @Test func loginShellRoundTrip() async throws {
        let (shell, arguments) = ClaudeTools.loginShellCommand(shell: "/bin/sh")
        let output = try await ProcessRunner().run(shell, ["-c", arguments[1]], environment: ["PATH": "/x:/y"])
        #expect(ClaudeTools.path(fromLoginShellOutput: output.stdout) == ["/x", "/y"])
    }
}

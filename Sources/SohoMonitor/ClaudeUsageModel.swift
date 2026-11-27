import Foundation
import Observation
import SohoMonitorCore

/// State of the Claude card: one `ClaudeAccountState` per configured profile. Refreshes only while the desktop panel
/// is visible, every `refresh_minutes`, one profile at a time; showing the panel refreshes what is due at once. The
/// decisions (what is due, when to wake, what to forget) are `ClaudeRefreshPlan`'s, tested in the core.
@MainActor @Observable
final class ClaudeUsageModel {
    private(set) var config = ClaudeConfig.disabled
    private(set) var states: [ClaudeAccount: ClaudeAccountState] = [:]
    private(set) var isRefreshing = false

    @ObservationIgnored private var visible = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Incremented at each restart: a cancelled loop that finishes late must not touch the current one's state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tools: ClaudeTools?

    var isEnabled: Bool { config.isEnabled }

    func state(of account: ClaudeAccount) -> ClaudeAccountState {
        states[account] ?? ClaudeAccountState()
    }

    /// A new configuration: removed profiles are forgotten, new ones are due at once.
    func apply(_ config: ClaudeConfig) {
        guard config != self.config else { return }
        self.config = config
        states = ClaudeRefreshPlan.retained(states, for: config)
        restartLoop()
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        restartLoop()
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = nil
        generation += 1
        isRefreshing = false
        guard visible, config.isEnabled else { return }
        let generation = generation
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDueAccounts(generation: generation)
                let wait = ClaudeRefreshPlan.secondsUntilNextDue(config: self.config, states: self.states, now: .now)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func refreshDueAccounts(generation: Int) async {
        let due = ClaudeRefreshPlan.due(config: config, states: states, now: .now)
        guard !due.isEmpty else { return }
        isRefreshing = true
        defer { if generation == self.generation { isRefreshing = false } }
        let provider = await makeProvider()
        for account in due {
            guard !Task.isCancelled else { return }
            let result = await provider.fetch(account)
            // Cancelled (panel hidden, configuration changed): the helper was stopped, its error is not news.
            guard !Task.isCancelled, generation == self.generation else { return }
            // The configuration may have changed while the helper ran: keep only a current profile's result.
            guard config.accounts.contains(account) else { continue }
            var state = state(of: account)
            state.record(result, at: .now)
            states[account] = state
        }
    }

    /// Looks `node` and `claude` up once; again at the next refresh while one of them is missing (installed later).
    private func makeProvider() async -> ClaudeUsageProvider {
        let environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        if tools?.node == nil || tools?.claude == nil {
            tools = await Task.detached(priority: .background) {
                await ClaudeTools.resolve(runner: ProcessRunner(), environment: environment, home: home)
            }.value
        }
        let script = Bundle.main.url(forResource: "usage", withExtension: "mjs", subdirectory: "claude-usage")
        return ClaudeUsageProvider(
            runner: ProcessRunner(), tools: tools ?? ClaudeTools(node: nil, claude: nil, searchPath: []),
            helperScript: script?.path, baseEnvironment: environment, home: home)
    }
}

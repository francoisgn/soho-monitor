import Foundation
import Observation
import SohoMonitorCore

/// State of the Claude card: one `ClaudeAccountState` per configured profile. Refreshes only while the desktop panel
/// is visible, every `refresh_minutes`, one profile at a time; showing the panel refreshes what is due at once.
@MainActor @Observable
final class ClaudeUsageModel {
    private(set) var config = ClaudeConfig.disabled
    private(set) var states: [ClaudeAccount: ClaudeAccountState] = [:]
    private(set) var isRefreshing = false

    @ObservationIgnored private var visible = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var tools: ClaudeTools?

    var isEnabled: Bool { config.isEnabled }

    func state(of account: ClaudeAccount) -> ClaudeAccountState {
        states[account] ?? ClaudeAccountState()
    }

    /// A new configuration: removed profiles are forgotten, new ones are due at once.
    func apply(_ config: ClaudeConfig) {
        guard config != self.config else { return }
        self.config = config
        states = states.filter { config.accounts.contains($0.key) }
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
        guard visible, config.isEnabled else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDueAccounts()
                let wait = self.secondsUntilNextDue()
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func refreshDueAccounts() async {
        let due = config.accounts.filter { state(of: $0).isDue(now: .now, refreshMinutes: config.refreshMinutes) }
        guard !due.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let provider = await makeProvider()
        for account in due {
            guard !Task.isCancelled else { return }
            let result = await provider.fetch(account)
            // Cancelled (panel hidden, configuration changed): the helper was stopped, its error is not news.
            guard !Task.isCancelled else { return }
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
        if tools == nil || tools?.node == nil || tools?.claude == nil {
            tools = await Task.detached(priority: .background) {
                await ClaudeTools.resolve(runner: ProcessRunner(), environment: environment, home: home)
            }.value
        }
        let script = Bundle.main.url(forResource: "usage", withExtension: "mjs", subdirectory: "claude-usage")
        return ClaudeUsageProvider(
            runner: ProcessRunner(), tools: tools ?? ClaudeTools(node: nil, claude: nil, searchPath: []),
            helperScript: script?.path, baseEnvironment: environment, home: home)
    }

    private func secondsUntilNextDue() -> Double {
        let interval = Double(config.refreshMinutes * 60)
        let next =
            config.accounts.map { account -> Double in
                guard let last = state(of: account).lastAttempt else { return 0 }
                return interval - Date.now.timeIntervalSince(last)
            }.min() ?? interval
        return max(1, next)
    }
}

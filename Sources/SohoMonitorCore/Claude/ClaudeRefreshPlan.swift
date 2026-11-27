import Foundation

/// The refresh decisions of the Claude card, pure so that they are tested; the app's loop only follows them.
public enum ClaudeRefreshPlan {
    /// Profiles to refresh now, in configuration order.
    public static func due(config: ClaudeConfig, states: [ClaudeAccount: ClaudeAccountState], now: Date)
        -> [ClaudeAccount]
    {
        config.accounts.filter {
            (states[$0] ?? ClaudeAccountState()).isDue(now: now, refreshMinutes: config.refreshMinutes)
        }
    }

    /// Seconds until the next profile is due (at least 1, so a loop never spins).
    public static func secondsUntilNextDue(
        config: ClaudeConfig, states: [ClaudeAccount: ClaudeAccountState], now: Date
    ) -> Double {
        let interval = Double(config.refreshMinutes * 60)
        let waits = config.accounts.map { account -> Double in
            guard let last = states[account]?.lastAttempt else { return 0 }
            return interval - now.timeIntervalSince(last)
        }
        return max(1, waits.min() ?? interval)
    }

    /// States of the profiles still configured (a removed profile is forgotten, a re-added one starts afresh).
    public static func retained(_ states: [ClaudeAccount: ClaudeAccountState], for config: ClaudeConfig)
        -> [ClaudeAccount: ClaudeAccountState]
    {
        states.filter { config.accounts.contains($0.key) }
    }
}

/// What a configuration reload must redo.
public enum ConfigChange {
    /// Rescheduling the disk scan cancels a scan in progress: only a change of the disk section (or the first valid
    /// configuration) does it.
    public static func reschedulesDisk(from previous: AppConfig?, to current: AppConfig) -> Bool {
        previous?.disk != current.disk
    }
}

import Foundation
import Yams

/// `claude:` section: the Claude Code profiles whose plan usage the card shows (ADR 0001).
public struct ClaudeConfig: Sendable, Equatable {
    public static let defaultRefreshMinutes = 5
    public static let disabled = ClaudeConfig(accounts: [])

    /// Minutes between two refreshes while the panel is visible.
    public var refreshMinutes: Int
    /// In the card's order.
    public var accounts: [ClaudeAccount]

    public init(refreshMinutes: Int = defaultRefreshMinutes, accounts: [ClaudeAccount]) {
        self.refreshMinutes = refreshMinutes
        self.accounts = accounts
    }

    /// No account: the card is not shown and nothing runs.
    public var isEnabled: Bool { !accounts.isEmpty }
}

/// One Claude Code profile: a label for the card and its `CLAUDE_CONFIG_DIR` (absolute, `~` expanded).
public struct ClaudeAccount: Sendable, Equatable, Hashable {
    public var label: String
    public var configDir: String

    public init(label: String, configDir: String) {
        self.label = label
        self.configDir = configDir
    }
}

extension Reader {
    mutating func readClaude(_ node: Node) -> ClaudeConfig {
        var config = ClaudeConfig.disabled
        guard case .mapping(let mapping) = node else {
            error(node, "claude", "expected a mapping (refresh_minutes, accounts)")
            return config
        }
        let keys = entries(mapping, at: "claude", known: ["refresh_minutes", "accounts"])
        if let refresh = keys["refresh_minutes"] {
            if let minutes = wholeNumber(refresh), (1...1440).contains(minutes) {
                config.refreshMinutes = minutes
            } else {
                error(refresh, "claude.refresh_minutes", "must be a whole number of minutes between 1 and 1440")
            }
        }
        if let accounts = keys["accounts"] {
            config.accounts = readClaudeAccounts(accounts)
        }
        return config
    }

    private mutating func readClaudeAccounts(_ node: Node) -> [ClaudeAccount] {
        guard case .sequence(let sequence) = node else {
            error(node, "claude.accounts", "expected a list of accounts")
            return []
        }
        var accounts: [ClaudeAccount] = []
        var labels: [String: Int] = [:]
        var directories: [String: Int] = [:]
        for (index, item) in sequence.enumerated() {
            let keyPath = "claude.accounts[\(index)]"
            guard case .mapping(let mapping) = item else {
                error(item, keyPath, "expected a mapping (label, config_dir)")
                continue
            }
            let keys = entries(mapping, at: keyPath, known: ["label", "config_dir"])
            let label = nonEmptyString(keys["label"])
            if label == nil { error(keys["label"] ?? item, "\(keyPath).label", "required (a non-empty string)") }
            let written = nonEmptyString(keys["config_dir"])
            if written == nil {
                error(
                    keys["config_dir"] ?? item, "\(keyPath).config_dir", "required (the profile's CLAUDE_CONFIG_DIR)")
            }
            guard let label, let written else { continue }
            if labels[label] != nil {
                error(item, keyPath, "duplicate label \"\(label)\"")
                continue
            }
            let directory = PathDisplay.expandingTilde(written, home: home)
            if let first = directories[directory] {
                error(keys["config_dir"], "\(keyPath).config_dir", "same directory as claude.accounts[\(first)]")
                continue
            }
            labels[label] = index
            directories[directory] = index
            let homePrefix = home.hasSuffix("/") ? home : home + "/"
            if !directory.hasPrefix(homePrefix) {
                warning(keys["config_dir"], "\(keyPath).config_dir", "outside the home folder")
            }
            if !directoryExists(directory) {
                warning(
                    keys["config_dir"], "\(keyPath).config_dir",
                    "directory not found: \(PathDisplay.abbreviated(directory, home: home))")
            }
            accounts.append(ClaudeAccount(label: label, configDir: directory))
        }
        return accounts
    }

    private mutating func warning(_ node: Node?, _ keyPath: String, _ message: String) {
        warnings.append(ConfigIssue(line: node?.mark?.line, keyPath: keyPath, message: message))
    }
}

import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct ClaudeConfigTests {
    private static let disk = """
        disk:
          categories:
            - group: Apps
              paths: [/Applications]

        """

    private func parse(_ claude: String, existing: Set<String>? = nil) throws(ConfigError) -> ConfigLoadResult {
        try ConfigParser.parse(
            Self.disk + claude, home: "/Users/me",
            directoryExists: { existing?.contains($0) ?? true })
    }

    @Test func parsesAccountsInOrderWithExpandedPathsAndDefaults() throws {
        let result = try parse(
            """
            claude:
              accounts:
                - label: Work
                  config_dir: ~/.claude-work
                - label: Personal
                  config_dir: /Users/me/.claude-personal/
            """)
        #expect(result.warnings.isEmpty)
        #expect(result.config.claude.refreshMinutes == 5)
        #expect(
            result.config.claude.accounts == [
                ClaudeAccount(label: "Work", configDir: "/Users/me/.claude-work"),
                ClaudeAccount(label: "Personal", configDir: "/Users/me/.claude-personal"),
            ])
        #expect(result.config.claude.isEnabled)
    }

    @Test func refreshMinutesIsRead() throws {
        let result = try parse(
            """
            claude:
              refresh_minutes: 15
              accounts:
                - {label: Work, config_dir: ~/.claude-work}
            """)
        #expect(result.config.claude.refreshMinutes == 15)
    }

    @Test func noSectionOrAnEmptyListDisablesTheModule() throws {
        #expect(try parse("").config.claude.isEnabled == false)
        let empty = try parse("claude:\n  accounts: []\n")
        #expect(empty.config.claude.isEnabled == false)
        #expect(empty.warnings.isEmpty)
    }

    @Test func reportsEveryClaudeErrorWithItsLine() {
        let yaml = """
            claude:
              refresh_minutes: 0
              accounts:
                - label: Work
                  config_dir: ~/.claude-work
                - label: Work
                  config_dir: ~/.claude-other
                - config_dir: ~/.claude-x
                - label: Nodir
                - just a string
            """
        #expect {
            try parse(yaml)
        } throws: { error in
            let issues = (error as? ConfigError)?.issues.map(\.description) ?? []
            return issues == [
                "line 6: claude.refresh_minutes: must be a whole number of minutes between 1 and 1440",
                "line 10: claude.accounts[1]: duplicate label \"Work\"",
                "line 12: claude.accounts[2].label: required (a non-empty string)",
                "line 13: claude.accounts[3].config_dir: required (the profile's CLAUDE_CONFIG_DIR)",
                "line 14: claude.accounts[4]: expected a mapping (label, config_dir)",
            ]
        }
    }

    @Test func structuralErrors() {
        for (yaml, expected) in [
            ("claude: 3\n", "line 5: claude: expected a mapping (refresh_minutes, accounts)"),
            ("claude:\n  accounts: {}\n", "line 6: claude.accounts: expected a list of accounts"),
        ] {
            #expect {
                try parse(yaml)
            } throws: { error in
                (error as? ConfigError)?.issues.map(\.description) == [expected]
            }
        }
    }

    @Test func missingDirectoryOutsideHomeAndUnknownKeysAreWarnings() throws {
        let result = try parse(
            """
            claude:
              colour: orange
              accounts:
                - label: Gone
                  config_dir: ~/.claude-gone
                - label: Shared
                  config_dir: /opt/claude
                  plan: max
            """, existing: ["/opt/claude"])
        #expect(
            result.warnings.map(\.description) == [
                "line 6: claude.colour: unknown key, ignored",
                "line 9: claude.accounts[0].config_dir: directory not found: ~/.claude-gone",
                "line 11: claude.accounts[1].config_dir: outside the home folder",
                "line 12: claude.accounts[1].plan: unknown key, ignored",
            ])
        // Both accounts stay: a profile created later starts working at the next refresh.
        #expect(result.config.claude.accounts.count == 2)
    }

    @Test func duplicateConfigDirIsAnError() {
        let yaml = """
            claude:
              accounts:
                - {label: A, config_dir: ~/.claude-a}
                - {label: B, config_dir: ~/.claude-a/}
            """
        #expect {
            try parse(yaml)
        } throws: { error in
            (error as? ConfigError)?.issues.map(\.description) == [
                "line 8: claude.accounts[1].config_dir: same directory as claude.accounts[0]"
            ]
        }
    }
}

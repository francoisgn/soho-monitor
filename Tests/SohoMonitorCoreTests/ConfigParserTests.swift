import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct ConfigParserTests {
    @Test func parsesCategoriesInOrderWithDefaults() throws {
        let yaml = """
            disk:
              categories:
                - group: Dev
                  label: DerivedData
                  paths:
                    - ~/Library/Developer/Xcode/DerivedData
                - group: Dev
                  label: iOS runtimes
                  source: ios-runtimes
                - group: Documents
                  paths: [~/Documents, "~/Library/Mobile Documents"]
            """
        let result = try ConfigParser.parse(yaml)
        let disk = result.config.disk
        #expect(result.warnings.isEmpty)
        #expect(disk.scanIntervalMinutes == 30)
        #expect(disk.freeWarningPercent == 20)
        #expect(disk.freeCriticalPercent == 10)
        #expect(
            disk.categories == [
                DiskCategory(
                    group: "Dev", label: "DerivedData", source: .paths(["~/Library/Developer/Xcode/DerivedData"])),
                DiskCategory(group: "Dev", label: "iOS runtimes", source: .iosRuntimes),
                // A category without a label takes its group's name, like "[Documents]" in the widget's file.
                DiskCategory(
                    group: "Documents", label: "Documents",
                    source: .paths(["~/Documents", "~/Library/Mobile Documents"])),
            ])
    }

    @Test func parsesIntervalAndThresholds() throws {
        let yaml = """
            disk:
              scan_interval_minutes: 45
              free_space:
                warning_below_percent: 25
                critical_below_percent: 7.5
              categories:
                - group: Apps
                  paths: [/Applications]
            """
        let disk = try ConfigParser.parse(yaml).config.disk
        #expect(disk.scanIntervalMinutes == 45)
        #expect(disk.freeWarningPercent == 25)
        #expect(disk.freeCriticalPercent == 7.5)
    }

    @Test func bareTildeIsAPathNotNull() throws {
        let yaml = """
            disk:
              categories:
                - group: Home
                  paths: [~]
            """
        let disk = try ConfigParser.parse(yaml).config.disk
        #expect(disk.categories.first?.source == .paths(["~"]))
    }

    @Test func unknownKeysAreWarningsNotErrors() throws {
        let yaml = """
            disk:
              colour: blue
              categories:
                - group: Apps
                  paths: [/Applications]
                  icon: app
            network: {}
            """
        let result = try ConfigParser.parse(yaml)
        #expect(
            result.warnings.map(\.description) == [
                "line 2: disk.colour: unknown key, ignored",
                "line 6: disk.categories[0].icon: unknown key, ignored",
                "line 7: network: unknown key, ignored",
            ])
        #expect(result.config.disk.categories.count == 1)
    }

    @Test func reportsEveryValidationErrorWithItsLocation() {
        let yaml = """
            disk:
              scan_interval_minutes: 0
              free_space:
                warning_below_percent: 5
                critical_below_percent: 10
              categories:
                - label: No group
                  paths: [/tmp]
                - group: Empty
                  paths: []
                - group: Both
                  source: ios-runtimes
                  paths: [/x]
                - group: Bad source
                  source: android
                - group: macOS
                  paths: [/System]
                - group: Dup
                  label: Same
                  paths: [/a]
                - group: Dup
                  label: Same
                  paths: [/b]
                - group: Blank path
                  paths: [""]
            """
        #expect {
            try ConfigParser.parse(yaml)
        } throws: { error in
            guard let error = error as? ConfigError else { return false }
            return error.issues.map(\.description) == [
                "line 2: disk.scan_interval_minutes: must be a whole number of minutes between 1 and 1440",
                "line 5: disk.free_space: critical_below_percent (10) must be lower than warning_below_percent (5)",
                "line 7: disk.categories[0].group: required (a non-empty string)",
                "line 10: disk.categories[1].paths: must list at least one path",
                "line 11: disk.categories[2]: use either paths or source, not both",
                "line 15: disk.categories[3].source: unknown source \"android\" (known: ios-runtimes)",
                "line 16: disk.categories[4].group: \"macOS\" is reserved (computed by the app)",
                "line 21: disk.categories[6]: duplicate category Dup/Same",
                "line 25: disk.categories[7].paths[0]: must be a non-empty string",
            ]
        }
    }

    @Test(arguments: [
        ("", "line 1: config: the file is empty"),
        ("- a\n- b\n", "line 1: config: expected a mapping at the top level"),
        ("other: 1\n", "line 1: disk: required section is missing"),
        ("disk:\n  categories: 3\n", "line 2: disk.categories: expected a list of categories"),
        ("disk:\n  categories: []\n", "line 2: disk.categories: must list at least one category"),
    ])
    func rejectsStructuralErrors(yaml: String, expected: String) {
        #expect {
            try ConfigParser.parse(yaml)
        } throws: { error in
            (error as? ConfigError)?.issues.map(\.description) == [expected]
        }
    }

    @Test func syntaxErrorCarriesTheParserLocation() {
        #expect {
            try ConfigParser.parse("disk:\n  categories:\n    - group: [unclosed\n")
        } throws: { error in
            guard let issue = (error as? ConfigError)?.issues.first else { return false }
            return issue.description.hasPrefix("line ") && issue.description.contains("YAML syntax")
        }
    }

    /// The documented example must stay valid: it is the operator's starting point.
    @Test func exampleConfigIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/example.yaml")
        // The example's Claude profiles are placeholders: their directories are taken as existing.
        let result = try ConfigParser.parse(
            String(contentsOf: url, encoding: .utf8), home: "/Users/me", directoryExists: { _ in true })
        #expect(result.warnings.isEmpty)
        #expect(result.config.disk.categories.count >= 10)
        #expect(result.config.disk.categories.contains { $0.source == .iosRuntimes })
        #expect(result.config.claude.accounts.map(\.label) == ["Work", "Personal"])
        #expect(
            result.config.synology
                == SynologyConfig(host: "nas.example.lan", port: 5001, user: "<user>", keychainItem: "synology"))
    }
}

@Suite struct ConfigStateTests {
    private func config(_ group: String) -> AppConfig {
        AppConfig(disk: DiskConfig(categories: [DiskCategory(group: group, label: group, source: .paths(["/x"]))]))
    }

    @Test func keepsTheLastValidConfigWhenAReloadFails() {
        var state = ConfigState()
        state.apply(.success(ConfigLoadResult(config: config("A"), warnings: [])))
        #expect(state.config == config("A"))
        #expect(state.errors.isEmpty)

        let issue = ConfigIssue(line: 3, keyPath: "disk", message: "broken")
        state.apply(.failure(ConfigError(issues: [issue])))
        #expect(state.config == config("A"))
        #expect(state.errors == [issue])
        #expect(state.hasValidConfig)

        state.apply(.success(ConfigLoadResult(config: config("B"), warnings: [])))
        #expect(state.config == config("B"))
        #expect(state.errors.isEmpty)
    }

    @Test func startsWithoutValidConfig() {
        var state = ConfigState()
        #expect(!state.hasValidConfig)
        state.apply(.failure(ConfigError(issues: [ConfigIssue(line: nil, keyPath: "config", message: "missing")])))
        #expect(!state.hasValidConfig)
        #expect(state.config.disk.categories.isEmpty)
    }

    @Test func missingFileIsAnActionableError() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/config.yaml")
        let result = ConfigFile.load(url)
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.issues.first?.description.contains("not found") == true)
        #expect(error.issues.first?.description.contains("config/example.yaml") == true)
    }

    @Test func defaultPathHonoursOverrideThenXDG() {
        #expect(
            ConfigFile.defaultURL(environment: ["SOHO_MONITOR_CONFIG": "/etc/x.yaml"], home: "/Users/me").path
                == "/etc/x.yaml")
        #expect(
            ConfigFile.defaultURL(environment: ["XDG_CONFIG_HOME": "/Users/me/.xdg"], home: "/Users/me").path
                == "/Users/me/.xdg/soho-monitor/config.yaml")
        #expect(
            ConfigFile.defaultURL(environment: [:], home: "/Users/me").path
                == "/Users/me/.config/soho-monitor/config.yaml")
    }
}

@Suite struct FileFingerprintTests {
    @Test func changesOnEditOrReplaceAndFollowsSymbolicLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soho-fp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("real.yaml")
        let link = dir.appendingPathComponent("config.yaml")
        #expect(FileFingerprint(url: link) == nil)

        try Data("a: 1\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let first = FileFingerprint(url: link)
        #expect(first != nil)
        #expect(FileFingerprint(url: link) == first)

        // An editor that saves atomically replaces the file: new inode behind the same link.
        try Data("a: 2\n".utf8).write(to: target, options: .atomic)
        let second = FileFingerprint(url: link)
        #expect(second != first)

        // An in-place edit that keeps the size changes the modification time.
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data("a: 3\n".utf8))
        try handle.close()
        var times = [timespec(tv_sec: 1_000, tv_nsec: 0), timespec(tv_sec: 2_000, tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, target.path, &times, 0)
        #expect(FileFingerprint(url: link) != second)
    }
}

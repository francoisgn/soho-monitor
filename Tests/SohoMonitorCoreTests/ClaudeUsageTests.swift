import Foundation
import Testing

@testable import SohoMonitorCore

/// Helper output as printed by `Helpers/claude-usage/usage.mjs` (figures from the spike, no identifier).
enum ClaudeFixtures {
    static let fetchedAt = Date(timeIntervalSince1970: 1_795_000_000)

    static let max = """
        {"subscription_type":"max","rate_limits_available":true,"limits":[
         {"kind":"session","group":"session","percent":15,"severity":"normal",
          "resets_at":"2026-11-27T12:00:00.174192+00:00","scope_model":null,"is_active":false},
         {"kind":"weekly_all","group":"weekly","percent":82.5,"severity":"warning",
          "resets_at":"2026-11-30T00:00:00+00:00","scope_model":null,"is_active":true},
         {"kind":"weekly_scoped","group":"weekly","percent":6,"severity":"critical",
          "resets_at":"2026-11-30T00:00:00.174364+00:00","scope_model":"Fable","is_active":false}]}
        """

    static func output(_ json: String, stderr: String = "", status: Int32 = 0) -> CommandOutput {
        CommandOutput(stdout: Data(json.utf8), stderr: Data(stderr.utf8), status: status)
    }

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }
}

@Suite struct ClaudeUsageParserTests {
    private func parse(_ output: CommandOutput) -> Result<ClaudeUsage, ClaudeUsageProblem> {
        ClaudeUsageParser.parse(output, fetchedAt: ClaudeFixtures.fetchedAt)
    }

    @Test func classifiesRowsOnKind() throws {
        let usage = try parse(ClaudeFixtures.output(ClaudeFixtures.max)).get()
        #expect(usage.plan == "max")
        #expect(usage.fetchedAt == ClaudeFixtures.fetchedAt)
        #expect(
            usage.session
                == UsageLimit(
                    percent: 15, severity: .normal, resetsAt: ClaudeFixtures.date("2026-11-27T12:00:00.174Z")))
        #expect(
            usage.weekly
                == UsageLimit(percent: 82.5, severity: .warning, resetsAt: ClaudeFixtures.date("2026-11-30T00:00:00Z")))
        #expect(usage.models.map(\.model) == ["Fable"])
        #expect(usage.models.first?.limit.percent == 6)
        #expect(usage.models.first?.limit.severity == .critical)
    }

    /// Fractional seconds are microseconds in the server's timestamps; the parsed date keeps them to the millisecond.
    @Test func readsMicrosecondTimestamps() throws {
        let usage = try parse(ClaudeFixtures.output(ClaudeFixtures.max)).get()
        let reset = try #require(usage.session?.resetsAt)
        #expect(abs(reset.timeIntervalSince(ClaudeFixtures.date("2026-11-27T12:00:00Z")) - 0.174192) < 0.001)
    }

    @Test func ignoresUnknownKindsFieldsAndBrokenRows() throws {
        let json = """
            {"subscription_type":"team","rate_limits_available":true,"new_top_level":{"x":1},"limits":[
             {"kind":"daily_magic","group":"daily","percent":50,"severity":"normal","resets_at":null},
             {"kind":"session","percent":"lots","severity":"normal"},
             {"kind":"session","percent":40,"severity":"sparkly","resets_at":null,"extra":[1,2]},
             {"kind":"weekly_scoped","percent":3,"severity":"normal","resets_at":"not a date"},
             "just a string"]}
            """
        let usage = try parse(ClaudeFixtures.output(json)).get()
        // A row whose percent is not a number is skipped; the next `session` row is used.
        #expect(usage.session == UsageLimit(percent: 40, severity: .normal, resetsAt: nil))
        #expect(usage.weekly == nil)
        // A scoped row without a model is not shown: the card labels each donut with its model.
        #expect(usage.models.isEmpty)
    }

    @Test func notLoggedInAndUnavailableLimitsAreDistinct() {
        #expect(
            parse(ClaudeFixtures.output(#"{"subscription_type":null,"rate_limits_available":false,"limits":null}"#))
                == .failure(.notLoggedIn))
        #expect(
            parse(ClaudeFixtures.output(#"{"subscription_type":"team","rate_limits_available":false,"limits":null}"#))
                == .failure(.rateLimitsUnavailable(plan: "team")))
        #expect(
            parse(ClaudeFixtures.output(#"{"subscription_type":"max","rate_limits_available":true,"limits":null}"#))
                == .failure(.rateLimitsUnavailable(plan: "max")))
    }

    @Test func helperErrorsAreReportedWithTheirMessage() {
        #expect(
            parse(ClaudeFixtures.output(#"{"error":"Claude Code native binary not found"}"#, status: 1))
                == .failure(.helperFailed("Claude Code native binary not found")))
        #expect(
            parse(
                ClaudeFixtures.output(
                    "", stderr: "Error [ERR_MODULE_NOT_FOUND]: Cannot find package\n  at x", status: 1))
                == .failure(.helperFailed("Error [ERR_MODULE_NOT_FOUND]: Cannot find package")))
        #expect(parse(ClaudeFixtures.output("", status: 0)) == .failure(.helperFailed("no output from the helper")))
        #expect(
            parse(ClaudeFixtures.output("<html>", status: 0)) == .failure(.helperFailed("unreadable helper output")))
    }

    @Test func severityFromTheServerUnknownIsNormal() {
        #expect(UsageSeverity(server: "warning") == .warning)
        #expect(UsageSeverity(server: "critical") == .critical)
        #expect(UsageSeverity(server: "normal") == .normal)
        #expect(UsageSeverity(server: "sparkly") == .normal)
        #expect(UsageSeverity(server: nil) == .normal)
    }

    @Test func fractionIsClampedForTheBar() {
        #expect(UsageLimit(percent: 82.5, severity: .normal, resetsAt: nil).fraction == 0.825)
        #expect(UsageLimit(percent: 140, severity: .normal, resetsAt: nil).fraction == 1)
        #expect(UsageLimit(percent: -3, severity: .normal, resetsAt: nil).fraction == 0)
    }
}

@Suite struct ClaudeAccountStateTests {
    private let t0 = ClaudeFixtures.fetchedAt

    private func usage(_ percent: Double, at date: Date) -> ClaudeUsage {
        ClaudeUsage(
            plan: "max", session: UsageLimit(percent: percent, severity: .normal, resetsAt: nil), weekly: nil,
            models: [], fetchedAt: date)
    }

    @Test func aFailureKeepsTheLastGoodValueAndRecordsTheProblem() {
        var state = ClaudeAccountState()
        #expect(state.usage == nil && state.problem == nil)
        state.record(.success(usage(10, at: t0)), at: t0)
        #expect(state.usage?.session?.percent == 10)
        #expect(state.problem == nil)
        state.record(.failure(.helperFailed("boom")), at: t0 + 300)
        #expect(state.usage?.session?.percent == 10)
        #expect(state.problem == .helperFailed("boom"))
        #expect(state.lastAttempt == t0 + 300)
        state.record(.success(usage(20, at: t0 + 600)), at: t0 + 600)
        #expect(state.usage?.session?.percent == 20)
        #expect(state.problem == nil)
    }

    @Test func staleAfterTwoRefreshIntervals() {
        var state = ClaudeAccountState()
        #expect(state.isStale(now: t0, refreshMinutes: 5) == false)  // nothing to dim yet
        state.record(.success(usage(10, at: t0)), at: t0)
        #expect(state.isStale(now: t0 + 599, refreshMinutes: 5) == false)
        #expect(state.isStale(now: t0 + 601, refreshMinutes: 5) == true)
    }

    @Test func dueWhenNeverTriedOrAfterOneInterval() {
        var state = ClaudeAccountState()
        #expect(state.isDue(now: t0, refreshMinutes: 5))
        state.record(.failure(.timedOut(seconds: 30)), at: t0)
        #expect(state.isDue(now: t0 + 298, refreshMinutes: 5) == false)
        #expect(state.isDue(now: t0 + 299.5, refreshMinutes: 5))  // a timer firing a little early still refreshes
    }
}

@Suite struct ResetFormatTests {
    private let now = ClaudeFixtures.fetchedAt

    static let cases: [(Double, String)] = [
        (7800, "in 2h 10m"),
        (2700, "in 45m"),
        (30, "in 1m"),
        (7200, "in 2h"),
        (223_259, "in 2d 14h"),  // 62 h and 59 s
        (259_200, "in 3d"),
        (0, "reset"),
        (-600, "reset"),
    ]

    @Test(arguments: cases)
    func relative(offset: Double, expected: String) {
        #expect(ResetFormat.relative(now + offset, now: now) == expected)
    }

    @Test func unknownReset() {
        #expect(ResetFormat.relative(nil, now: now) == "no reset time")
    }

    @Test func percentFigure() {
        #expect(ResetFormat.percent(82.5) == "83%")
        #expect(ResetFormat.percent(0) == "0%")
        #expect(ResetFormat.percent(100.4) == "100%")
    }
}

@Suite struct ClaudeUsageProblemTests {
    @Test func messagesAreActionable() {
        #expect(ClaudeUsageProblem.nodeMissing.message.contains("Node.js"))
        #expect(ClaudeUsageProblem.claudeMissing.message.contains("Claude Code"))
        #expect(ClaudeUsageProblem.notLoggedIn.message.contains("/login"))
        #expect(ClaudeUsageProblem.helperMissing.message.contains("bundle-app.sh"))
        #expect(ClaudeUsageProblem.configDirMissing("~/.claude-x").message.contains("~/.claude-x"))
        #expect(ClaudeUsageProblem.timedOut(seconds: 30).message == "no answer within 30 s")
        #expect(ClaudeUsageProblem.rateLimitsUnavailable(plan: "team").message.contains("team"))
    }
}

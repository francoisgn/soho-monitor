import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct ClaudeRefreshPlanTests {
    private let t0 = ClaudeFixtures.fetchedAt
    private let work = ClaudeAccount(label: "Work", configDir: "/Users/me/.claude-work")
    private let personal = ClaudeAccount(label: "Personal", configDir: "/Users/me/.claude-personal")

    private func tried(at date: Date) -> ClaudeAccountState {
        var state = ClaudeAccountState()
        state.record(.failure(.timedOut(seconds: 30)), at: date)
        return state
    }

    @Test func onlyDueAccountsInConfigOrder() {
        let config = ClaudeConfig(accounts: [work, personal])
        #expect(ClaudeRefreshPlan.due(config: config, states: [:], now: t0) == [work, personal])
        let states = [work: tried(at: t0), personal: tried(at: t0 - 400)]
        #expect(ClaudeRefreshPlan.due(config: config, states: states, now: t0) == [personal])
    }

    @Test func nextWakeIsTheEarliestDueAccountAtLeastOneSecond() {
        let config = ClaudeConfig(accounts: [work, personal])
        let states = [work: tried(at: t0 - 100), personal: tried(at: t0 - 250)]
        #expect(ClaudeRefreshPlan.secondsUntilNextDue(config: config, states: states, now: t0) == 50)
        #expect(ClaudeRefreshPlan.secondsUntilNextDue(config: config, states: [:], now: t0) == 1)
        #expect(ClaudeRefreshPlan.secondsUntilNextDue(config: .disabled, states: [:], now: t0) == 300)
    }

    @Test func removedAccountsAreForgotten() {
        let states = [work: tried(at: t0), personal: tried(at: t0)]
        let kept = ClaudeRefreshPlan.retained(states, for: ClaudeConfig(accounts: [personal]))
        #expect(Array(kept.keys) == [personal])
    }

    /// Rescheduling the disk scan cancels a scan in progress: only a change of the disk section may do it.
    @Test func onlyADiskChangeReschedulesTheScan() {
        let disk = DiskConfig(categories: [DiskCategory(group: "A", label: "A", source: .paths(["/x"]))])
        let before = AppConfig(disk: disk)
        var claudeOnly = before
        claudeOnly.claude = ClaudeConfig(accounts: [work])
        var diskEdit = before
        diskEdit.disk.scanIntervalMinutes = 45
        #expect(ConfigChange.reschedulesDisk(from: before, to: claudeOnly) == false)
        #expect(ConfigChange.reschedulesDisk(from: before, to: diskEdit))
        #expect(ConfigChange.reschedulesDisk(from: nil, to: before))
    }

    @Test func availableButNoKnownRowIsAProblem() {
        let json = #"{"subscription_type":"max","rate_limits_available":true,"limits":[{"kind":"new","percent":1}]}"#
        #expect(
            ClaudeUsageParser.parse(ClaudeFixtures.output(json), fetchedAt: ClaudeFixtures.fetchedAt)
                == .failure(.noUsageRows))
        #expect(ClaudeUsageProblem.noUsageRows.message.contains("no usage"))
    }
}

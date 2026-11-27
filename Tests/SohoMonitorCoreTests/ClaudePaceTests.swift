import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct ResetFormatTests {
    private let now = ClaudeFixtures.fetchedAt

    static let shortCases: [(Double, String)] = [
        (0, "now"),
        (-600, "now"),
        (30, "1m"),
        (59, "1m"),
        (60, "1m"),
        (61, "2m"),
        (2640, "44m"),
        (2650, "45m"),
        (3599, "1h"),  // 59 min 59 s rounds up to the hour
        (3600, "1h"),
        (3660, "1h01"),
        (7800, "2h10"),
        (11100, "3h05"),
        (86340, "23h59"),
        (86399, "1d"),
        (86400, "1d"),
        (216_000, "2d12h"),
        (223_259, "2d14h"),  // 62 h and 59 s: whole hours
        (259_200, "3d"),
    ]

    @Test(arguments: shortCases)
    func shortText(offset: Double, expected: String) {
        #expect(ResetFormat.short(now + offset, now: now) == expected)
    }

    @Test func shortUnknownReset() {
        #expect(ResetFormat.short(nil, now: now) == "–")
    }

    static let spokenCases: [(Double, String)] = [
        (0, "resets now"),
        (-1, "resets now"),
        (60, "resets in 1 minute"),
        (2640, "resets in 44 minutes"),
        (3600, "resets in 1 hour"),
        (3660, "resets in 1 hour 1 minute"),
        (11100, "resets in 3 hours 5 minutes"),
        (86400, "resets in 1 day"),
        (90000, "resets in 1 day 1 hour"),
        (216_000, "resets in 2 days 12 hours"),
    ]

    @Test(arguments: spokenCases)
    func spokenText(offset: Double, expected: String) {
        #expect(ResetFormat.spoken(now + offset, now: now) == expected)
    }

    @Test func spokenUnknownReset() {
        #expect(ResetFormat.spoken(nil, now: now) == "no reset time")
    }

    @Test func percentFigure() {
        #expect(ResetFormat.percent(82.5) == "83%")
        #expect(ResetFormat.percent(0) == "0%")
        #expect(ResetFormat.percent(100.4) == "100%")
    }
}

@Suite struct UsagePaceTests {
    private let now = ClaudeFixtures.fetchedAt
    private let hour: TimeInterval = 3600

    /// A 5-hour row whose window started `elapsed` seconds ago.
    private func session(_ percent: Double, elapsed: TimeInterval, severity: UsageSeverity = .normal) -> UsageLimit {
        UsageLimit(
            percent: percent, severity: severity, resetsAt: now + UsageWindow.session - elapsed,
            window: UsageWindow.session)
    }

    @Test func windowLengths() {
        #expect(UsageWindow.session == 5 * 3600)
        #expect(UsageWindow.weekly == 7 * 86400)
    }

    @Test func expectedShareIsTheElapsedShareOfTheWindow() {
        #expect(session(0, elapsed: hour).expectedPercent(now: now) == 20)
        #expect(session(0, elapsed: 0).expectedPercent(now: now) == 0)
        #expect(session(0, elapsed: 2.5 * hour).expectedPercent(now: now) == 50)
    }

    @Test func paceMarginIsFivePoints() {
        #expect(UsageLimit.paceMarginPercent == 5)
    }

    @Test func warningOnlyAboveExpectedPlusTheMargin() {
        // 20 %/h on the 5-hour window: one hour in, 20 % is on pace and 25 % is the edge of the margin (#82).
        #expect(session(20, elapsed: hour).reading(now: now) == .normal)
        #expect(session(21, elapsed: hour).reading(now: now) == .normal)
        #expect(session(24.9, elapsed: hour).reading(now: now) == .normal)
        #expect(session(25, elapsed: hour).reading(now: now) == .normal)
        #expect(session(25.1, elapsed: hour).reading(now: now) == .warning)
        #expect(session(30, elapsed: hour).reading(now: now) == .warning)
    }

    @Test func startOfWindowWithSmallUsageStaysGreen() {
        #expect(session(0, elapsed: 0).reading(now: now) == .normal)
        #expect(session(1, elapsed: 0).reading(now: now) == .normal)
        #expect(session(5, elapsed: 0).reading(now: now) == .normal)
        #expect(session(5.1, elapsed: 0).reading(now: now) == .warning)
        // Six minutes in, 2 % is expected: 3 % (the case of #82) stays green, 7 % is the edge.
        #expect(session(3, elapsed: 360).reading(now: now) == .normal)
        #expect(session(7, elapsed: 360).reading(now: now) == .normal)
        #expect(session(7.5, elapsed: 360).reading(now: now) == .warning)
    }

    @Test func ninetyPercentIsCriticalWhateverThePace() {
        // One minute before the reset, 89.9 % is well under pace.
        #expect(session(89.9, elapsed: UsageWindow.session - 60).reading(now: now) == .normal)
        #expect(session(90, elapsed: UsageWindow.session - 60).reading(now: now) == .critical)
        #expect(session(90, elapsed: 0).reading(now: now) == .critical)
        #expect(session(120, elapsed: hour).reading(now: now) == .critical)
    }

    @Test func weeklyWindow() {
        let halfway = now + UsageWindow.weekly / 2
        func weekly(_ percent: Double) -> UsageSeverity {
            UsageLimit(percent: percent, severity: .normal, resetsAt: halfway, window: UsageWindow.weekly)
                .reading(now: now)
        }
        #expect(weekly(50) == .normal)
        #expect(weekly(55) == .normal)
        #expect(weekly(55.5) == .warning)
    }

    @Test func noResetTimeMeansNoPace() {
        let limit = UsageLimit(percent: 80, severity: .normal, resetsAt: nil, window: UsageWindow.session)
        #expect(limit.expectedPercent(now: now) == nil)
        #expect(limit.reading(now: now) == .normal)
        #expect(
            UsageLimit(percent: 90, severity: .normal, resetsAt: nil, window: UsageWindow.session).reading(now: now)
                == .critical)
    }

    @Test func noWindowLengthMeansNoPace() {
        let limit = UsageLimit(percent: 80, severity: .normal, resetsAt: now + 60)
        #expect(limit.expectedPercent(now: now) == nil)
        #expect(limit.reading(now: now) == .normal)
    }

    @Test func clockPastTheResetExpectsTheWholeWindow() {
        let late = session(85, elapsed: UsageWindow.session + 600)
        #expect(late.expectedPercent(now: now) == 100)
        #expect(late.reading(now: now) == .normal)
    }

    @Test func resetFurtherThanOneWindowAwayCountsAsTheStart() {
        // Clock skew: the window has not started by the local clock.
        let early = session(5, elapsed: -600)
        #expect(early.expectedPercent(now: now) == 0)
        #expect(early.reading(now: now) == .normal)
        #expect(session(6, elapsed: -600).reading(now: now) == .warning)
    }

    @Test func serverSeverityIsAFloor() {
        #expect(session(10, elapsed: hour, severity: .warning).reading(now: now) == .warning)
        #expect(session(10, elapsed: hour, severity: .critical).reading(now: now) == .critical)
        #expect(session(30, elapsed: hour, severity: .critical).reading(now: now) == .critical)
    }
}

@Suite struct UsageTextTests {
    private let now = ClaudeFixtures.fetchedAt

    @Test func spokenSaysThePaceInWords() {
        // One hour into the window, 20 % is on pace: 26 % is above, past the 5-point margin.
        let ahead = UsageLimit(percent: 26, severity: .normal, resetsAt: now + 4 * 3600, window: UsageWindow.session)
        #expect(
            UsageText.spoken("5-hour quota", ahead, now: now) == "5-hour quota, 26 %, above pace, resets in 4 hours")
        let onPace = UsageLimit(percent: 5, severity: .normal, resetsAt: now + 2640, window: UsageWindow.session)
        #expect(UsageText.spoken("5-hour quota", onPace, now: now) == "5-hour quota, 5 %, resets in 44 minutes")
        let full = UsageLimit(percent: 95, severity: .normal, resetsAt: nil)
        #expect(
            UsageText.spoken("Fable weekly quota", full, now: now)
                == "Fable weekly quota, 95 %, critical, no reset time")
    }

    @Test func helpGivesTheSteadyPaceShare() {
        let limit = UsageLimit(percent: 30, severity: .normal, resetsAt: now + 4 * 3600, window: UsageWindow.session)
        #expect(UsageText.help("5-hour session", limit, now: now) == "5-hour session: 30% used, 20% at a steady pace")
        let unknown = UsageLimit(percent: 30, severity: .normal, resetsAt: nil)
        #expect(UsageText.help("5-hour session", unknown, now: now) == "5-hour session")
    }
}

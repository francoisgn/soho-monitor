import Foundation

/// The reading of a row, for its colour: the server's `severity`, raised by the client's pace reading
/// (`UsageLimit.reading(now:)`, ADR 0001, amended by #78).
public enum UsageSeverity: String, Sendable, Equatable, Comparable {
    case normal, warning, critical

    /// An unknown or missing value is shown as normal: a new server grade must not turn the card red.
    public init(server: String?) {
        self = server.flatMap(UsageSeverity.init(rawValue:)) ?? .normal
    }

    private var rank: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Window lengths per row kind, **inferred**: a `limits[]` row has no length field, and the server sends `resets_at`
/// only, so a window starts one length before it. Basis: `sdk.d.ts` of `@anthropic-ai/claude-agent-sdk` 0.3.332 (the
/// pinned version): `usage_EXPERIMENTAL_…` returns "plan rate-limit utilization windows (5-hour, 7-day, per-model)",
/// and its legacy `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` fields put the per-model windows at
/// 7 days (ADR 0001). An unknown kind gets no length, hence no pace reading.
public enum UsageWindow {
    /// `session`: 5 hours.
    public static let session: TimeInterval = 5 * 3600
    /// `weekly_all` and `weekly_scoped`: 7 days.
    public static let weekly: TimeInterval = 7 * 86400

    /// The length for a row kind; nil for a kind of unknown length (no pace reading).
    public static func length(ofKind kind: String) -> TimeInterval? {
        switch kind {
        case "session": session
        case "weekly_all", "weekly_scoped": weekly
        default: nil
        }
    }
}

/// One plan limit: share used, the server's severity, when the window resets, how long the window is.
public struct UsageLimit: Sendable, Equatable {
    public var percent: Double
    public var severity: UsageSeverity
    public var resetsAt: Date?
    /// From the row's kind (`UsageWindow`); nil when unknown: no pace reading.
    public var window: TimeInterval?

    public init(percent: Double, severity: UsageSeverity, resetsAt: Date?, window: TimeInterval? = nil) {
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.window = window
    }

    /// Used share at or above which a row is critical, whatever the pace (operator request, #78).
    public static let criticalPercent: Double = 90

    /// Percentage points a row may run ahead of the steady pace before it turns yellow, so a few percent used right
    /// after a reset stays green (operator decision, #82).
    public static let paceMarginPercent: Double = 5

    /// Share of the window elapsed at `now`, 0 to 100: what a steady pace would have used (5 hours: 20 % an hour).
    /// Nil without a reset time or a window length. A clock past the reset reads 100; a reset more than one window
    /// away (clock skew) reads 0.
    public func expectedPercent(now: Date) -> Double? {
        guard let resetsAt, let window, window > 0 else { return nil }
        let elapsed = min(window, max(0, window - resetsAt.timeIntervalSince(now)))
        return elapsed * 100 / window
    }

    /// The colour reading: critical at 90 % or more; warning when the used share is more than the window's
    /// elapsed share plus `paceMarginPercent`; normal otherwise. Never milder than the server's `severity`.
    public func reading(now: Date) -> UsageSeverity {
        let pace: UsageSeverity
        if percent >= Self.criticalPercent {
            pace = .critical
        } else if let expected = expectedPercent(now: now), percent > expected + Self.paceMarginPercent {
            pace = .warning
        } else {
            pace = .normal
        }
        return max(pace, severity)
    }

    /// Share of a bar or a donut, 0 to 1 (the server may report more than 100 % after an overage).
    public var fraction: Double { min(1, max(0, percent / 100)) }
}

/// A weekly limit that applies to one model only (`weekly_scoped`), labelled with the server's display name.
public struct ModelUsageLimit: Sendable, Equatable {
    public var model: String
    public var limit: UsageLimit

    public init(model: String, limit: UsageLimit) {
        self.model = model
        self.limit = limit
    }
}

/// The usage of one profile, classified on the rows' `kind`.
public struct ClaudeUsage: Sendable, Equatable {
    /// `subscription_type` (e.g. `max`, `team`).
    public var plan: String?
    /// `session`: the 5-hour window.
    public var session: UsageLimit?
    /// `weekly_all`: the weekly limit, all models.
    public var weekly: UsageLimit?
    /// `weekly_scoped` rows with a model, in the server's order.
    public var models: [ModelUsageLimit]
    public var fetchedAt: Date

    public init(
        plan: String?, session: UsageLimit?, weekly: UsageLimit?, models: [ModelUsageLimit], fetchedAt: Date
    ) {
        self.plan = plan
        self.session = session
        self.weekly = weekly
        self.models = models
        self.fetchedAt = fetchedAt
    }
}

/// Why a profile has no fresh figures; `message` is shown in the card as is.
public enum ClaudeUsageProblem: Error, Sendable, Equatable {
    case notLoggedIn
    case rateLimitsUnavailable(plan: String)
    /// The path as written for the user (`~` abbreviated).
    case configDirMissing(String)
    case nodeMissing
    case claudeMissing
    case helperMissing
    case timedOut(seconds: Int)
    case helperFailed(String)
    /// Limits reported available, but no row of a known kind.
    case noUsageRows

    public var message: String {
        switch self {
        case .notLoggedIn:
            "not logged in to a Claude plan: run `claude` with this CLAUDE_CONFIG_DIR, then /login"
        case .rateLimitsUnavailable(let plan):
            "plan limits unavailable for this account (plan: \(plan))"
        case .configDirMissing(let path):
            "config directory not found: \(path)"
        case .nodeMissing:
            "Node.js not found in the login shell's PATH (install it, e.g. brew install node)"
        case .claudeMissing:
            "Claude Code not found in the login shell's PATH (install it, then log in)"
        case .helperMissing:
            "usage helper not in the app bundle: build the app with scripts/bundle-app.sh"
        case .timedOut(let seconds):
            "no answer within \(seconds) s"
        case .helperFailed(let message):
            message
        case .noUsageRows:
            "no usage limit reported for this account"
        }
    }
}

/// Reads the helper's output (`Helpers/claude-usage/usage.mjs`). Tolerant: unknown fields and kinds are ignored, a
/// row that cannot be read is skipped.
public enum ClaudeUsageParser {
    public static func parse(_ output: CommandOutput, fetchedAt: Date) -> Result<ClaudeUsage, ClaudeUsageProblem> {
        guard !output.stdout.isEmpty else {
            let stderr = String(decoding: output.stderr, as: UTF8.self)
            let first = stderr.split(separator: "\n").first.map { String($0.prefix(300)) }
            return .failure(.helperFailed(first ?? "no output from the helper"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
            return .failure(.helperFailed("unreadable helper output"))
        }
        if let message = object["error"] as? String {
            return .failure(.helperFailed(message))
        }
        let plan = object["subscription_type"] as? String
        guard object["rate_limits_available"] as? Bool == true, let rows = object["limits"] as? [Any] else {
            return .failure(plan.map { .rateLimitsUnavailable(plan: $0) } ?? .notLoggedIn)
        }
        var usage = ClaudeUsage(plan: plan, session: nil, weekly: nil, models: [], fetchedAt: fetchedAt)
        for case let row as [String: Any] in rows {
            guard let kind = row["kind"] as? String, var limit = limit(row) else { continue }
            limit.window = UsageWindow.length(ofKind: kind)
            switch kind {
            case "session" where usage.session == nil:
                usage.session = limit
            case "weekly_all" where usage.weekly == nil:
                usage.weekly = limit
            case "weekly_scoped":
                if let model = row["scope_model"] as? String, !model.isEmpty {
                    usage.models.append(ModelUsageLimit(model: model, limit: limit))
                }
            default:
                continue
            }
        }
        // A card with a bare label says nothing: no known row is a problem of its own.
        guard usage.session != nil || usage.weekly != nil || !usage.models.isEmpty else {
            return .failure(.noUsageRows)
        }
        return .success(usage)
    }

    private static func limit(_ row: [String: Any]) -> UsageLimit? {
        // JSONSerialization gives NSNumber for numbers and for booleans: reject the latter.
        guard let number = row["percent"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let percent = number.doubleValue
        guard percent.isFinite else { return nil }
        return UsageLimit(
            percent: percent, severity: UsageSeverity(server: row["severity"] as? String),
            resetsAt: (row["resets_at"] as? String).flatMap(date(_:)))
    }

    /// ISO 8601 with or without fractional seconds (the server sends microseconds).
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// What the card knows about one profile: the last good figures, the last problem, when it was last tried.
public struct ClaudeAccountState: Sendable, Equatable {
    public private(set) var usage: ClaudeUsage?
    /// Set by a failed refresh, cleared by a good one; the last good figures stay.
    public private(set) var problem: ClaudeUsageProblem?
    public private(set) var lastAttempt: Date?

    public init() {}

    public mutating func record(_ result: Result<ClaudeUsage, ClaudeUsageProblem>, at date: Date) {
        lastAttempt = date
        switch result {
        case .success(let usage):
            self.usage = usage
            problem = nil
        case .failure(let problem):
            self.problem = problem
        }
    }

    /// Figures older than two refresh intervals: shown dimmed with their age.
    public func isStale(now: Date, refreshMinutes: Int) -> Bool {
        guard let usage else { return false }
        return now.timeIntervalSince(usage.fetchedAt) > Double(2 * refreshMinutes * 60)
    }

    /// Never tried, or tried at least one interval ago (one second early still counts: timers drift).
    public func isDue(now: Date, refreshMinutes: Int) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= Double(refreshMinutes * 60) - 1
    }
}

/// Figures of the card.
public enum ResetFormat {
    /// Compact time to the reset, minutes rounded up: `44m`, `3h05`, `3h`, `2d12h`, `2d`. A reset in the past (clock
    /// skew, late refresh) reads `now`; an unknown one `–`.
    public static func short(_ date: Date?, now: Date) -> String {
        guard let date else { return "–" }
        guard let (days, hours, minutes) = parts(date, now: now) else { return "now" }
        if days > 0 { return hours == 0 ? "\(days)d" : "\(days)d\(hours)h" }
        if hours > 0 { return minutes == 0 ? "\(hours)h" : "\(hours)h" + (minutes < 10 ? "0" : "") + "\(minutes)" }
        return "\(minutes)m"
    }

    /// The same, spelt out for VoiceOver: `resets in 3 hours 5 minutes`, `resets now`, `no reset time`.
    public static func spoken(_ date: Date?, now: Date) -> String {
        guard let date else { return "no reset time" }
        guard let (days, hours, minutes) = parts(date, now: now) else { return "resets now" }
        func unit(_ value: Int, _ name: String) -> String? {
            value == 0 ? nil : "\(value) \(name)\(value == 1 ? "" : "s")"
        }
        let words =
            days > 0 ? [unit(days, "day"), unit(hours, "hour")] : [unit(hours, "hour"), unit(minutes, "minute")]
        return "resets in " + words.compactMap { $0 }.joined(separator: " ")
    }

    /// Days, hours and minutes to `date`, minutes rounded up (a day or more drops the minutes); nil once passed.
    private static func parts(_ date: Date, now: Date) -> (days: Int, hours: Int, minutes: Int)? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let total = max(1, Int((seconds / 60).rounded(.up)))
        let hours = total / 60
        return (hours / 24, hours % 24, total % 60)
    }

    /// Whole percent, rounded: `83%`.
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

/// Tooltip and VoiceOver text of a limit; the colour is said in words too.
public enum UsageText {
    /// Tooltip: the title, then the used and the steady-pace shares when the window is known.
    public static func help(_ title: String, _ limit: UsageLimit, now: Date) -> String {
        guard let expected = limit.expectedPercent(now: now) else { return title }
        return "\(title): \(ResetFormat.percent(limit.percent)) used, \(ResetFormat.percent(expected)) at a steady pace"
    }

    /// VoiceOver label: `5-hour quota, 26 %, above pace, resets in 44 minutes`.
    public static func spoken(_ title: String, _ limit: UsageLimit, now: Date) -> String {
        let pace =
            switch limit.reading(now: now) {
            case .normal: ""
            case .warning: ", above pace"
            case .critical: ", critical"
            }
        return "\(title), \(Int(limit.percent.rounded())) %\(pace), \(ResetFormat.spoken(limit.resetsAt, now: now))"
    }
}

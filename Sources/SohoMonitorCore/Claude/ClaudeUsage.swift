import Foundation

/// The server's reading of a row, for its colour. The client never grades a row itself (ADR 0001).
public enum UsageSeverity: String, Sendable, Equatable {
    case normal, warning, critical

    /// An unknown or missing value is shown as normal: a new server grade must not turn the card red.
    public init(server: String?) {
        self = server.flatMap(UsageSeverity.init(rawValue:)) ?? .normal
    }
}

/// One plan limit: share used, the server's severity, when the window resets.
public struct UsageLimit: Sendable, Equatable {
    public var percent: Double
    public var severity: UsageSeverity
    public var resetsAt: Date?

    public init(percent: Double, severity: UsageSeverity, resetsAt: Date?) {
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
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
            guard let kind = row["kind"] as? String, let limit = limit(row) else { continue }
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
    /// `in 2h 10m`, `in 45m`, `in 2d 14h`; a reset in the past (clock skew, late refresh) reads `reset`.
    public static func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "no reset time" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "reset" }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "in \(days)d" : "in \(days)d \(restHours)h"
    }

    /// Whole percent, rounded: `83%`.
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

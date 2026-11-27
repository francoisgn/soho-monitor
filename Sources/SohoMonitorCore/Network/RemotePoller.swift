import Foundation
import Synchronization

/// What a card of a LAN service (NAS, controller) shows.
public enum RemoteState<Value: Sendable>: Sendable {
    /// Nothing known yet.
    case loading
    case ok(Value, at: Date)
    /// The last attempts failed; the last good data, fetched at `since`, is still shown for a bounded time.
    case stale(Value, since: Date, reason: String)
    /// The host cannot be reached (off the LAN, no network) since the first failure of the streak.
    case unreachable(since: Date, reason: String)
    /// Another failure (TLS refusal, unexpected answer) with no data left to show.
    case failed(String)
    /// Credentials refused: polling stopped until they or the configuration change.
    case authFailed(String)
    /// No credentials saved: nothing is sent until they are.
    case needsSetup
}

extension RemoteState: Equatable where Value: Equatable {}

/// The outcome of one failed fetch, as the poller needs it.
public enum RemoteFailure: Error, Sendable, Equatable {
    /// DNS failure, refused, timeout: retried with backoff.
    case unreachable(String)
    /// Anything else that may go away by itself: retried with backoff.
    case failed(String)
    /// Stops polling until `credentialsChanged()`: never lock an account out by repeating a bad login.
    case authFailed(String)
    /// Stops polling until `credentialsChanged()`.
    case needsSetup
}

/// Timing rules of a poller.
public struct RemotePollPolicy: Sendable, Equatable {
    /// Between two successful fetches; also the base of the backoff. The module's floor is applied by its config.
    public var interval: Duration
    /// The longest wait between two attempts after failures.
    public var cap: Duration
    /// How long the last good data stays visible (as stale) after it was fetched; then it is cleared.
    public var staleLimit: Duration
    /// Upper bound of the random extra wait added to a backoff delay, as a fraction of it (never past `cap`).
    public var jitter: Double

    public init(
        interval: Duration, cap: Duration = .seconds(600), staleLimit: Duration = .seconds(900), jitter: Double = 0.2
    ) {
        self.interval = interval
        self.cap = max(cap, interval)
        self.staleLimit = staleLimit
        self.jitter = jitter
    }

    /// Wait before the next attempt after `failures` consecutive failures (at least 1): the interval, then doubled
    /// at each failure, capped; plus up to `jitter` of it (`random` in 0...1), still capped. Never below the
    /// interval, so the module's polling floor holds during failures too.
    public func backoff(afterFailures failures: Int, random: Double) -> Duration {
        let doublings = min(max(failures - 1, 0), 20)
        let raw = min(cap, interval * (1 << doublings))
        let extra = raw * (jitter * min(max(random, 0), 1))
        return min(cap, raw + extra)
    }
}

/// Held by a consumer (visible card) while it needs the data.
public struct RemoteDemand: Hashable, Sendable {
    let serial: UInt64
}

/// Polls one LAN service: one request in flight at most, only while demanded and while the network path is
/// satisfied, every `interval` after a success and with exponential backoff after failures. An auth failure or
/// missing credentials stop it until `credentialsChanged()`. Shared by the Synology and UniFi modules.
public actor RemotePoller<Value: Sendable, C: Clock> where C.Duration == Duration {
    private let policy: RemotePollPolicy
    private let clock: C
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let fetch: @Sendable () async -> Result<Value, RemoteFailure>

    public private(set) var state: RemoteState<Value> = .loading
    /// When the next attempt is due; nil: as soon as possible (or never, while stopped or off the network).
    private(set) var nextAttempt: C.Instant?
    private var demand: Set<UInt64> = []
    private var serial: UInt64 = 0
    private var pathSatisfied = true
    private var stopped = false
    private var failures = 0
    private var failingSince: Date?
    private var lastGood: (value: Value, at: Date)?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var observers: [Int: AsyncStream<RemoteState<Value>>.Continuation] = [:]
    private var nextObserver = 0

    public init(
        policy: RemotePollPolicy, clock: C, now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        fetch: @escaping @Sendable () async -> Result<Value, RemoteFailure>
    ) {
        self.policy = policy
        self.clock = clock
        self.now = now
        self.random = random
        self.fetch = fetch
    }

    /// True while the polling loop runs (something is demanded).
    public var isRunning: Bool { loop != nil }

    /// The current state at once, then every change.
    public func updates() -> AsyncStream<RemoteState<Value>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RemoteState<Value>.self, bufferingPolicy: .bufferingNewest(1))
        nextObserver += 1
        let id = nextObserver
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    /// Starts polling (an attempt at once if one is due) until every demand is released.
    public func acquire() -> RemoteDemand {
        serial += 1
        demand.insert(serial)
        if loop == nil {
            loop = Task { await self.run() }
        } else {
            sleeper?.cancel()
        }
        return RemoteDemand(serial: serial)
    }

    /// Ends one demand; the loop stops (after a request in flight) when none is left. Releasing twice is harmless.
    public func release(_ token: RemoteDemand) {
        guard demand.remove(token.serial) != nil, demand.isEmpty else { return }
        sleeper?.cancel()
    }

    /// From `NWPathMonitor`. Unsatisfied: `.unreachable` at once, no request. Satisfied (a new path): one attempt at
    /// once, then the normal cadence.
    public func setPathSatisfied(_ satisfied: Bool) {
        pathSatisfied = satisfied
        if satisfied {
            nextAttempt = nil
        } else {
            let since = failingSince ?? now()
            failingSince = since
            publish(.unreachable(since: since, reason: "no network"))
        }
        sleeper?.cancel()
    }

    /// The secret or the configuration changed: polling resumes at once with a clean slate.
    public func credentialsChanged() {
        stopped = false
        failures = 0
        failingSince = nil
        nextAttempt = nil
        publish(.loading)
        sleeper?.cancel()
    }

    private func run() async {
        while !demand.isEmpty, !Task.isCancelled {
            if !pathSatisfied || stopped {
                await pause(until: nil)
                continue
            }
            if let due = nextAttempt, due > clock.now {
                await pause(until: due)
                continue
            }
            let result = await fetch()
            record(result)
        }
        loop = nil
    }

    /// Sleeps until `deadline` (nil: until woken), or until an event cancels the sleep.
    private func pause(until deadline: C.Instant?) async {
        let clock = clock
        let wake = deadline ?? clock.now.advanced(by: .seconds(86_400 * 365))
        let task = Task { _ = try? await clock.sleep(until: wake, tolerance: nil) }
        sleeper = task
        await task.value
        sleeper = nil
    }

    private func record(_ result: Result<Value, RemoteFailure>) {
        let date = now()
        switch result {
        case .success(let value):
            failures = 0
            failingSince = nil
            lastGood = (value, date)
            nextAttempt = clock.now.advanced(by: policy.interval)
            publish(.ok(value, at: date))
        case .failure(.authFailed(let reason)):
            stop(.authFailed(reason))
        case .failure(.needsSetup):
            stop(.needsSetup)
        case .failure(.unreachable(let reason)), .failure(.failed(let reason)):
            failures += 1
            let since = failingSince ?? date
            failingSince = since
            nextAttempt = clock.now.advanced(by: policy.backoff(afterFailures: failures, random: random()))
            if !pathSatisfied {
                // The path went away while the request was in flight: that is the reason to show.
                publish(.unreachable(since: since, reason: "no network"))
            } else if let good = lastGood, date.timeIntervalSince(good.at) <= policy.staleLimit.seconds {
                publish(.stale(good.value, since: good.at, reason: reason))
            } else {
                lastGood = nil
                if case .unreachable = result.failure {
                    publish(.unreachable(since: since, reason: reason))
                } else {
                    publish(.failed(reason))
                }
            }
        }
    }

    private func stop(_ state: RemoteState<Value>) {
        stopped = true
        failures = 0
        nextAttempt = nil
        publish(state)
    }

    private func publish(_ new: RemoteState<Value>) {
        state = new
        for observer in observers.values { observer.yield(new) }
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

extension Duration {
    /// In seconds, with the fraction.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

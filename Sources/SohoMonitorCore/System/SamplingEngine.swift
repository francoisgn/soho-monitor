import Synchronization

/// Produces one value of a metric per call. Rates (CPU ticks, network bytes) keep their previous raw reading inside
/// the collector and return nil when no rate can be computed yet.
public protocol MetricCollector: Sendable {
    associatedtype Value: Sendable
    /// Nil: nothing to show yet (first reading of a rate). Throws when the metric cannot be read.
    func sample() async throws -> Value?
    /// Forgets the previous raw reading: the next sample yields no rate (start, wake from sleep, long pause).
    func reset() async
}

/// What a card shows for a metric.
public enum MetricStatus<Value: Sendable>: Sendable {
    /// No value yet.
    case loading
    case value(Value)
    /// The last sample failed; the reason is shown, never a fake 0.
    case unavailable(String)
}

extension MetricStatus: Equatable where Value: Equatable {}

/// Name of a registered metric ("cpu", "memory").
public struct MetricID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// Held by a consumer (visible panel, open popover, menu bar indicator) while it needs a metric.
public struct DemandToken: Hashable, Sendable {
    public let metric: MetricID
    let serial: UInt64
}

/// Output of one metric: current status, history (oldest first) and a stream of every status change.
public final class MetricChannel<Value: Sendable>: Sendable {
    public let id: MetricID

    private struct State {
        var status: MetricStatus<Value> = .loading
        var history: RingBuffer<Value>
        var nextObserver = 0
        var observers: [Int: AsyncStream<MetricStatus<Value>>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(id: MetricID, capacity: Int) {
        self.id = id
        state = Mutex(State(history: RingBuffer(capacity: capacity)))
    }

    public var status: MetricStatus<Value> { state.withLock { $0.status } }
    public var history: [Value] { state.withLock { $0.history.elements } }

    /// The current status at once, then every change, until the consumer stops iterating. Only the newest status
    /// is buffered: a slow consumer skips intermediate ones rather than accumulating them.
    public func updates() -> AsyncStream<MetricStatus<Value>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: MetricStatus<Value>.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            state.nextObserver += 1
            state.observers[state.nextObserver] = continuation
            continuation.yield(state.status)
            return state.nextObserver
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    func publish(_ value: Value) {
        update { state in
            state.history.append(value)
            state.status = .value(value)
        }
    }

    func fail(_ reason: String) {
        update { $0.status = .unavailable(reason) }
    }

    private func update(_ change: (inout State) -> Void) {
        state.withLock { state in
            change(&state)
            for observer in state.observers.values { observer.yield(state.status) }
        }
    }
}

/// One shared sampler for every metric. A metric is sampled only while at least one `DemandToken` is held for it:
/// with no demand, no timer runs and no collector is called. Each metric has its own interval (at least 1 s); the
/// first sample is taken as soon as a metric is demanded.
///
/// After a gap longer than `gapFactor` intervals (the Mac slept, or the metric was not demanded for a while), the
/// collector is reset before sampling, so the first rate after the gap is not an average over the whole gap; and the
/// next tick is scheduled from now, never as a burst of catch-up ticks. Use a clock that keeps counting while the Mac
/// sleeps (`ContinuousClock`) so that the gap is seen.
public actor SamplingEngine<C: Clock> where C.Duration == Duration {
    public static var minimumInterval: Duration { .seconds(1) }

    private struct Entry {
        var interval: Duration
        var tick: @Sendable () async -> Void
        var reset: @Sendable () async -> Void
        var demand: Set<UInt64> = []
        var nextDue: C.Instant?
        var lastSample: C.Instant?
    }

    private let clock: C
    private let gapFactor: Int
    private var entries: [MetricID: Entry] = [:]
    private var serial: UInt64 = 0
    private var loop: Task<Void, Never>?
    /// Bumped whenever the loop is replaced: an older loop that resumes after a restart stops at once.
    private var generation = 0

    public init(clock: C, gapFactor: Int = 3) {
        self.clock = clock
        self.gapFactor = max(2, gapFactor)
    }

    /// True while a timer runs (some metric is demanded).
    public var isRunning: Bool { loop != nil }

    /// Adds a metric. `interval` is clamped to at least 1 s; `capacity` is the history length. Registering an id again
    /// replaces the previous collector (its demand is kept).
    public func register<M: MetricCollector>(
        _ id: MetricID, collector: M, interval: Duration = .seconds(1), capacity: Int = 120
    ) -> MetricChannel<M.Value> {
        let channel = MetricChannel<M.Value>(id: id, capacity: capacity)
        let entry = Entry(
            interval: max(interval, Self.minimumInterval),
            tick: {
                do {
                    if let value = try await collector.sample() { channel.publish(value) }
                } catch {
                    channel.fail(String(describing: error))
                }
            },
            reset: { await collector.reset() },
            demand: entries[id]?.demand ?? [])
        entries[id] = entry
        return channel
    }

    /// Starts sampling `id` (at once if it was not demanded yet) until the token is released.
    public func acquire(_ id: MetricID) -> DemandToken {
        serial += 1
        let token = DemandToken(metric: id, serial: serial)
        guard entries[id] != nil else { return token }
        let wasIdle = entries[id]?.demand.isEmpty ?? true
        entries[id]?.demand.insert(token.serial)
        if wasIdle { restart() }
        return token
    }

    /// Ends one demand; releasing a token twice is harmless. The timer stops when nothing is demanded any more.
    public func release(_ token: DemandToken) {
        guard entries[token.metric]?.demand.remove(token.serial) != nil else { return }
        guard entries[token.metric]?.demand.isEmpty == true else { return }
        entries[token.metric]?.nextDue = nil
        if entries.values.allSatisfy({ $0.demand.isEmpty }) {
            stop()
        }
    }

    private func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    private func restart() {
        stop()
        let current = generation
        loop = Task { await self.run(generation: current) }
    }

    private func run(generation current: Int) async {
        while generation == current, !Task.isCancelled {
            let now = clock.now
            for id in entries.keys where entries[id]?.demand.isEmpty == false {
                guard generation == current, let entry = entries[id], !entry.demand.isEmpty else { continue }
                if let due = entry.nextDue, due > now { continue }
                // Next tick one interval after the one that was due, or from now after a gap: never a catch-up burst.
                // Recorded before the awaits below: the actor is free during them, and a loop restarted meanwhile
                // (another metric acquired) must not sample this one a second time, microseconds later.
                var next = (entry.nextDue ?? now).advanced(by: entry.interval)
                if next <= now { next = now.advanced(by: entry.interval) }
                entries[id]?.nextDue = next
                entries[id]?.lastSample = now
                if let last = entry.lastSample, last.duration(to: now) > entry.interval * gapFactor {
                    await entry.reset()
                }
                await entry.tick()
                guard generation == current else { return }
            }
            let dues = entries.values.filter { !$0.demand.isEmpty }.compactMap(\.nextDue)
            guard generation == current, let wake = dues.min() else { return }
            do {
                try await clock.sleep(until: wake, tolerance: .milliseconds(100))
            } catch {
                return
            }
        }
    }
}

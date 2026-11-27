import Foundation
import Synchronization
import Testing

@testable import SohoMonitorCore

/// A clock that only moves when the test says so. `sleep` suspends until `advance` reaches the deadline;
/// `waitForSleeper` returns once something sleeps on it (the engine has finished its tick).
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var cancelled: Set<Int> = []
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (resumeNow, waiters): (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) =
                    state.withLock { state in
                        if state.cancelled.remove(id) != nil { return (.failure(CancellationError()), []) }
                        if deadline <= state.now { return (.success(()), []) }
                        state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                        defer { state.waiters = [] }
                        return (nil, state.waiters)
                    }
                if let resumeNow { continuation.resume(with: resumeNow) }
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Sleeper?.none
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let ids = state.sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0)?.continuation }
        }
        for continuation in due { continuation.resume() }
    }

    /// Returns once at least one task sleeps on this clock.
    func waitForSleeper() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state in
                if !state.sleepers.isEmpty { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Counts its calls and returns the call number; can be told to fail, or to return no value (a rate's first sample).
final class CountingCollector: MetricCollector {
    private let calls = Mutex(0)
    private let resets = Mutex(0)
    private let failing = Mutex(false)
    let primes: Bool
    private let primed = Mutex(false)

    init(primes: Bool = false) { self.primes = primes }

    var callCount: Int { calls.withLock { $0 } }
    var resetCount: Int { resets.withLock { $0 } }
    func setFailing(_ value: Bool) { failing.withLock { $0 = value } }

    func sample() async throws -> Int? {
        let call = calls.withLock { count in
            count += 1
            return count
        }
        if failing.withLock({ $0 }) { throw ProbeError.unreadable("sensor gone") }
        if primes, !primed.withLock({ $0 }) {
            primed.withLock { $0 = true }
            return nil
        }
        return call
    }

    func reset() async {
        resets.withLock { $0 += 1 }
        primed.withLock { $0 = false }
    }
}

/// A collector whose `sample()` suspends until `open()`: lets a test act while a tick is in flight.
final class GatedCollector: MetricCollector {
    private struct State {
        var calls = 0
        var isOpen = false
        var blocked: [CheckedContinuation<Void, Never>] = []
        var insideWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var callCount: Int { state.withLock { $0.calls } }

    func sample() async throws -> Int? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (resumeNow, inside) = state.withLock { state in
                state.calls += 1
                defer { state.insideWaiters = [] }
                if state.isOpen { return (true, state.insideWaiters) }
                state.blocked.append(continuation)
                return (false, state.insideWaiters)
            }
            for waiter in inside { waiter.resume() }
            if resumeNow { continuation.resume() }
        }
        return callCount
    }

    func reset() async {}

    /// Returns once a `sample()` call has started.
    func waitUntilInside() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state in
                if state.calls > 0 { return true }
                state.insideWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Lets every blocked and future `sample()` call through.
    func open() {
        let blocked = state.withLock { state in
            state.isOpen = true
            defer { state.blocked = [] }
            return state.blocked
        }
        for continuation in blocked { continuation.resume() }
    }
}

@Suite(.timeLimit(.minutes(1))) struct SamplingEngineTests {
    let clock = ManualClock()

    private func tick(_ seconds: Int = 1) async {
        clock.advance(by: .seconds(seconds))
        await clock.waitForSleeper()
    }

    @Test func noConsumerMeansNoCall() async {
        let engine = SamplingEngine(clock: clock)
        let collector = CountingCollector()
        _ = await engine.register("cpu", collector: collector)
        clock.advance(by: .seconds(10))
        await Task.yield()
        #expect(collector.callCount == 0)
        #expect(await engine.isRunning == false)
    }

    @Test func oneConsumerGetsOneSamplePerSecond() async {
        let engine = SamplingEngine(clock: clock)
        let collector = CountingCollector(primes: true)
        let channel = await engine.register("cpu", collector: collector, capacity: 10)
        _ = await engine.acquire("cpu")
        await clock.waitForSleeper()  // the priming sample, taken at once
        #expect(channel.history.isEmpty)
        #expect(channel.status == .loading)
        for _ in 0..<3 { await tick() }
        #expect(channel.history == [2, 3, 4])
        #expect(channel.status == .value(4))
    }

    @Test func aGaugeShowsItsFirstSampleAtOnce() async {
        let engine = SamplingEngine(clock: clock)
        let channel = await engine.register("memory", collector: CountingCollector())
        _ = await engine.acquire("memory")
        await clock.waitForSleeper()
        #expect(channel.status == .value(1))
        #expect(channel.history == [1])
    }

    @Test func releasingTheLastTokenStopsTheTimer() async {
        let engine = SamplingEngine(clock: clock)
        let collector = CountingCollector()
        _ = await engine.register("cpu", collector: collector)
        let first = await engine.acquire("cpu")
        let second = await engine.acquire("cpu")
        await clock.waitForSleeper()
        await engine.release(first)
        await tick()
        #expect(collector.callCount == 2)  // still demanded by the second token
        await engine.release(second)
        #expect(clock.sleeperCount == 0)
        #expect(await engine.isRunning == false)
        clock.advance(by: .seconds(5))
        await Task.yield()
        #expect(collector.callCount == 2)
    }

    @Test func releasingTwiceOrAnUnknownTokenIsHarmless() async {
        let engine = SamplingEngine(clock: clock)
        let collector = CountingCollector()
        _ = await engine.register("cpu", collector: collector)
        let token = await engine.acquire("cpu")
        let keep = await engine.acquire("cpu")
        await clock.waitForSleeper()
        await engine.release(token)
        await engine.release(token)
        #expect(await engine.isRunning)
        await tick()
        #expect(collector.callCount == 2)
        await engine.release(keep)
    }

    @Test func historyKeepsTheLatestCapacitySamples() async {
        let engine = SamplingEngine(clock: clock)
        let channel = await engine.register("memory", collector: CountingCollector(), capacity: 3)
        _ = await engine.acquire("memory")
        await clock.waitForSleeper()
        for _ in 0..<5 { await tick() }
        #expect(channel.history == [4, 5, 6])
    }

    @Test func aFailingCollectorIsUnavailableOthersContinueAndItIsRetriedNextTick() async {
        let engine = SamplingEngine(clock: clock)
        let broken = CountingCollector()
        let healthy = CountingCollector()
        let brokenChannel = await engine.register("cpu", collector: broken)
        let healthyChannel = await engine.register("memory", collector: healthy)
        broken.setFailing(true)
        _ = await engine.acquire("cpu")
        await clock.waitForSleeper()  // the cpu tick has finished
        _ = await engine.acquire("memory")
        await clock.waitForSleeper()
        #expect(brokenChannel.status == .unavailable("sensor gone"))
        #expect(healthyChannel.status == .value(1))
        await tick()
        #expect(broken.callCount == 2)  // retried once per interval, no tighter loop
        #expect(healthyChannel.status == .value(2))
        broken.setFailing(false)
        await tick()
        #expect(brokenChannel.status == .value(3))
    }

    @Test func anIntervalBelowOneSecondIsClampedToOneSecond() async {
        let engine = SamplingEngine(clock: clock)
        let collector = CountingCollector()
        _ = await engine.register("cpu", collector: collector, interval: .milliseconds(100))
        _ = await engine.acquire("cpu")
        await clock.waitForSleeper()
        clock.advance(by: .milliseconds(900))
        await Task.yield()
        #expect(collector.callCount == 1)
        #expect(clock.sleeperCount == 1)
        await tick(0)  // reaches 1 s: one more sample
        clock.advance(by: .milliseconds(100))
        await clock.waitForSleeper()
        #expect(collector.callCount == 2)
    }

    @Test func aLongGapResetsTheRateAndCausesNoCatchUpBurst() async {
        let engine = SamplingEngine(clock: clock)
        let collector = CountingCollector(primes: true)
        let channel = await engine.register("cpu", collector: collector)
        _ = await engine.acquire("cpu")
        await clock.waitForSleeper()
        await tick()
        #expect(channel.history == [2])
        await tick(60)  // the Mac slept for a minute
        #expect(collector.callCount == 3)  // one tick, not sixty
        #expect(collector.resetCount == 1)
        #expect(channel.history == [2])  // first sample after wake: no rate
        await tick()
        #expect(channel.history == [2, 4])
    }

    @Test func reacquiringAfterAPauseStartsAFreshRate() async {
        let engine = SamplingEngine(clock: clock)
        let collector = CountingCollector(primes: true)
        _ = await engine.register("cpu", collector: collector)
        let token = await engine.acquire("cpu")
        await clock.waitForSleeper()
        await tick()
        await engine.release(token)
        clock.advance(by: .seconds(30))
        _ = await engine.acquire("cpu")
        await clock.waitForSleeper()
        #expect(collector.resetCount == 1)
        #expect(collector.callCount == 3)
    }

    @Test func updatesStreamTheCurrentStatusThenEachChange() async {
        let engine = SamplingEngine(clock: clock)
        let channel = await engine.register("memory", collector: CountingCollector())
        var iterator = channel.updates().makeAsyncIterator()
        #expect(await iterator.next() == .loading)
        _ = await engine.acquire("memory")
        #expect(await iterator.next() == .value(1))
        await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        #expect(await iterator.next() == .value(2))
    }

    @Test func acquiringAnotherMetricDuringATickDoesNotSampleTheFirstTwice() async {
        let engine = SamplingEngine(clock: clock)
        let gated = GatedCollector()
        let memory = CountingCollector()
        _ = await engine.register("cpu", collector: gated)
        _ = await engine.register("memory", collector: memory)
        _ = await engine.acquire("cpu")
        await gated.waitUntilInside()  // the cpu tick is in flight: the actor is free
        _ = await engine.acquire("memory")  // restarts the loop
        gated.open()
        await clock.waitForSleeper()
        #expect(gated.callCount == 1)
        #expect(memory.callCount == 1)
    }

    @Test func releasingAndReacquiringDuringATickDoesNotOverlapIt() async {
        let engine = SamplingEngine(clock: clock)
        let gated = GatedCollector()
        _ = await engine.register("cpu", collector: gated)
        let token = await engine.acquire("cpu")
        await gated.waitUntilInside()
        await engine.release(token)  // the panel flaps hidden then shown while the tick is in flight
        _ = await engine.acquire("cpu")
        gated.open()
        await clock.waitForSleeper()
        #expect(gated.callCount == 1)
        await tick()
        #expect(gated.callCount == 2)  // back to one sample per interval
    }

    @Test func acquiringAnUnregisteredMetricDoesNotStartTheTimer() async {
        let engine = SamplingEngine(clock: clock)
        _ = await engine.acquire("gpu")
        #expect(await engine.isRunning == false)
    }
}

import Foundation
import Synchronization
import Testing

@testable import SohoMonitorCore

@Suite struct RemotePollPolicyTests {
    private let policy = RemotePollPolicy(interval: .seconds(60), cap: .seconds(600))

    @Test func backoffDoublesFromTheIntervalAndStopsAtTheCap() {
        let delays = (1...8).map { policy.backoff(afterFailures: $0, random: 0) }
        #expect(delays == [60, 120, 240, 480, 600, 600, 600, 600].map { Duration.seconds($0) })
    }

    @Test func jitterAddsAtMostItsShareAndNeverPassesTheCap() {
        #expect(policy.backoff(afterFailures: 1, random: 1) == .seconds(72))
        #expect(policy.backoff(afterFailures: 4, random: 1) == .seconds(576))
        #expect(policy.backoff(afterFailures: 5, random: 1) == .seconds(600))
        #expect(policy.backoff(afterFailures: 1000, random: 1) == .seconds(600))
        // Never below the interval: the module's polling floor holds during failures too.
        #expect(policy.backoff(afterFailures: 1, random: -5) == .seconds(60))
    }
}

/// Drives a `RemotePoller` with a manual clock (`SamplingEngineTests.swift`) and a scripted fetch.
@Suite(.timeLimit(.minutes(1))) struct RemotePollerTests {
    /// Answers each fetch with the next scripted result (the last one repeats) and counts the calls.
    final class ScriptedFetch: Sendable {
        private struct State {
            var script: [Result<Int, RemoteFailure>]
            var calls = 0
        }

        private let state: Mutex<State>

        init(_ script: [Result<Int, RemoteFailure>]) {
            state = Mutex(State(script: script))
        }

        var calls: Int { state.withLock { $0.calls } }

        func set(_ script: [Result<Int, RemoteFailure>]) {
            state.withLock { $0.script = script }
        }

        func callAsFunction() -> Result<Int, RemoteFailure> {
            state.withLock { state in
                state.calls += 1
                return state.script.count > 1 ? state.script.removeFirst() : state.script[0]
            }
        }
    }

    let clock = ManualClock()

    private func poller(_ fetch: ScriptedFetch, staleLimit: Duration = .seconds(900))
        -> RemotePoller<Int, ManualClock>
    {
        let clock = clock
        return RemotePoller(
            policy: RemotePollPolicy(interval: .seconds(60), cap: .seconds(600), staleLimit: staleLimit),
            clock: clock,
            now: { Date(timeIntervalSince1970: clock.now.offset.seconds) },
            random: { 0 },
            fetch: { fetch() })
    }

    /// Waits until the poller sleeps again (its attempt is done), then returns the wait before the next attempt.
    private func settle(_ poller: RemotePoller<Int, ManualClock>) async -> Duration? {
        await clock.waitForSleeper()
        return await poller.nextAttempt.map { clock.now.duration(to: $0) }
    }

    @Test func consecutiveFailuresAreSpacedByTheBackoffScheduleUpToTheCap() async {
        let fetch = ScriptedFetch([.failure(.unreachable("timed out"))])
        let poller = poller(fetch)
        let token = await poller.acquire()
        var waits: [Duration] = []
        for _ in 1...6 {
            guard let wait = await settle(poller) else { break }
            waits.append(wait)
            // Just before the deadline nothing is sent.
            clock.advance(by: wait - .seconds(1))
            #expect(fetch.calls == waits.count)
            clock.advance(by: .seconds(1))
        }
        _ = await settle(poller)
        #expect(waits == [60, 120, 240, 480, 600, 600].map { Duration.seconds($0) })
        #expect(fetch.calls == 7)
        #expect(await poller.state == .unreachable(since: Date(timeIntervalSince1970: 0), reason: "timed out"))
        await poller.release(token)
    }

    @Test func aSuccessResetsTheBackoff() async {
        let fetch = ScriptedFetch([
            .failure(.unreachable("refused")), .failure(.unreachable("refused")), .success(7),
            .failure(.unreachable("refused")),
        ])
        let poller = poller(fetch)
        let token = await poller.acquire()
        #expect(await settle(poller) == .seconds(60))
        clock.advance(by: .seconds(60))
        #expect(await settle(poller) == .seconds(120))
        clock.advance(by: .seconds(120))
        #expect(await settle(poller) == .seconds(60))  // the success
        #expect(await poller.state == .ok(7, at: Date(timeIntervalSince1970: 180)))
        clock.advance(by: .seconds(60))
        #expect(await settle(poller) == .seconds(60))  // first failure of a new streak
        #expect(
            await poller.state == .stale(7, since: Date(timeIntervalSince1970: 180), reason: "refused"))
        await poller.release(token)
    }

    @Test func anAuthFailureStopsRequestsUntilTheCredentialsChange() async {
        let fetch = ScriptedFetch([.failure(.authFailed("wrong user name or password")), .success(1)])
        let poller = poller(fetch)
        let token = await poller.acquire()
        #expect(await settle(poller) == nil)
        #expect(await poller.state == .authFailed("wrong user name or password"))
        clock.advance(by: .seconds(86_400))
        await clock.waitForSleeper()
        #expect(fetch.calls == 1)
        await poller.credentialsChanged()
        #expect(await settle(poller) == .seconds(60))
        #expect(fetch.calls == 2)
        #expect(await poller.state == .ok(1, at: Date(timeIntervalSince1970: 86_400)))
        await poller.release(token)
    }

    @Test func missingCredentialsStopRequestsToo() async {
        let fetch = ScriptedFetch([.failure(.needsSetup)])
        let poller = poller(fetch)
        let token = await poller.acquire()
        #expect(await settle(poller) == nil)
        #expect(await poller.state == .needsSetup)
        clock.advance(by: .seconds(3_600))
        await clock.waitForSleeper()
        #expect(fetch.calls == 1)
        await poller.release(token)
    }

    @Test func withoutANetworkPathItIsUnreachableAndSendsNothing() async {
        let fetch = ScriptedFetch([.success(3)])
        let poller = poller(fetch)
        await poller.setPathSatisfied(false)
        let token = await poller.acquire()
        await clock.waitForSleeper()
        clock.advance(by: .seconds(3_600))
        await clock.waitForSleeper()
        #expect(fetch.calls == 0)
        #expect(await poller.state == .unreachable(since: Date(timeIntervalSince1970: 0), reason: "no network"))
        // The path comes back: one attempt at once, then the normal cadence.
        await poller.setPathSatisfied(true)
        #expect(await settle(poller) == .seconds(60))
        #expect(fetch.calls == 1)
        #expect(await poller.state == .ok(3, at: Date(timeIntervalSince1970: 3_600)))
        await poller.release(token)
    }

    @Test func aReturningPathCutsTheBackoffShort() async {
        let fetch = ScriptedFetch([
            .failure(.unreachable("timed out")), .failure(.unreachable("timed out")), .success(1),
        ])
        let poller = poller(fetch)
        let token = await poller.acquire()
        _ = await settle(poller)
        clock.advance(by: .seconds(60))
        #expect(await settle(poller) == .seconds(120))  // t = 60, backing off until 180
        clock.advance(by: .seconds(100))
        await poller.setPathSatisfied(false)  // t = 160: off the network
        await poller.setPathSatisfied(true)  // back: one attempt at once, not at 180
        #expect(await settle(poller) == .seconds(60))
        #expect(fetch.calls == 3)
        #expect(await poller.state == .ok(1, at: Date(timeIntervalSince1970: 160)))
        await poller.release(token)
    }

    @Test func anotherSatisfiedPathAfterASuccessKeepsTheCadence() async {
        let fetch = ScriptedFetch([.success(1)])
        let poller = poller(fetch)
        let token = await poller.acquire()
        #expect(await settle(poller) == .seconds(60))
        clock.advance(by: .seconds(10))
        await poller.setPathSatisfied(true)  // e.g. Wi-Fi to Ethernet
        #expect(await settle(poller) == .seconds(50))
        #expect(fetch.calls == 1)
        await poller.release(token)
    }

    @Test func aRepeatedPathEventNeverBringsAnAttemptWithinAnInterval() async {
        let fetch = ScriptedFetch([.failure(.unreachable("refused"))])
        let poller = poller(fetch)
        let token = await poller.acquire()
        _ = await settle(poller)  // t = 0, next at 60
        clock.advance(by: .seconds(60))
        #expect(await settle(poller) == .seconds(120))  // t = 60, backing off until 180
        clock.advance(by: .seconds(10))
        await poller.setPathSatisfied(true)  // t = 70: flaps
        await poller.setPathSatisfied(true)
        #expect(await settle(poller) == .seconds(50))  // one interval after the last attempt, not at once
        #expect(fetch.calls == 2)
        await poller.release(token)
    }

    @Test func aStoppedPollerKeepsAskingForCredentialsAcrossNetworkChanges() async {
        let fetch = ScriptedFetch([.failure(.authFailed("wrong user name or password"))])
        let poller = poller(fetch)
        let token = await poller.acquire()
        _ = await settle(poller)
        await poller.setPathSatisfied(false)
        #expect(await poller.state == .authFailed("wrong user name or password"))
        await poller.setPathSatisfied(true)
        await clock.waitForSleeper()
        #expect(await poller.state == .authFailed("wrong user name or password"))
        #expect(fetch.calls == 1)
        await poller.release(token)
    }

    @Test func aFetchInFlightWhenCredentialsChangeIsIgnored() async {
        let gate = GatedFetch()
        let clock = clock
        let poller = RemotePoller<Int, ManualClock>(
            policy: RemotePollPolicy(interval: .seconds(60)), clock: clock,
            now: { Date(timeIntervalSince1970: clock.now.offset.seconds) }, random: { 0 },
            fetch: { await gate.fetch() })
        let token = await poller.acquire()
        await gate.waitUntilInside()
        await poller.credentialsChanged()  // the user saved a new password meanwhile
        gate.open(with: .failure(.authFailed("wrong user name or password")), then: .success(9))
        #expect(await settle(poller) == .seconds(60))
        #expect(gate.calls == 2)
        #expect(await poller.state == .ok(9, at: Date(timeIntervalSince1970: 0)))
        await poller.release(token)
    }

    /// The first fetch suspends until `open`; the later ones answer `then` at once.
    final class GatedFetch: Sendable {
        private struct State {
            var calls = 0
            var first: Result<Int, RemoteFailure>?
            var then: Result<Int, RemoteFailure> = .success(0)
            var blocked: CheckedContinuation<Result<Int, RemoteFailure>, Never>?
            var insideWaiter: CheckedContinuation<Void, Never>?
        }

        private let state = Mutex(State())

        var calls: Int { state.withLock { $0.calls } }

        func fetch() async -> Result<Int, RemoteFailure> {
            let call = state.withLock { state in
                state.calls += 1
                return state.calls
            }
            if call > 1 { return state.withLock { $0.then } }
            return await withCheckedContinuation { continuation in
                let waiter = state.withLock { state in
                    state.blocked = continuation
                    defer { state.insideWaiter = nil }
                    return state.insideWaiter
                }
                waiter?.resume()
            }
        }

        func waitUntilInside() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let inside = state.withLock { state in
                    if state.blocked != nil { return true }
                    state.insideWaiter = continuation
                    return false
                }
                if inside { continuation.resume() }
            }
        }

        func open(with first: Result<Int, RemoteFailure>, then: Result<Int, RemoteFailure>) {
            let blocked = state.withLock { state in
                state.then = then
                defer { state.blocked = nil }
                return state.blocked
            }
            blocked?.resume(returning: first)
        }
    }

    @Test func staleDataIsKeptForABoundedTimeThenCleared() async {
        let fetch = ScriptedFetch([.success(5), .failure(.failed("HTTP 502"))])
        let poller = poller(fetch, staleLimit: .seconds(200))
        let token = await poller.acquire()
        _ = await settle(poller)
        clock.advance(by: .seconds(60))  // t = 60: 60 s after the good data
        _ = await settle(poller)
        #expect(await poller.state == .stale(5, since: Date(timeIntervalSince1970: 0), reason: "HTTP 502"))
        clock.advance(by: .seconds(60))  // t = 120
        _ = await settle(poller)
        clock.advance(by: .seconds(120))  // t = 240: past the limit
        _ = await settle(poller)
        #expect(await poller.state == .failed("HTTP 502"))
        await poller.release(token)
    }

    @Test func releasingTheLastDemandStopsTheLoop() async {
        let fetch = ScriptedFetch([.success(1)])
        let poller = poller(fetch)
        let token = await poller.acquire()
        _ = await settle(poller)
        await poller.release(token)
        while await poller.isRunning { await Task.yield() }
        clock.advance(by: .seconds(3_600))
        #expect(fetch.calls == 1)
        // Demanded again after the interval: one attempt at once, then the normal cadence.
        let again = await poller.acquire()
        #expect(await settle(poller) == .seconds(60))
        #expect(fetch.calls == 2)
        await poller.release(again)
    }
}

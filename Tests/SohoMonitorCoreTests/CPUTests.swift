import Foundation
import Synchronization
import Testing

@testable import SohoMonitorCore

/// Tick snapshots shaped like `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` (user, system, idle, nice per core);
/// values made up.
enum CPUFixtures {
    static let first = CPUTicks(cores: [
        CoreTicks(user: 100, system: 50, idle: 800, nice: 10),
        CoreTicks(user: 10, system: 10, idle: 1000, nice: 0),
    ])
    /// Core 0: +60 user, +20 system, +100 idle, +10 nice (90 busy of 190); core 1: +10, +10, +170, +0 (20 of 190).
    static let second = CPUTicks(cores: [
        CoreTicks(user: 160, system: 70, idle: 900, nice: 20),
        CoreTicks(user: 20, system: 20, idle: 1170, nice: 0),
    ])
}

/// Answers sysctl names from a dictionary, as a Mac without some keys would.
struct FakeSysctl: SysctlReading {
    var strings: [String: String] = [:]
    var ints: [String: Int] = [:]
    func string(_ name: String) -> String? { strings[name] }
    func int(_ name: String) -> Int? { ints[name] }
}

@Suite struct CPUUsageTests {
    @Test func busyTicksOverTotalTicks() throws {
        let usage = try #require(CPUUsage.between(CPUFixtures.first, CPUFixtures.second))
        #expect(usage.total == 110.0 / 380.0)
        #expect(usage.perCore == [90.0 / 190.0, 20.0 / 190.0])
        #expect(usage.user == 70.0 / 380.0)
        #expect(usage.system == 30.0 / 380.0)
    }

    @Test func levelTurnsOrangeAt70AndRedAt90Percent() {
        func usage(_ total: Double) -> CPUUsage { CPUUsage(total: total, user: total, system: 0, perCore: []) }
        #expect(usage(0.69).level == .normal)
        #expect(usage(0.7).level == .warning)
        #expect(usage(0.9).level == .critical)
    }

    @Test func countersGoingBackwardsAreDiscarded() {
        #expect(CPUUsage.between(CPUFixtures.second, CPUFixtures.first) == nil)
        var wrapped = CPUFixtures.second
        wrapped.cores[1].idle = 5  // one counter wrapped past UInt32.max
        #expect(CPUUsage.between(CPUFixtures.first, wrapped) == nil)
    }

    @Test func noElapsedTicksOrACoreCountChangeGiveNoUsage() {
        #expect(CPUUsage.between(CPUFixtures.first, CPUFixtures.first) == nil)
        let oneCore = CPUTicks(cores: [CPUFixtures.second.cores[0]])
        #expect(CPUUsage.between(CPUFixtures.first, oneCore) == nil)
        #expect(CPUUsage.between(CPUTicks(cores: []), CPUTicks(cores: [])) == nil)
    }
}

@Suite struct CPUCollectorTests {
    /// Plays back the given readings, one per call.
    final class Playback: Sendable {
        private let queue: Mutex<[Result<CPUTicks, ProbeError>]>
        init(_ readings: [Result<CPUTicks, ProbeError>]) { queue = Mutex(readings) }
        func next() throws(ProbeError) -> CPUTicks {
            let result = queue.withLock { $0.isEmpty ? .failure(.unreadable("no more fixtures")) : $0.removeFirst() }
            return try result.get()
        }
    }

    @Test func firstSampleHasNoPercentageThenDeltas() async throws {
        let playback = Playback([.success(CPUFixtures.first), .success(CPUFixtures.second)])
        let collector = CPUCollector(read: { () throws(ProbeError) in try playback.next() })
        #expect(try await collector.sample() == nil)
        let usage = try #require(try await collector.sample())
        #expect(usage.total == 110.0 / 380.0)
    }

    @Test func resetMakesTheNextSampleALoadingOne() async throws {
        let playback = Playback([.success(CPUFixtures.first), .success(CPUFixtures.second)])
        let collector = CPUCollector(read: { () throws(ProbeError) in try playback.next() })
        _ = try await collector.sample()
        await collector.reset()
        #expect(try await collector.sample() == nil)
    }

    @Test func backwardsCountersAreDiscardedAndBecomeTheNewBaseline() async throws {
        let later = CPUTicks(
            cores: CPUFixtures.second.cores.map {
                CoreTicks(user: $0.user + 10, system: $0.system, idle: $0.idle + 30, nice: $0.nice)
            })
        let playback = Playback([.success(CPUFixtures.second), .success(CPUFixtures.first), .success(later)])
        let collector = CPUCollector(read: { () throws(ProbeError) in try playback.next() })
        _ = try await collector.sample()
        #expect(try await collector.sample() == nil)
        // Baseline is now `first`: the next delta is computed from it, not from the discarded pair.
        let usage = try #require(try await collector.sample())
        #expect(usage == CPUUsage.between(CPUFixtures.first, later))
    }

    @Test func aMachErrorIsThrownWithItsText() async {
        let playback = Playback([.failure(.unreadable("host_processor_info: (os/kern) failure"))])
        let collector = CPUCollector(read: { () throws(ProbeError) in try playback.next() })
        await #expect(throws: ProbeError.unreadable("host_processor_info: (os/kern) failure")) {
            try await collector.sample()
        }
    }

    @Test func theRealMachReaderReturnsEveryLogicalCore() throws {
        let ticks = try MachCPU.ticks()
        #expect(ticks.cores.count == ProcessInfo.processInfo.processorCount)
    }
}

@Suite struct CPUInfoTests {
    static let appleSilicon = FakeSysctl(
        strings: [
            "machdep.cpu.brand_string": "Apple M4", "hw.perflevel0.name": "Performance",
            "hw.perflevel1.name": "Efficiency",
        ],
        ints: [
            "hw.physicalcpu": 10, "hw.logicalcpu": 10, "hw.nperflevels": 2, "hw.perflevel0.logicalcpu": 4,
            "hw.perflevel1.logicalcpu": 6,
        ])

    @Test func appleSiliconShowsCoresAndTheirSplit() {
        let info = CPUInfo.read(Self.appleSilicon)
        #expect(info.name == "Apple M4")
        #expect(info.pills == ["10 cores", "4P + 6E"])
    }

    @Test func hyperThreadingShowsPhysicalAndLogical() {
        let intel = FakeSysctl(
            strings: ["machdep.cpu.brand_string": "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"],
            ints: ["hw.physicalcpu": 8, "hw.logicalcpu": 16, "hw.nperflevels": 1, "hw.perflevel0.logicalcpu": 16])
        let info = CPUInfo.read(intel)
        #expect(info.pills == ["8 physical cores", "16 logical cores"])
    }

    @Test func missingKeysDropTheirPill() {
        let info = CPUInfo.read(FakeSysctl(ints: ["hw.logicalcpu": 12]))
        #expect(info.name == nil)
        #expect(info.pills == ["12 logical cores"])
        #expect(CPUInfo.read(FakeSysctl()).pills.isEmpty)
    }

    @Test func aSplitWithoutLevelNamesIsOmitted() {
        var sysctl = Self.appleSilicon
        sysctl.strings["hw.perflevel1.name"] = nil
        #expect(CPUInfo.read(sysctl).pills == ["10 cores"])
    }
}

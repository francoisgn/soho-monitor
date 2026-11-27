import Foundation
import Testing

@testable import SohoMonitorCore

/// Page counts shaped like `vm_statistics64` on a 16 GiB Apple silicon Mac (16 KiB pages); values made up.
enum MemoryFixtures {
    static let pageSize: UInt64 = 16_384
    static let total: UInt64 = 17_179_869_184
    static let pages = VMPageCounts(
        free: 20_000, active: 200_000, inactive: 190_000, speculative: 10_000, wired: 100_000, compressed: 50_000,
        purgeable: 5_000, external: 150_000)
    static let swap = SwapUsage(total: 8_589_934_592, used: 7_516_192_768)
}

@Suite struct MemoryReadingTests {
    @Test func usedIsAppWiredAndCompressedAsDocumented() {
        let reading = MemoryReading(
            pages: MemoryFixtures.pages, pageSize: MemoryFixtures.pageSize, total: MemoryFixtures.total,
            swap: nil, pressure: nil)
        // active + inactive + speculative + wired + compressed - purgeable - external
        #expect(reading.used == 395_000 * 16_384)
        #expect(reading.app == 245_000 * 16_384)
        #expect(reading.wired == 100_000 * 16_384)
        #expect(reading.compressed == 50_000 * 16_384)
        #expect(reading.cached == 155_000 * 16_384)
        #expect(reading.total == MemoryFixtures.total)
        #expect(reading.usedFraction == Double(395_000 * 16_384) / Double(MemoryFixtures.total))
    }

    @Test func usedNeverGoesNegativeNorAboveTotal() {
        let odd = VMPageCounts(
            free: 0, active: 1, inactive: 0, speculative: 0, wired: 0, compressed: 0, purgeable: 50, external: 50)
        let reading = MemoryReading(pages: odd, pageSize: 4096, total: 1_000_000, swap: nil, pressure: nil)
        #expect(reading.used == 0)
        #expect(reading.app == 0)
        let huge = VMPageCounts(
            free: 0, active: 1_000, inactive: 0, speculative: 0, wired: 0, compressed: 0, purgeable: 0, external: 0)
        let full = MemoryReading(pages: huge, pageSize: 4096, total: 1_000_000, swap: nil, pressure: nil)
        #expect(full.used == 1_000_000)
        #expect(full.usedFraction == 1)
    }

    @Test func pillsShowUsedOfTotalPressureAndSwap() {
        let reading = MemoryReading(
            pages: MemoryFixtures.pages, pageSize: MemoryFixtures.pageSize, total: MemoryFixtures.total,
            swap: MemoryFixtures.swap, pressure: .warning)
        #expect(reading.usedOfTotal == "6.0 GB of 16.0 GB")
        #expect(reading.swapText == "Swap 7.0 GB")
        #expect(reading.level == .warning)
        #expect(
            reading.breakdown
                == "App 3.7 GB · Wired 1.5 GB · Compressed 781 MB · Cached 2.4 GB")
    }

    @Test func unknownPressureAndMissingSwapAreOmittedNotNormal() {
        let reading = MemoryReading(
            pages: MemoryFixtures.pages, pageSize: MemoryFixtures.pageSize, total: MemoryFixtures.total,
            swap: nil, pressure: nil)
        #expect(reading.swapText == nil)
        #expect(reading.pressure == nil)
        // Without pressure, the level falls back to the used share (37 % here: normal).
        #expect(reading.level == .normal)
    }

    @Test func pressureDrivesTheLevelOverTheUsedShare() {
        let reading = MemoryReading(
            pages: MemoryFixtures.pages, pageSize: MemoryFixtures.pageSize, total: MemoryFixtures.total,
            swap: nil, pressure: .critical)
        #expect(reading.level == .critical)
    }
}

@Suite struct MemoryPressureTests {
    @Test func dispatchLevelsMapToPressure() {
        #expect(MemoryPressure(dispatchLevel: 0x01) == .normal)
        #expect(MemoryPressure(dispatchLevel: 0x02) == .warning)
        #expect(MemoryPressure(dispatchLevel: 0x04) == .critical)
        #expect(MemoryPressure(dispatchLevel: 0) == nil)
        #expect(MemoryPressure(dispatchLevel: 0x08) == nil)
    }

    @Test func labelsNameTheLevel() {
        #expect(MemoryPressure.normal.label == "Pressure normal")
        #expect(MemoryPressure.warning.label == "Pressure warning")
        #expect(MemoryPressure.critical.label == "Pressure critical")
    }

    @Test func shortLabelsFitTheCompactPill() {
        #expect(MemoryPressure.normal.shortLabel == "Normal")
        #expect(MemoryPressure.warning.shortLabel == "Warning")
        #expect(MemoryPressure.critical.shortLabel == "Critical")
    }

    @Test func criticalStaysUntilNormal() {
        var tracker = MemoryPressureTracker(initial: nil)
        #expect(tracker.level == nil)
        tracker.apply(eventMask: 0x04)
        #expect(tracker.level == .critical)
        tracker.apply(eventMask: 0)  // spurious event: no level, nothing changes
        #expect(tracker.level == .critical)
        tracker.apply(eventMask: 0x01)
        #expect(tracker.level == .normal)
    }

    @Test func severalFlagsInOneEventKeepTheMostSevere() {
        var tracker = MemoryPressureTracker(initial: .normal)
        tracker.apply(eventMask: 0x02 | 0x04)
        #expect(tracker.level == .critical)
    }
}

@Suite struct MemoryCollectorTests {
    @Test func samplesPagesTotalSwapAndPressure() async throws {
        let collector = MemoryCollector(
            readPages: { () throws(ProbeError) in (MemoryFixtures.pages, MemoryFixtures.pageSize) },
            total: MemoryFixtures.total, swap: { MemoryFixtures.swap }, pressure: { .normal })
        let reading = try #require(try await collector.sample())
        #expect(reading.used == 395_000 * 16_384)
        #expect(reading.swap == MemoryFixtures.swap)
        #expect(reading.pressure == .normal)
    }

    @Test func aFailedReadIsThrown() async {
        let collector = MemoryCollector(
            readPages: { () throws(ProbeError) in throw .unreadable("host_statistics64: (os/kern) failure") },
            total: MemoryFixtures.total, swap: { nil }, pressure: { nil })
        await #expect(throws: ProbeError.unreadable("host_statistics64: (os/kern) failure")) {
            try await collector.sample()
        }
    }

    @Test func anUnknownTotalIsAnError() async {
        let collector = MemoryCollector(
            readPages: { () throws(ProbeError) in (MemoryFixtures.pages, MemoryFixtures.pageSize) },
            total: nil, swap: { nil }, pressure: { nil })
        await #expect(throws: ProbeError.self) { try await collector.sample() }
    }

    @Test func theRealReadersAnswerOnThisMac() throws {
        let (pages, pageSize) = try MachMemory.pages()
        #expect(pageSize > 0)
        #expect(pages.wired > 0)
        #expect(SystemSysctl().uint64("hw.memsize") == ProcessInfo.processInfo.physicalMemory)
        #expect(MachMemory.swapUsage() != nil)
    }
}

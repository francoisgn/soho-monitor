import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct RingBufferTests {
    @Test func keepsTheLatestCapacityElementsInOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.count == 3)
        #expect(buffer.last == 5)
    }

    @Test func belowCapacityKeepsEverything() {
        var buffer = RingBuffer<Int>(capacity: 4)
        #expect(buffer.isEmpty)
        #expect(buffer.elements.isEmpty)
        buffer.append(7)
        buffer.append(8)
        #expect(buffer.elements == [7, 8])
    }

    @Test func wrapsSeveralTimes() {
        var buffer = RingBuffer<Int>(capacity: 2)
        for value in 0..<11 { buffer.append(value) }
        #expect(buffer.elements == [9, 10])
    }

    @Test func capacityIsAtLeastOne() {
        var buffer = RingBuffer<Int>(capacity: 0)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.capacity == 1)
        #expect(buffer.elements == [2])
    }
}

@Suite struct MetricLevelTests {
    static let cases: [(Double?, MetricLevel)] = [
        (0.0, .normal),
        (0.69, .normal),
        (0.7, .warning),
        (0.89, .warning),
        (0.9, .critical),
        (1.5, .critical),
        (nil, .normal),
        (Double.nan, .normal),
    ]

    @Test(arguments: cases)
    func thresholdsPickTheLevel(fraction: Double?, expected: MetricLevel) {
        #expect(MetricLevel(fraction: fraction, warning: 0.7, critical: 0.9) == expected)
    }
}

@Suite struct MetricFractionTests {
    @Test func clampsOutOfRangeAndRejectsNonFiniteValues() {
        #expect(MetricFraction.clamped(0.42) == 0.42)
        #expect(MetricFraction.clamped(-0.2) == 0)
        #expect(MetricFraction.clamped(1.7) == 1)
        #expect(MetricFraction.clamped(.nan) == nil)
        #expect(MetricFraction.clamped(.infinity) == nil)
    }
}

@Suite struct PercentFormatTests {
    static let cases: [(Double?, String)] = [
        (0.0, "0%"),
        (0.004, "0%"),
        (0.234, "23%"),
        (0.235, "24%"),
        (1.0, "100%"),
        (1.3, "100%"),
        (-0.1, "0%"),
        (nil, "—"),
        (Double.nan, "—"),
    ]

    @Test(arguments: cases)
    func wholePercentOrDash(fraction: Double?, expected: String) {
        #expect(PercentFormat.whole(fraction) == expected)
    }
}

@Suite struct MemoryFormatTests {
    static let cases: [(UInt64, String)] = [
        (0, "0 MB"),
        (536_870_912, "512 MB"),
        (1_072_693_248, "1023 MB"),
        (1_073_217_536, "1.0 GB"),
        (1_073_741_824, "1.0 GB"),
        (7_541_686_272, "7.0 GB"),
        (17_179_869_184, "16.0 GB"),
        (137_438_953_472, "128 GB"),
    ]

    @Test(arguments: cases)
    func binaryUnitsSoA16GiBMacReads16GB(bytes: UInt64, expected: String) {
        #expect(MemoryFormat.short(bytes) == expected)
    }
}

@Suite struct SparklineScaleTests {
    @Test func unitDomainClampsAndKeepsValues() {
        #expect(SparklineScale.normalized([0, 0.5, 1.2, -1, .nan], domain: .unit) == [0, 0.5, 1, 0, 0])
    }

    @Test func autoDomainStretchesMinToMax() {
        #expect(SparklineScale.normalized([2, 4, 6], domain: .auto) == [0, 0.5, 1])
    }

    @Test func emptySingleAndFlatHistoriesDoNotCrash() {
        #expect(SparklineScale.normalized([], domain: .auto).isEmpty)
        #expect(SparklineScale.normalized([3], domain: .auto) == [0.5])
        #expect(SparklineScale.normalized([3, 3, 3], domain: .auto) == [0.5, 0.5, 0.5])
        #expect(SparklineScale.normalized([0.3], domain: .unit) == [0.3])
    }
}

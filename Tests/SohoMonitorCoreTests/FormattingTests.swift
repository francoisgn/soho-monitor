import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct ByteFormatTests {
    static let cases: [(Int64, String)] = [
        (0, "0 MB"),
        (-5, "0 MB"),
        (1_478_656, "1 MB"),
        (730_505_216, "731 MB"),
        (999_499_999, "999 MB"),
        (999_500_000, "1.0 GB"),
        (1_000_000_000, "1.0 GB"),
        (27_643_658_240, "27.6 GB"),
        (183_916_957_696, "183.9 GB"),
        (999_949_999_999, "999.9 GB"),
        (999_950_000_000, "1.00 TB"),
        (1_234_567_890_123, "1.23 TB"),
    ]

    @Test(arguments: cases)
    func decimalUnitsLikeFinder(bytes: Int64, expected: String) {
        #expect(ByteFormat.short(bytes) == expected)
    }
}

@Suite struct RelativeAgeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let cases: [(Double, String)] = [
        (0.0, "just now"),
        (29.0, "just now"),
        (90.0, "2 min ago"),
        (59.0 * 60, "59 min ago"),
        (61.0 * 60, "1 h ago"),
        (23.0 * 3600, "23 h ago"),
        (49.0 * 3600, "2 d ago"),
        (-120.0, "just now"),
    ]

    @Test(arguments: cases)
    func agesAreShortAndRounded(secondsAgo: Double, expected: String) {
        #expect(RelativeAge.string(from: now.addingTimeInterval(-secondsAgo), now: now) == expected)
    }
}

@Suite struct PathDisplayTests {
    @Test func homeIsAbbreviated() {
        #expect(PathDisplay.abbreviated("/Users/me/Git/x", home: "/Users/me") == "~/Git/x")
        #expect(PathDisplay.abbreviated("/Users/me", home: "/Users/me") == "~")
        #expect(PathDisplay.abbreviated("/Users/meta/x", home: "/Users/me") == "/Users/meta/x")
        #expect(PathDisplay.abbreviated("/Applications/Xcode.app", home: "/Users/me") == "/Applications/Xcode.app")
    }

    @Test func tildeIsExpanded() {
        #expect(PathDisplay.expandingTilde("~", home: "/Users/me") == "/Users/me")
        #expect(PathDisplay.expandingTilde("~/Git", home: "/Users/me") == "/Users/me/Git")
        #expect(PathDisplay.expandingTilde("~other/Git", home: "/Users/me") == "~other/Git")
        #expect(PathDisplay.expandingTilde("/opt/homebrew/", home: "/Users/me") == "/opt/homebrew")
        #expect(PathDisplay.expandingTilde("/", home: "/Users/me") == "/")
    }
}

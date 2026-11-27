import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct MacOSVersionTests {
    @Test func versionAndBuild() {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        #expect(MacOSVersion.display(version, build: "25C56") == "macOS 26.2 (25C56)")
    }

    @Test func aPatchVersionIsShownOnlyWhenNotZero() {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 1)
        #expect(MacOSVersion.display(version, build: "25C101") == "macOS 26.2.1 (25C101)")
    }

    @Test func withoutABuildOnlyTheVersion() {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        #expect(MacOSVersion.display(version, build: nil) == "macOS 26.0")
        #expect(MacOSVersion.display(version, build: "  ") == "macOS 26.0")
    }

    @Test func theBuildComesFromKernOsversion() {
        let sysctl = FakeSysctl(strings: ["kern.osversion": "25C56"])
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        #expect(MacOSVersion.current(version: version, sysctl: sysctl) == "macOS 26.2 (25C56)")
        #expect(MacOSVersion.current(version: version, sysctl: FakeSysctl()) == "macOS 26.2")
    }
}

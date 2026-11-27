import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct SynologyConfigTests {
    private static let disk = """
        disk:
          categories:
            - group: Apps
              paths: [/Applications]

        """

    private func parse(_ synology: String) throws(ConfigError) -> ConfigLoadResult {
        try ConfigParser.parse(Self.disk + synology, home: "/Users/me", directoryExists: { _ in true })
    }

    private func issues(_ synology: String) -> [ConfigIssue] {
        do {
            _ = try parse(synology)
            return []
        } catch {
            return error.issues
        }
    }

    @Test func noSectionLeavesTheModuleOff() throws {
        #expect(try parse("").config.synology == nil)
    }

    @Test func minimalSectionGetsDefaults() throws {
        let result = try parse(
            """
            synology:
              host: nas.example.test
              user: <user>
            """)
        #expect(result.warnings.isEmpty)
        let config = try #require(result.config.synology)
        #expect(config.host == "nas.example.test")
        #expect(config.port == 5001)
        #expect(config.user == "<user>")
        #expect(config.keychainItem == "synology")
        #expect(config.tls == .systemTrust)
        #expect(config.intervalSeconds == 60)
        #expect(config.baseURL.absoluteString == "https://nas.example.test:5001")
    }

    @Test func everyKeyIsRead() throws {
        let result = try parse(
            """
            synology:
              host: 192.0.2.10
              port: 5443
              user: monitor
              keychain_item: nas-home
              interval_seconds: 300
              tls:
                pin_sha256: "\(TestCertificates.validFingerprint.lowercased())"
            """)
        let config = try #require(result.config.synology)
        #expect(config.port == 5443)
        #expect(config.keychainItem == "nas-home")
        #expect(config.intervalSeconds == 300)
        #expect(config.tls == .pinned(try #require(CertificateFingerprint(TestCertificates.validFingerprint))))
        #expect(config.baseURL.absoluteString == "https://192.0.2.10:5443")
    }

    @Test func allowSelfSignedIsAnExplicitOptOut() throws {
        let on = try parse("synology:\n  host: h.test\n  user: u\n  tls:\n    allow_self_signed: true\n")
        #expect(on.config.synology?.tls == .allowSelfSigned)
        let off = try parse("synology:\n  host: h.test\n  user: u\n  tls:\n    allow_self_signed: false\n")
        #expect(off.config.synology?.tls == .systemTrust)
    }

    @Test func reportsEverySynologyErrorWithItsLine() {
        let found = issues(
            """
            synology:
              host: https://nas.example.test/
              port: 70000
              user: ""
              keychain_item: ""
              interval_seconds: 30
              tls:
                pin_sha256: "AB:CD"
            """)
        #expect(
            found.map(\.keyPath) == [
                "synology.host", "synology.port", "synology.user", "synology.keychain_item",
                "synology.interval_seconds", "synology.tls.pin_sha256",
            ])
        #expect(found.map(\.line) == [6, 7, 8, 9, 10, 12])
        #expect(found[0].message.contains("host name or IP address"))
        #expect(found[4].message.contains("at least 60"))
        #expect(found[5].message.contains("64 hexadecimal digits"))
    }

    @Test func hostAndUserAreRequired() {
        let found = issues("synology:\n  port: 5001\n")
        #expect(found.map(\.keyPath) == ["synology.host", "synology.user"])
    }

    @Test func anEmptyTLSSectionIsSystemTrust() throws {
        let result = try parse("synology:\n  host: h.test\n  user: u\n  tls:\n")
        #expect(result.config.synology?.tls == .systemTrust)
    }

    @Test func pinAndOptOutTogetherIsAnError() {
        let found = issues(
            """
            synology:
              host: h.test
              user: u
              tls:
                pin_sha256: "\(TestCertificates.validFingerprint)"
                allow_self_signed: true
            """)
        #expect(found.map(\.keyPath) == ["synology.tls"])
        #expect(found[0].message.contains("not both"))
    }

    @Test func aPasswordInTheFileIsRefused() {
        let found = issues("synology:\n  host: h.test\n  user: u\n  password: hunter2\n")
        #expect(found.map(\.keyPath) == ["synology.password"])
        #expect(found[0].message.contains("Keychain"))
        // The value itself never ends up in a message.
        #expect(!found[0].message.contains("hunter2"))
    }

    @Test func unknownKeysAreWarnings() throws {
        let result = try parse("synology:\n  host: h.test\n  user: u\n  colour: blue\n  tls:\n    verify: no\n")
        #expect(result.warnings.map(\.keyPath) == ["synology.colour", "synology.tls.verify"])
    }

    @Test func cardKeysDefaultToEverySectionAndASixHourUpdateCheck() throws {
        let config = try #require(try parse("synology:\n  host: h.test\n  user: u\n").config.synology)
        #expect(config.sections == Set(NASSectionKind.allCases))
        #expect(config.expectedStopped.isEmpty)
        #expect(config.updateIntervalHours == 6)
    }

    @Test func cardKeysAreRead() throws {
        let result = try parse(
            """
            synology:
              host: h.test
              user: u
              sections: [storage, docker]
              expected_stopped: [backup-job, " tools "]
              update_interval_hours: 24
            """)
        #expect(result.warnings.isEmpty)
        let config = try #require(result.config.synology)
        #expect(config.sections == [.storage, .docker])
        #expect(config.expectedStopped == ["backup-job", "tools"])
        #expect(config.updateIntervalHours == 24)
    }

    @Test func malformedCardKeysAreErrors() {
        let found = issues(
            """
            synology:
              host: h.test
              user: u
              sections: [storage, gpu]
              expected_stopped: name
              update_interval_hours: 0
            """)
        #expect(
            found.map(\.keyPath) == [
                "synology.sections[1]", "synology.expected_stopped", "synology.update_interval_hours",
            ])
        #expect(found[0].message.contains("storage, system, update, docker"))
        #expect(found[2].message.contains("at least 1"))
        #expect(
            issues("synology:\n  host: h.test\n  user: u\n  sections: []\n").map(\.keyPath) == ["synology.sections"])
    }

    @Test func intervalBelowTheFloorIsRefused() {
        #expect(
            issues("synology:\n  host: h.test\n  user: u\n  interval_seconds: 10\n").map(\.keyPath) == [
                "synology.interval_seconds"
            ])
    }
}

@Suite struct CertificateFingerprintTests {
    @Test func parsesTheUsualSpellings() throws {
        let colons = try #require(CertificateFingerprint(TestCertificates.validFingerprint))
        let bare = CertificateFingerprint(TestCertificates.validFingerprint.replacingOccurrences(of: ":", with: ""))
        let spaced = CertificateFingerprint(
            TestCertificates.validFingerprint.lowercased().replacingOccurrences(of: ":", with: " "))
        #expect(bare == colons)
        #expect(spaced == colons)
        #expect(colons.description == TestCertificates.validFingerprint)
    }

    @Test func refusesMalformedValues() {
        #expect(CertificateFingerprint("") == nil)
        #expect(CertificateFingerprint("AB:CD") == nil)
        #expect(CertificateFingerprint(String(repeating: "G", count: 64)) == nil)
        #expect(CertificateFingerprint(TestCertificates.validFingerprint + ":00") == nil)
    }

    @Test func hashesTheDEROfTheLeaf() {
        #expect(
            CertificateFingerprint(sha256Of: TestCertificates.valid).description == TestCertificates.validFingerprint)
        #expect(
            CertificateFingerprint(sha256Of: TestCertificates.expired).description
                == TestCertificates.expiredFingerprint)
        #expect(
            CertificateFingerprint(sha256Of: TestCertificates.other).description == TestCertificates.otherFingerprint)
    }
}

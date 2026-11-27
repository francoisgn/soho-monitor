import Foundation
import Testing

@testable import SohoMonitorCore

/// Fixtures shaped like `diskutil info -plist /`, `diskutil apfs list -plist <container>` and
/// `xcrun simctl runtime list -j` on macOS 26 (keys checked on a real Mac; values made up).
enum SystemFixtures {
    static let diskutilInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>APFSContainerFree</key><integer>183916957696</integer>
          <key>APFSContainerReference</key><string>disk3</string>
          <key>APFSContainerSize</key><integer>494384795648</integer>
          <key>DeviceIdentifier</key><string>disk3s1s1</string>
          <key>VolumeName</key><string>Macintosh HD</string>
        </dict></plist>
        """

    static let apfsList = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Containers</key><array><dict>
          <key>ContainerReference</key><string>disk3</string>
          <key>Volumes</key><array>
            <dict><key>Name</key><string>Macintosh HD</string><key>Roles</key><array><string>System</string></array>
              <key>CapacityInUse</key><integer>19000000000</integer></dict>
            <dict><key>Name</key><string>Preboot</string><key>Roles</key><array><string>Preboot</string></array>
              <key>CapacityInUse</key><integer>20000000000</integer></dict>
            <dict><key>Name</key><string>Recovery</string><key>Roles</key><array><string>Recovery</string></array>
              <key>CapacityInUse</key><integer>3000000000</integer></dict>
            <dict><key>Name</key><string>Data</string><key>Roles</key><array><string>Data</string></array>
              <key>CapacityInUse</key><integer>250000000000</integer></dict>
            <dict><key>Name</key><string>VM</string><key>Roles</key><array><string>VM</string></array>
              <key>CapacityInUse</key><integer>6000000000</integer></dict>
          </array>
        </dict></array></dict></plist>
        """

    static let simctlRuntimes = """
        {
          "2B02F7A4-0000-0000-0000-000000000001" : { "kind" : "Disk Image", "sizeBytes" : 8315434484, "state" : "Ready" },
          "5BCD7338-0000-0000-0000-000000000002" : { "kind" : "Disk Image", "sizeBytes" : 8338867041, "state" : "Ready" },
          "AAAA0000-0000-0000-0000-000000000003" : { "kind" : "Bundled with Xcode", "state" : "Ready" }
        }
        """
}

@Suite struct SystemProbeTests {
    @Test func volumeInfoFromDiskutilInfo() throws {
        let info = try SystemProbeParser.volume(fromInfoPlist: Data(SystemFixtures.diskutilInfo.utf8))
        #expect(
            info
                == VolumeInfo(
                    name: "Macintosh HD", total: 494_384_795_648, free: 183_916_957_696, containerReference: "disk3"))
    }

    @Test func volumeInfoRejectsAPlistWithoutContainerFigures() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>VolumeName</key><string>USB</string></dict></plist>
            """
        #expect(throws: ProbeError.self) { try SystemProbeParser.volume(fromInfoPlist: Data(plist.utf8)) }
        #expect(throws: ProbeError.self) { try SystemProbeParser.volume(fromInfoPlist: Data("not a plist".utf8)) }
    }

    @Test func macOSIsEveryVolumeOfTheContainerButData() throws {
        let bytes = try SystemProbeParser.macOSBytes(fromApfsListPlist: Data(SystemFixtures.apfsList.utf8))
        #expect(bytes == 19_000_000_000 + 20_000_000_000 + 3_000_000_000 + 6_000_000_000)
    }

    @Test func runtimesAddUpTheirSizes() throws {
        let bytes = try SystemProbeParser.runtimeBytes(fromSimctlJSON: Data(SystemFixtures.simctlRuntimes.utf8))
        #expect(bytes == 8_315_434_484 + 8_338_867_041)
        #expect(try SystemProbeParser.runtimeBytes(fromSimctlJSON: Data("{}".utf8)) == 0)
        #expect(throws: ProbeError.self) { try SystemProbeParser.runtimeBytes(fromSimctlJSON: Data("[1]".utf8)) }
    }
}

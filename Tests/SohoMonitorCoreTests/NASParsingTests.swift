import Foundation
import Testing

@testable import SohoMonitorCore

/// Anonymised responses of a real DS416play (DSM 7.1.1), recorded on 2026-11-27: identifying values replaced, Docker
/// command lines and health-check output dropped (`Fixtures/Synology`).
enum NASFixtures {
    static func text(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Synology"))
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    static func data(_ name: String) throws -> Data { Data(try text(name).utf8) }

    static let storage = "storage-load-info-v1"
    static let info = "core-system-info-v1"
    static let utilization = "core-system-utilization-get-v1"
    static let upgrade = "core-upgrade-server-check-v1"
    static let docker = "docker-container-list-v1-paged"

    /// The fixture with one textual replacement, for the states the device did not show (L27: derived from a real
    /// response, never written from scratch). The replaced text must occur.
    static func data(_ name: String, replacing old: String, with new: String) throws -> Data {
        let text = try text(name)
        try #require(text.contains(old), "\(old) not in \(name)")
        return Data(text.replacingOccurrences(of: old, with: new).utf8)
    }
}

@Suite struct NASStorageTests {
    @Test func volumeUsageAndHealthComeFromLoadInfo() throws {
        let storage = try NASStorage.decode(NASFixtures.data(NASFixtures.storage))
        let volume = try #require(storage.volumes.first)
        #expect(storage.volumes.count == 1)
        #expect(volume.name == "volume1")
        #expect(volume.total == 7_670_124_396_544)
        #expect(volume.used == 6_877_561_569_280)
        #expect(abs((volume.usedFraction ?? 0) - 6_877_561_569_280 / 7_670_124_396_544) < 1e-9)
        // The recorded NAS is almost full: DSM itself flags the volume and its pool.
        #expect(volume.health == .attention)
        #expect(volume.detail == "fs_almost_full")
        #expect(volume.free == 7_670_124_396_544 - 6_877_561_569_280)
    }

    @Test func freeSpaceNeedsBothSizesAndNeverGoesNegative() {
        func volume(total: UInt64?, used: UInt64?) -> NASVolume {
            NASVolume(name: "v", total: total, used: used, health: .normal, detail: nil)
        }
        #expect(volume(total: 100, used: 30).free == 70)
        #expect(volume(total: 100, used: nil).free == nil)
        #expect(volume(total: nil, used: 30).free == nil)
        // A used size above the total (DSM counts reserved space differently): nothing free, not a wrap-around.
        #expect(volume(total: 100, used: 130).free == 0)
    }

    @Test func poolsAndDisksKeepTheirStatus() throws {
        let storage = try NASStorage.decode(NASFixtures.data(NASFixtures.storage))
        #expect(storage.pools.map(\.name) == ["SHR"])
        #expect(storage.pools.first?.health == .attention)
        #expect(storage.disks.map(\.name) == ["Drive 1", "Drive 2", "Drive 3", "Drive 4"])
        #expect(storage.disks.allSatisfy { $0.health == .normal })
        #expect(storage.disks.map(\.temperature) == [38, 41, 40, 41])
    }

    @Test func worstHealthNamesThePoolOrDisk() throws {
        let storage = try NASStorage.decode(NASFixtures.data(NASFixtures.storage))
        #expect(storage.hardware == NASHealthSummary(health: .attention, subject: "Pool SHR"))
        // A degraded pool (derived from the recording: the state the device did not show) wins over attention.
        let degraded = try NASStorage.decode(
            NASFixtures.data(
                NASFixtures.storage, replacing: #""status":"attention","suggestions":[{"arg""#,
                with: #""status":"degraded","suggestions":[{"arg""#))
        #expect(degraded.pools.first?.health == .degraded)
        #expect(degraded.hardware == NASHealthSummary(health: .degraded, subject: "Pool SHR"))
        #expect(degraded.hardware.health.level == .critical)
    }

    @Test func aFailingDiskIsNamed() throws {
        let failing = try NASStorage.decode(
            NASFixtures.data(
                NASFixtures.storage, replacing: #""smart_testing":true,"status":"normal""#,
                with: #""smart_testing":true,"status":"crashed""#))
        #expect(failing.disks[1].health == .crashed)
        #expect(failing.hardware == NASHealthSummary(health: .crashed, subject: "Drive 2"))
    }

    @Test func healthyHardwareHasNoSubject() throws {
        let healthy = try NASStorage.decode(
            NASFixtures.data(
                NASFixtures.storage, replacing: #""status":"attention","suggestions":[{"arg""#,
                with: #""status":"normal","suggestions":[{"arg""#))
        #expect(healthy.hardware == NASHealthSummary(health: .normal, subject: nil))
    }

    @Test(arguments: [
        ("normal", NASHealth.normal), ("Normal", .normal), ("attention", .attention), ("degraded", .degraded),
        ("crashed", .crashed), ("repairing", .unknown("repairing")), ("", .unknown("")),
    ])
    func statusStrings(_ text: String, _ expected: NASHealth) {
        #expect(NASHealth(dsm: text) == expected)
    }

    @Test func unknownStatusIsShownVerbatimAndNeverGreen() {
        #expect(NASHealth.unknown("repairing").label == "repairing")
        #expect(NASHealth.unknown("").label == "unknown")
        #expect(NASHealth.unknown("repairing").level == .warning)
        #expect(NASHealth.normal.level == .normal)
        #expect(NASHealth.crashed.level == .critical)
    }

    @Test func missingOptionalFieldsAreOmitted() throws {
        let body = #"{"data":{"volumes":[{"id":"volume_1"}],"disks":[{"id":"sda"}]},"success":true}"#
        let storage = try NASStorage.decode(Data(body.utf8))
        #expect(storage.volumes.first?.name == "volume_1")
        #expect(storage.volumes.first?.usedFraction == nil)
        #expect(storage.volumes.first?.health == .unknown(""))
        #expect(storage.pools.isEmpty)
        #expect(storage.disks.first?.name == "sda")
        #expect(storage.disks.first?.temperature == nil)
        #expect(storage.volumes.first?.free == nil)
    }

    @Test func sizesAsNumbersAreAcceptedToo() throws {
        let body =
            #"{"data":{"volumes":[{"id":"v","vol_path":"/volume2","size":{"total":200,"used":"50"}}]},"success":true}"#
        let volume = try #require(try NASStorage.decode(Data(body.utf8)).volumes.first)
        #expect(volume.name == "volume2")
        #expect(volume.usedFraction == 0.25)
    }

    @Test func notTheEnvelopeIsAnError() {
        #expect(throws: DSMError.self) { try NASStorage.decode(Data("[]".utf8)) }
    }
}

@Suite struct NASSystemTests {
    @Test func utilizationGivesCPUMemoryAndDiskActivity() throws {
        let system = try NASSystem.decode(utilization: NASFixtures.data(NASFixtures.utilization), info: nil)
        // CPU: user 13 + system 22 + other 44, as py-synologydsm-api's `cpu_total_load` adds them.
        #expect(system.cpu == 0.79)
        #expect(system.memory == 0.31)  // `memory.real_usage`
        #expect(system.diskActivity == 0.59)  // `disk.total.utilization`
        #expect(system.temperature == nil)
        #expect(system.uptime == nil)
    }

    @Test func infoAddsModelVersionTemperatureAndUptime() throws {
        let system = try NASSystem.decode(
            utilization: NASFixtures.data(NASFixtures.utilization), info: NASFixtures.data(NASFixtures.info))
        #expect(system.model == "DS416play")
        #expect(system.dsmVersion == "DSM 7.1.1-42962 Update 9")
        #expect(system.temperature == 54)
        #expect(system.temperatureWarning == false)
        #expect(system.uptime == TimeInterval(1856 * 3600 + 6 * 60 + 43))
    }

    @Test func temperatureWarningFlagIsRead() throws {
        let hot = try NASFixtures.data(
            NASFixtures.info, replacing: #""temperature_warning":false"#, with: #""temperature_warning":true"#)
        let system = try NASSystem.decode(utilization: NASFixtures.data(NASFixtures.utilization), info: hot)
        #expect(system.temperatureWarning)
    }

    @Test func missingFieldsAreOmitted() throws {
        let system = try NASSystem.decode(
            utilization: Data(#"{"data":{"cpu":{"user_load":5}},"success":true}"#.utf8), info: nil)
        #expect(system.cpu == nil)  // a partial sum would understate the load
        #expect(system.memory == nil)
        #expect(system.diskActivity == nil)
    }

    @Test(arguments: [
        ("1856:6:43", 6_682_003.0), ("0:0:5", 5.0), ("12:30:00", 45_000.0), ("bogus", -1), ("1:2", -1), ("1:61:0", -1),
    ])
    func uptimeIsHoursMinutesSeconds(_ text: String, _ seconds: Double) {
        #expect(NASSystem.uptime(text) == (seconds < 0 ? nil : seconds))
    }

    @Test(arguments: [
        (6_682_003.0, "77 d 8 h"), (86_400.0, "1 d 0 h"), (45_000.0, "12 h 30 min"), (59.0, "< 1 min"),
        (600.0, "10 min"),
    ])
    func uptimeFormat(_ seconds: Double, _ text: String) {
        #expect(NASFormat.uptime(seconds) == text)
    }
}

@Suite struct NASUpdateTests {
    @Test func availableUpdateShowsItsVersion() throws {
        let update = try NASUpdate.decode(NASFixtures.data(NASFixtures.upgrade))
        #expect(update == NASUpdate(available: true, version: "DSM 7.2.2-72806 Update 11"))
        #expect(update.badge == "DSM 7.2.2-72806 Update 11")
    }

    @Test func upToDateHasNoBadge() throws {
        let update = try NASUpdate.decode(
            NASFixtures.data(NASFixtures.upgrade, replacing: #""available":true"#, with: #""available":false"#))
        #expect(!update.available)
        #expect(update.badge == nil)
    }

    @Test func availableWithoutVersionStillSaysSo() throws {
        let update = try NASUpdate.decode(Data(#"{"data":{"available":true},"success":true}"#.utf8))
        #expect(update.badge == "update available")
    }
}

@Suite struct NASContainerTests {
    @Test func listGivesNamesAndStates() throws {
        let list = try NASContainerList.decode(NASFixtures.data(NASFixtures.docker), expectedStopped: [])
        #expect(list.total == 6)
        #expect(list.containers.count == 6)
        #expect(list.containers.map(\.name) == ["app-1", "app-2", "app-3", "app-4", "app-5", "app-6"])
        #expect(list.containers.allSatisfy { $0.state == .running })
        #expect(list.containers.first?.image == "example/app-1:latest")
        #expect(list.running == 6)
    }

    @Test func unhealthyAndStoppedComeFirstAndAreFlagged() throws {
        var text = try NASFixtures.text(NASFixtures.docker)
        // app-1 turns unhealthy, app-3 exits with an error, app-4 exits cleanly: states the device did not show.
        try #require(text.contains(#""Status":"healthy"},"OOMKilled""#))
        text = text.replacingOccurrences(
            of: #""Status":"healthy"},"OOMKilled""#, with: #""Status":"unhealthy"},"OOMKilled""#, options: [],
            range: text.range(of: #""Status":"healthy"},"OOMKilled""#))
        text = try Self.stop("app-3", exitCode: 137, in: text)
        text = try Self.stop("app-4", exitCode: 0, in: text)
        let list = try NASContainerList.decode(Data(text.utf8), expectedStopped: [])
        #expect(list.containers.map(\.name) == ["app-1", "app-3", "app-4", "app-2", "app-5", "app-6"])
        #expect(list.containers[0].state == .unhealthy)
        #expect(list.containers[1].state == .stopped(exitCode: 137))
        #expect(list.containers[1].level == .critical)
        #expect(list.containers[2].state == .stopped(exitCode: 0))
        #expect(list.containers[2].level == .warning)
        #expect(list.running == 4)  // unhealthy still runs
        // Expected to be stopped: no longer flagged, sorted with the healthy ones.
        let expected = try NASContainerList.decode(Data(text.utf8), expectedStopped: ["app-4"])
        #expect(expected.containers.first { $0.name == "app-4" }?.level == .normal)
        #expect(expected.containers.map(\.name) == ["app-1", "app-3", "app-2", "app-4", "app-5", "app-6"])
    }

    /// Rewrites one container's state block as Docker reports an exited one.
    private static func stop(_ name: String, exitCode: Int, in text: String) throws -> String {
        var json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var data = try #require(json["data"] as? [String: Any])
        var containers = try #require(data["containers"] as? [[String: Any]])
        let index = try #require(containers.firstIndex { $0["name"] as? String == name })
        var state = try #require(containers[index]["State"] as? [String: Any])
        state["Status"] = "exited"
        state["Running"] = false
        state["ExitCode"] = exitCode
        state["Health"] = nil
        containers[index]["State"] = state
        data["containers"] = containers
        json["data"] = data
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    @Test(arguments: [
        ("running", nil, NASContainerState.running), ("running", "healthy", .running),
        ("running", "starting", .running),
        ("running", "unhealthy", .unhealthy), ("restarting", nil, .restarting), ("paused", nil, .paused),
        ("exited", nil, .stopped(exitCode: 2)), ("created", nil, .stopped(exitCode: 2)), ("dead", nil, .other("dead")),
        ("weird", nil, .other("weird")),
    ])
    func dockerStates(_ status: String, _ health: String?, _ expected: NASContainerState) {
        #expect(NASContainerState(status: status, health: health, exitCode: 2) == expected)
    }

    @Test func secretsAreNeverDecoded() throws {
        // `cmd`, `env`, mounts and labels are not part of the model: a list carrying them decodes the same.
        let body = #"""
            {"data":{"containers":[{"name":"db","image":"example/db:1","status":"running","cmd":"--password=x",
            "env":["SECRET=x"],"State":{"Status":"running","Running":true,"ExitCode":0}}],"limit":1,"offset":0,
            "total":1},"success":true}
            """#
        let list = try NASContainerList.decode(Data(body.utf8), expectedStopped: [])
        #expect(
            list.containers == [
                NASContainer(name: "db", image: "example/db:1", state: .running, expectedStopped: false)
            ])
        #expect(!String(describing: list).contains("SECRET"))
        #expect(!String(describing: list).contains("password"))
    }

    @Test func statusFallsBackToTheTopLevelField() throws {
        let body = #"{"data":{"containers":[{"name":"a","status":"exited"}],"total":1},"success":true}"#
        let list = try NASContainerList.decode(Data(body.utf8), expectedStopped: [])
        #expect(list.containers.first?.state == .stopped(exitCode: nil))
    }
}

@Suite struct NASDisplayTests {
    @Test func loadLevelsUseTheMacCardsThresholds() {
        let system = NASSystem(cpu: 0.92, memory: 0.86, diskActivity: 0.5)
        #expect(system.cpuLevel == .critical)  // CPU card: 70 % / 90 %
        #expect(system.memoryLevel == .warning)  // memory card: 85 % / 95 %
        #expect(system.diskActivityLevel == .normal)  // as CPU
        #expect(NASSystem().cpuLevel == .normal)
    }

    @Test(arguments: [
        ("DSM 7.1.1-42962 Update 9", "DSM 7.1.1"), ("DSM 7.2.2-72806 Update 11", "DSM 7.2.2"), ("DSM 7.2", "DSM 7.2"),
    ])
    func shortVersion(_ full: String, _ short: String) {
        #expect(NASFormat.shortVersion(full) == short)
    }

    @Test func volumeStatusText() {
        var volume = NASVolume(name: "volume1", total: 10, used: 9, health: .attention, detail: "fs_almost_full")
        #expect(volume.statusText == "almost full")
        volume.detail = "something_internal"
        #expect(volume.statusText == "Attention")  // internal codes stay in the tooltip
        volume.health = .normal
        #expect(volume.statusText == "Healthy")
    }
}

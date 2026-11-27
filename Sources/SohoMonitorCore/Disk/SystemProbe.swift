import Foundation
import Synchronization

/// A system command or its output could not be used.
public enum ProbeError: Error, Sendable, Equatable, CustomStringConvertible {
    case commandFailed(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .commandFailed(let message), .unreadable(let message): message
        }
    }
}

/// Output of a finished command.
public struct CommandOutput: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var status: Int32

    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

/// Runs a command to completion. Injected so that tests play back canned outputs and never touch the disk.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandOutput
}

/// Runs commands with `Process` at background quality of service, the lowest class: the child gets the lowest CPU
/// priority and its I/O may be throttled (Apple, Energy Efficiency Guide for Mac Apps, "Prioritize Work with Quality
/// of Service Classes"), so a long `du` pass does not slow down the user's work.
public struct ProcessRunner: CommandRunning {
    public init() {}

    /// Stops every command still running (called when the app quits: a child `du` would otherwise outlive it).
    public static func terminateRunning() {
        for process in RunningProcesses.shared.all() where process.isRunning { process.terminate() }
    }

    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.qualityOfService = .background
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let cancelled = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Both pipes are drained on their own threads: a full stderr pipe would otherwise block `du`.
                DispatchQueue.global(qos: .background).async {
                    do {
                        try process.run()
                        RunningProcesses.shared.insert(process)
                        // Cancelled before the process existed: onCancel found nothing to stop.
                        if cancelled.isSet { process.terminate() }
                    } catch {
                        continuation.resume(throwing: ProbeError.commandFailed("cannot run \(executable): \(error)"))
                        return
                    }
                    let stderr = ReadBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .background).async {
                        stderr.data = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let stdout = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    RunningProcesses.shared.remove(process)
                    continuation.resume(
                        returning: CommandOutput(stdout: stdout, stderr: stderr.data, status: process.terminationStatus)
                    )
                }
            }
        } onCancel: {
            cancelled.set()
            if process.isRunning { process.terminate() }
        }
    }
}

/// A one-way flag shared between the cancellation handler and the thread that starts the process.
private final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

/// Processes started by `ProcessRunner` and not yet finished.
private final class RunningProcesses: @unchecked Sendable {
    static let shared = RunningProcesses()
    private let lock = NSLock()
    private var byID: [ObjectIdentifier: Process] = [:]

    func insert(_ process: Process) {
        lock.withLock { byID[ObjectIdentifier(process)] = process }
    }

    func remove(_ process: Process) {
        lock.withLock { byID[ObjectIdentifier(process)] = nil }
    }

    func all() -> [Process] {
        lock.withLock { Array(byID.values) }
    }
}

/// Holds the bytes read on the stderr thread until the stdout thread has finished (`DispatchGroup.wait` orders them).
private final class ReadBox: @unchecked Sendable {
    var data = Data()
}

/// Parsers of `diskutil` and `simctl` outputs.
public enum SystemProbeParser {
    /// `diskutil info -plist /`: volume name, APFS container size and free space, container reference.
    public static func volume(fromInfoPlist data: Data) throws(ProbeError) -> VolumeInfo {
        guard let dict = plistDictionary(data),
            let total = int64(dict["APFSContainerSize"]), let free = int64(dict["APFSContainerFree"]),
            let reference = dict["APFSContainerReference"] as? String
        else {
            throw .unreadable("diskutil info: no APFS container figures for /")
        }
        let name = (dict["VolumeName"] as? String) ?? "Startup disk"
        return VolumeInfo(name: name, total: total, free: free, containerReference: reference)
    }

    /// `diskutil apfs list -plist <container>`: bytes used by every volume of the container except the Data one
    /// (System, Preboot, Recovery, VM, Update): what System Settings calls macOS.
    public static func macOSBytes(fromApfsListPlist data: Data) throws(ProbeError) -> Int64 {
        guard let dict = plistDictionary(data), let containers = dict["Containers"] as? [[String: Any]],
            let volumes = containers.first?["Volumes"] as? [[String: Any]]
        else {
            throw .unreadable("diskutil apfs list: no container volumes")
        }
        return volumes.reduce(Int64(0)) { sum, volume in
            let roles = volume["Roles"] as? [String] ?? []
            return roles.contains("Data") ? sum : sum + (int64(volume["CapacityInUse"]) ?? 0)
        }
    }

    /// `xcrun simctl runtime list -j`: a JSON object of runtimes, each with its `sizeBytes`.
    public static func runtimeBytes(fromSimctlJSON data: Data) throws(ProbeError) -> Int64 {
        guard let object = try? JSONSerialization.jsonObject(with: data), let runtimes = object as? [String: Any]
        else {
            throw .unreadable("simctl runtime list: unexpected output")
        }
        return runtimes.values.reduce(Int64(0)) { sum, runtime in
            sum + (int64((runtime as? [String: Any])?["sizeBytes"]) ?? 0)
        }
    }

    private static func plistDictionary(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: n.int64Value
        case let i as Int: Int64(i)
        default: nil
        }
    }
}

import Foundation
import Testing

@testable import SohoMonitorCore

@Suite(.timeLimit(.minutes(1))) struct ProcessRunnerTests {
    @Test func runsACommandAndCapturesBothStreams() async throws {
        let output = try await ProcessRunner().run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(String(decoding: output.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: output.stderr, as: UTF8.self) == "err\n")
        #expect(output.status == 3)
    }

    /// A task cancelled before the process starts must not leave it running to completion (onCancel runs first,
    /// when there is no process to stop yet).
    @Test func aTaskCancelledBeforeTheStartStopsTheProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().run("/bin/sleep", ["20"])
        }
        let output = try await task.value
        #expect(output.status != 0, "sleep should have been terminated")
        #expect(clock.now - start < .seconds(10))
    }
}

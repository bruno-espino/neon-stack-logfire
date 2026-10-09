import Foundation
import XCTest
import OpenTelemetryApi
@testable import LogfireAppleSupport
#if os(macOS)
import Darwin

final class CPURecordingLifecycleTests: XCTestCase {
    func testWorkerPreservesTheCallersActiveSpan() throws {
        let capture = try fixture(FileManager.default.temporaryDirectory)
        let parent = DefaultTracer.instance.spanBuilder(spanName: "run").setNoParent().startSpan()
        try OpenTelemetry.instance.contextProvider.withActiveSpan(parent) {
            let job = CPURecordingJob(parent: parent) {
                XCTAssertEqual(OpenTelemetry.instance.contextProvider.activeSpan?.context, parent.context)
                return capture
            }
            _ = try job.wait()
            XCTAssertTrue(OpenTelemetry.instance.contextProvider.activeSpan === parent)
        }
    }

    private func fixture(_ folder: URL) throws -> CapturedCPURecording {
        let session = try NativeSession(marker: ["session_id": UUID().uuidString, "pid": 42,
            "executable": "/synthetic/App", "started_at": Date().timeIntervalSince1970], verify: false)
        return CapturedCPURecording(options: Companion.Options(), session: session, folder: folder,
            trace: folder.appendingPathComponent("synthetic.trace"), binaryHash: "synthetic", commandDuration: 1)
    }

    func testAppDeadlineDoesNotWaitForRecordingFinalization() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = try fixture(folder), release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let job = CPURecordingJob {
            started.signal(); release.wait()
            return capture
        }
        defer { release.signal() }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let result = try CommandRunner.run("/bin/sleep", ["30"], output: folder.appendingPathComponent("app.stdout"),
            errors: folder.appendingPathComponent("app.stderr"), seconds: 0.1)
        XCTAssertTrue(result.timedOut)
        release.signal()
        XCTAssertEqual(try job.wait().trace, capture.trace)
    }

    func testSharedInterruptionReapsAppAndRecorder() throws {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let cancellation = CommandCancellation()
        defer { cancellation.finish() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = try fixture(folder), launched = DispatchSemaphore(value: 0)
        let pidFile = folder.appendingPathComponent("recorder.pid")
        let job = CPURecordingJob {
            let result = try CommandRunner.run("/bin/sleep", ["30"], output: folder.appendingPathComponent("cpu.stdout"),
                errors: folder.appendingPathComponent("cpu.stderr"), seconds: 2,
                onLaunch: { pid in
                    try String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
                    launched.signal()
                }, cancellation: cancellation)
            try HostCommand.requireSuccess(result.exitCode, message: "Synthetic recording failed")
            return capture
        }
        defer { _ = try? job.wait() }
        var appPID: Int32 = 0, interrupted = false
        let result = try CommandRunner.run("/bin/sleep", ["30"], output: folder.appendingPathComponent("app.stdout"),
            errors: folder.appendingPathComponent("app.stderr"), seconds: 2, onLaunch: { appPID = $0 },
            onTick: {
                if !interrupted, launched.wait(timeout: .now()) == .success {
                    interrupted = true
                    kill(getpid(), SIGTERM)
                }
                return false
            }, cancellation: cancellation)
        XCTAssertEqual(result.exitCode, 143)
        XCTAssertFalse(result.timedOut)
        XCTAssertThrowsError(try job.wait()) { XCTAssertEqual($0 as? CompanionError, .interrupted(143)) }
        let recorderPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(appPID, 0), -1)
        XCTAssertEqual(kill(recorderPID, 0), -1)
    }

    func testInterruptedScopeDoesNotStartAnotherCommand() throws {
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }
        let cancellation = CommandCancellation()
        defer { cancellation.finish() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try CommandRunner.run("/bin/sleep", ["30"], output: folder.appendingPathComponent("first.stdout"),
            errors: folder.appendingPathComponent("first.stderr"), seconds: 2,
            onLaunch: { _ in kill(getpid(), SIGINT) }, cancellation: cancellation)
        XCTAssertEqual(result.exitCode, 130)
        let skipped = try CommandRunner.run("/bin/sleep", ["30"], output: folder.appendingPathComponent("second.stdout"),
            errors: folder.appendingPathComponent("second.stderr"), seconds: 2,
            onLaunch: { _ in XCTFail("An interrupted operation must not launch another child") }, cancellation: cancellation)
        XCTAssertEqual(skipped.exitCode, 130)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("second.stdout").path))
    }
}
#endif

import Foundation
import XCTest
@testable import LogfireAppleSupport
#if os(macOS)
import Darwin

final class ScenarioRunTests: XCTestCase {
    func testDefinitionsCannotOverrideIdentityOrEnableInjectedTools() throws {
        let good = ScenarioDefinition(schemaVersion: 1, id: "sample-v1", arguments: [], environment: ["QUALITY": "low"], requireFrameWindows: false)
        try good.validate()
        for key in ["LOGFIRE_TOKEN", "LOGFIRE_SESSION_ID", "OTEL_EXPORTER_OTLP_HEADERS", "MTL_CAPTURE_ENABLED", "NEON_SESSION_ID"] {
            XCTAssertThrowsError(try ScenarioDefinition(schemaVersion: 1, id: "sample", arguments: [], environment: [key: "override"], requireFrameWindows: false).validate())
        }
        for values in [["--app", "app"], ["--app", "app", "--scenario", "file", "--seconds", "nan"], ["--app", "app", "--scenario", "file", "--profile", "all"]] {
            XCTAssertThrowsError(try ScenarioRunOptions(values))
        }
        XCTAssertNil(try ScenarioRunOptions(["--app", "app", "--scenario", "file"]).profile)
    }

    func testSignalRejectsStaleIdentityAndMissingReadiness() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString, started = Date().timeIntervalSince1970 - 1
        let session = try NativeSession(marker: ["session_id": id, "pid": 42, "executable": "/synthetic/App", "started_at": started], verify: false)
        var value: [String: Any] = ["schema_version": 1, "scenario_id": "sample", "session_id": id, "pid": 42,
            "ready": true, "phase": "passed", "recorded_at": Date().timeIntervalSince1970, "details": [:]]
        func write() throws { try JSONSerialization.data(withJSONObject: value).write(to: url) }
        try write()
        let signal = try ScenarioSignal.read(url, id: "sample", session: session)
        XCTAssertEqual(ScenarioSignal.exitCode(result: .init(exitCode: 143, timedOut: false, requestedStop: true), signal: signal, windows: 1, required: true, issues: []), 0)
        XCTAssertEqual(ScenarioSignal.exitCode(result: .init(exitCode: 0, timedOut: false, requestedStop: false), signal: nil, windows: 0, required: false, issues: []), 1)
        XCTAssertEqual(ScenarioSignal.exitCode(result: .init(exitCode: 0, timedOut: false, requestedStop: false), signal: signal, windows: 0, required: true, issues: []), 1)
        XCTAssertEqual(ScenarioSignal.exitCode(result: .init(exitCode: 0, timedOut: false, requestedStop: false), signal: signal, windows: 0, required: false, issues: []), 0)
        XCTAssertEqual(ScenarioSignal.exitCode(result: .init(exitCode: 137, timedOut: false, requestedStop: true), signal: signal, windows: 1, required: true, issues: []), 137)
        for (key, bad) in [("session_id", UUID().uuidString as Any), ("pid", 43), ("ready", false), ("recorded_at", started - 1), ("phase", "unknown")] {
            let original = value[key]; value[key] = bad; try write()
            XCTAssertThrowsError(try ScenarioSignal.read(url, id: "sample", session: session))
            value[key] = original
        }
    }

    func testSuccessfulProcessExitDoesNotCountAsScenarioCompletion() throws {
        try assertFixture(executable: "/usr/bin/true", arguments: [], seconds: "2", expected: 1)
    }

    func testFrameReaderAcceptsOtherApplicationsRenderModes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let window: [String: Any] = ["frames": 300, "window_seconds": 5, "render_callback_fps": 60,
            "frame_interval_p95_ms": 17, "drawable_width": 600, "drawable_height": 600,
            "frames_over_25_ms": 1, "thermal_state": 0, "workload": "onscreen", "render_mode": "log-roll"]
        try JSONSerialization.data(withJSONObject: window).write(to: url)
        XCTAssertEqual(try SessionAnalysis.windows(at: url).first?["render_mode"] as? String, "log-roll")
    }

    func testMissingProtocolTimesOutAndReapsTheApp() throws {
        try assertFixture(executable: "/bin/sleep", arguments: ["10"], seconds: "1", expected: 124)
    }

    private func assertFixture(executable: String, arguments: [String], seconds: String, expected: Int32) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = folder.appendingPathComponent("Fixture.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let command = contents.appendingPathComponent("MacOS/Fixture")
        try Data("#!/bin/sh\nexec \(executable) \"$@\"\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Fixture", "CFBundleIdentifier": "dev.example.ScenarioFixture.\(UUID().uuidString)", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let definition = ScenarioDefinition(schemaVersion: 1, id: "fixture", arguments: arguments, environment: [:], requireFrameWindows: false)
        let spec = folder.appendingPathComponent("definition.json"); try JSONEncoder().encode(definition).write(to: spec)
        let out = folder.appendingPathComponent("output")
        XCTAssertEqual(try ScenarioRun.run(["--app", app.path, "--scenario", spec.path, "--seconds", seconds, "--output", out.path, "--no-telemetry"]), expected)
        let reports = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(reports.first).appendingPathComponent("report.json"))) as? [String: Any])
        XCTAssertEqual(report["status"] as? String, "failed")
        XCTAssertEqual((report["exit_code"] as? NSNumber)?.int32Value, expected)
        let pid = try XCTUnwrap((report["app.pid"] as? NSNumber)?.int32Value)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }
}
#endif

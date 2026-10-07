import Foundation
import XCTest
@testable import LogfireAppleSupport
#if os(macOS)
import Darwin

final class ScenarioRunTests: XCTestCase {
    func testDefinitionsCannotOverrideIdentityOrEnableInjectedTools() throws {
        let good = ScenarioDefinition(schemaVersion: 1, id: "sample-v1", arguments: [], environment: ["QUALITY": "low"], requireFrameWindows: false)
        try good.validate()
        for key in ["LOGFIRE_TOKEN", "LOGFIRE_SESSION_ID", "OTEL_EXPORTER_OTLP_HEADERS", "MTL_CAPTURE_ENABLED"] {
            XCTAssertThrowsError(try ScenarioDefinition(schemaVersion: 1, id: "sample", arguments: [], environment: [key: "override"], requireFrameWindows: false).validate()) {
                XCTAssertEqual($0 as? ScenarioError, .reservedEnvironmentKey(key))
            }
        }
        for (values, expected) in [
            (["--app", "app"], ScenarioError.missingRequiredOption("--scenario")),
            (["--app", "app", "--scenario", "file", "--seconds", "nan"], .invalidOptionValue("--seconds")),
            (["--app", "app", "--scenario", "file", "--profile", "all"], .invalidOptionValue("--profile")),
            (["--app"], .missingOptionValue("--app")),
            (["--unknown", "value"], .unknownOption("--unknown")),
        ] {
            XCTAssertThrowsError(try ScenarioRunOptions(values)) { XCTAssertEqual($0 as? ScenarioError, expected) }
        }
        XCTAssertNil(try ScenarioRunOptions(["--app", "app", "--scenario", "file"]).profile)
        XCTAssertEqual(try ScenarioRunOptions(["--app", "app", "--scenario", "file", "--profile", "shader"]).profile, "shader")
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
        XCTAssertEqual(ScenarioOutcome.evaluate(result: .init(exitCode: 143, timedOut: false, requestedStop: true), phase: signal.phase, windows: 1, required: true, issues: []).exitCode, 0)
        XCTAssertEqual(ScenarioOutcome.evaluate(result: .init(exitCode: 0, timedOut: false, requestedStop: false), phase: nil, windows: 0, required: false, issues: []).exitCode, 1)
        XCTAssertEqual(ScenarioOutcome.evaluate(result: .init(exitCode: 0, timedOut: false, requestedStop: false), phase: signal.phase, windows: 0, required: true, issues: []).exitCode, 1)
        XCTAssertEqual(ScenarioOutcome.evaluate(result: .init(exitCode: 0, timedOut: false, requestedStop: false), phase: signal.phase, windows: 0, required: false, issues: []).exitCode, 0)
        XCTAssertEqual(ScenarioOutcome.evaluate(result: .init(exitCode: 137, timedOut: false, requestedStop: true), phase: signal.phase, windows: 1, required: true, issues: []).exitCode, 137)
        for (key, bad) in [("session_id", UUID().uuidString as Any), ("pid", 43), ("ready", false), ("recorded_at", started - 1), ("phase", "unknown")] {
            let original = value[key]; value[key] = bad; try write()
            XCTAssertThrowsError(try ScenarioSignal.read(url, id: "sample", session: session)) {
                XCTAssertEqual($0 as? ScenarioError, .invalidStatus(key))
            }
            value[key] = original
        }
    }

    func testOutcomesPreserveFailureCausesWithOverlappingExitCodes() {
        let result = CommandResult(exitCode: 2, timedOut: false, requestedStop: false)
        let failed = ScenarioOutcome.evaluate(result: result, phase: "passed", windows: 1, required: true, issues: [])
        let incomplete = ScenarioOutcome.evaluate(result: .init(exitCode: 0, timedOut: false, requestedStop: false),
            phase: "passed", windows: 1, required: true, issues: ["Missing profile"])
        XCTAssertEqual(failed.exitCode, 2)
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(incomplete.exitCode, 2)
        XCTAssertEqual(incomplete.status, "incomplete")
        XCTAssertEqual(ScenarioOutcome.evaluate(result: result, phase: "passed", windows: 1, required: true,
            issues: [], analysisInterruption: 130).exitCode, 130)
        XCTAssertEqual(ScenarioOutcome.evaluate(result: .init(exitCode: 143, timedOut: true, requestedStop: true),
            phase: "passed", windows: 1, required: true, issues: []).exitCode, 124)
    }

    func testDefinitionValidationNamesTheInvalidFieldWithoutItsValue() {
        for (definition, field) in [
            (ScenarioDefinition(schemaVersion: 2, id: "good", arguments: [], environment: [:], requireFrameWindows: false), "schema_version"),
            (ScenarioDefinition(schemaVersion: 1, id: "bad id", arguments: [], environment: [:], requireFrameWindows: false), "id"),
            (ScenarioDefinition(schemaVersion: 1, id: "good", arguments: ["private\0value"], environment: [:], requireFrameWindows: false), "arguments[0]"),
            (ScenarioDefinition(schemaVersion: 1, id: "good", arguments: [], environment: ["QUALITY": "private\0value"], requireFrameWindows: false), "environment[QUALITY]"),
        ] {
            XCTAssertThrowsError(try definition.validate()) {
                XCTAssertEqual($0 as? ScenarioError, .invalidDefinition(field))
                XCTAssertFalse(String(describing: $0).contains("private"))
            }
        }
    }

    func testSuccessfulProcessExitDoesNotCountAsScenarioCompletion() throws {
        try assertFixture(executable: "/usr/bin/true", arguments: [], seconds: "2", expected: 1)
    }

    func testProcessFailurePreservesExitTwoAsAFailedReport() throws {
        try assertFixture(executable: "/bin/sh", arguments: ["-c", "exit 2"], seconds: "2", expected: 2)
    }

    func testProtocolCompletionProducesPassedAndIncompleteReportsAndReapsBothApps() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = folder.appendingPathComponent("Fixture.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let command = contents.appendingPathComponent("MacOS/Fixture"), source = folder.appendingPathComponent("Fixture.swift")
        let program = #"""
        import Foundation
        let env = ProcessInfo.processInfo.environment
        let pid = ProcessInfo.processInfo.processIdentifier
        let session = env["LOGFIRE_SESSION_ID"]!
        let marker: [String: Any] = ["session_id": session, "pid": pid,
            "executable": CommandLine.arguments[0], "started_at": Date().timeIntervalSince1970]
        let sessions = URL(fileURLWithPath: env["LOGFIRE_SESSION_DIR"]!)
        try JSONSerialization.data(withJSONObject: marker).write(to: sessions.appendingPathComponent("\(pid).json"), options: .atomic)
        let status = URL(fileURLWithPath: env["LOGFIRE_SCENARIO_STATUS"]!)
        if env["INVALID_FRAME"] == "1" {
            try Data("invalid retained JSON".utf8).write(to: status.deletingLastPathComponent().appendingPathComponent("performance.jsonl"))
        }
        let completion: [String: Any] = ["schema_version": 1, "scenario_id": env["LOGFIRE_SCENARIO_ID"]!,
            "session_id": session, "pid": pid, "ready": true, "phase": "passed",
            "recorded_at": Date().timeIntervalSince1970, "details": ["assertion": "passed"]]
        try JSONSerialization.data(withJSONObject: completion).write(to: status, options: .atomic)
        Thread.sleep(forTimeInterval: 10)
        """#
        try program.write(to: source, atomically: true, encoding: .utf8)
        let compilation = try HostCommand.run("/usr/bin/xcrun", ["swiftc", source.path, "-o", command.path],
            output: folder.appendingPathComponent("compile.log"), errors: folder.appendingPathComponent("compile.stderr"), seconds: 30)
        XCTAssertEqual(compilation, 0)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Fixture",
            "CFBundleIdentifier": "dev.example.ScenarioFixture", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        for (invalid, expected, expectedStatus) in [("0", Int32(0), "passed"), ("1", Int32(2), "incomplete")] {
            let spec = folder.appendingPathComponent("scenario.json"), out = folder.appendingPathComponent("output-" + invalid)
            try JSONEncoder().encode(ScenarioDefinition(schemaVersion: 1, id: "fixture", arguments: [],
                environment: ["INVALID_FRAME": invalid], requireFrameWindows: false)).write(to: spec)
            XCTAssertEqual(try ScenarioRun.run(["--app", app.path, "--scenario", spec.path, "--seconds", "3",
                "--output", out.path, "--no-telemetry"]), expected)
            let run = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent("report.json"))) as? [String: Any])
            XCTAssertEqual(report["status"] as? String, expectedStatus)
            XCTAssertEqual((report["exit_code"] as? NSNumber)?.int32Value, expected)
            XCTAssertEqual((report["scenario.details"] as? [String: String])?["assertion"], "passed")
            let pid = try XCTUnwrap((report["app.pid"] as? NSNumber)?.int32Value)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
            if invalid == "1" { XCTAssertEqual(report["issues"] as? [String], ["Frame evidence is invalid."]) }
        }
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

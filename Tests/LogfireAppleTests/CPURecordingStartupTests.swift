import Foundation
import XCTest
@testable import LogfireAppleSupport
#if os(macOS)
import Darwin

final class CPURecordingStartupTests: XCTestCase {
    func testAttachmentUsesVerifiedIdentityWithoutWaitingForRendererReadiness() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = folder.appendingPathComponent("Fixture.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let command = contents.appendingPathComponent("MacOS/Fixture"), source = folder.appendingPathComponent("Fixture.swift")
        let program = #"""
        import Foundation
        let env = ProcessInfo.processInfo.environment
        let pid = ProcessInfo.processInfo.processIdentifier
        let marker: [String: Any] = ["session_id": env["WRONG_MARKER"] == "1" ? UUID().uuidString : env["LOGFIRE_SESSION_ID"]!,
            "pid": pid, "executable": CommandLine.arguments[0], "started_at": Date().timeIntervalSince1970,
            "build.id": "fixture-build"]
        let sessions = URL(fileURLWithPath: env["LOGFIRE_SESSION_DIR"]!)
        try JSONSerialization.data(withJSONObject: marker).write(to: sessions.appendingPathComponent("\(pid).json"), options: .atomic)
        let receipt = env["START_RECEIPT"]!
        while !FileManager.default.fileExists(atPath: receipt) { Thread.sleep(forTimeInterval: 0.01) }
        if env["NO_READINESS"] == "1" { Thread.sleep(forTimeInterval: 30) }
        Thread.sleep(forTimeInterval: 0.1)
        let status: [String: Any] = ["schema_version": 1, "scenario_id": env["LOGFIRE_SCENARIO_ID"]!,
            "session_id": env["LOGFIRE_SESSION_ID"]!, "pid": pid, "ready": true, "phase": "passed",
            "recorded_at": Date().timeIntervalSince1970, "details": [:]]
        try JSONSerialization.data(withJSONObject: status).write(to: URL(fileURLWithPath: env["LOGFIRE_SCENARIO_STATUS"]!), options: .atomic)
        """#
        try program.write(to: source, atomically: true, encoding: .utf8)
        XCTAssertEqual(try HostCommand.run("/usr/bin/xcrun", ["swiftc", source.path, "-o", command.path],
            output: folder.appendingPathComponent("compile.log"), errors: folder.appendingPathComponent("compile.stderr"), seconds: 30), 0)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Fixture",
            "CFBundleIdentifier": "dev.example.CPUStartupFixture.\(UUID().uuidString)", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try JSONSerialization.data(withJSONObject: ["build.id": "fixture-build"])
            .write(to: contents.appendingPathComponent("Resources/LogfireBuild.json"))
        for (name, flags, expected) in [
            ("before-readiness", [String: String](), Int32(2)),
            ("wrong-identity", ["WRONG_MARKER": "1"], Int32(1)),
            ("no-readiness", ["NO_READINESS": "1"], Int32(124)),
        ] {
            let receipt = folder.appendingPathComponent("\(name).started")
            let definition = ScenarioDefinition(schemaVersion: 1, id: "fixture", arguments: [],
                environment: flags.merging(["START_RECEIPT": receipt.path]) { _, value in value }, requireFrameWindows: false)
            let spec = folder.appendingPathComponent("\(name).json")
            try JSONEncoder().encode(definition).write(to: spec)
            let output = folder.appendingPathComponent(name)
            let code = try ScenarioRun.run(["--app", app.path, "--scenario", spec.path, "--profile", "cpu",
                "--seconds", "1", "--output", output.path, "--no-telemetry"], recordCPU: { args, _ in
                    let sessionsIndex = try XCTUnwrap(args.firstIndex(of: "--sessions"))
                    let status = URL(fileURLWithPath: args[sessionsIndex + 1]).deletingLastPathComponent().appendingPathComponent("scenario.json")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: status.path))
                    try Data("requested-before-readiness".utf8).write(to: receipt)
                    throw CompanionError.message("Synthetic recorder failure")
                })
            XCTAssertEqual(code, expected, name)
            let sessionFolder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).first)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sessionFolder.appendingPathComponent("report.json"))) as? [String: Any])
            XCTAssertEqual(FileManager.default.fileExists(atPath: receipt.path), name != "wrong-identity", name)
            if name == "before-readiness" {
                XCTAssertEqual(report["status"] as? String, "incomplete")
                XCTAssertEqual(report["scenario.phase"] as? String, "passed")
                XCTAssertEqual(report["profile.start_trigger"] as? String, "session-identity")
                XCTAssertLessThan(try XCTUnwrap(report["profile.start_requested_seconds"] as? Double),
                    try XCTUnwrap(report["readiness.seconds"] as? Double))
            } else if name == "no-readiness" {
                XCTAssertEqual(report["status"] as? String, "failed")
                XCTAssertEqual(report["scenario.phase"] as? String, "missing")
            }
            let pid = try XCTUnwrap((report["app.pid"] as? NSNumber)?.int32Value)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
        }
    }
}
#endif

import Foundation
import XCTest
@testable import LogfireSwift

final class DevelopmentScenarioTests: XCTestCase {
    func testScenarioRequiresRunnerIdentityAndReadinessBeforeCompletion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = Logfire(serviceName: "test", configuration: nil)
        let output = folder.appendingPathComponent("scenario.json")
        var env = ["LOGFIRE_SESSION_ID": client.sessionID, "LOGFIRE_SCENARIO_ID": "test-scenario", "LOGFIRE_SCENARIO_STATUS": output.path]
        let scenario = try XCTUnwrap(DevelopmentScenario(client: client, environment: env))
        XCTAssertThrowsError(try scenario.finish(passed: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try scenario.markReady()
        try scenario.finish(passed: false, details: ["reason": "expected assertion failed"])
        try scenario.markReady()
        try scenario.finish(passed: true)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(value["phase"] as? String, "failed")
        XCTAssertEqual(value["session_id"] as? String, client.sessionID)
        XCTAssertEqual((value["details"] as? [String: String])?["reason"], "expected assertion failed")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        env["LOGFIRE_SESSION_ID"] = UUID().uuidString
        XCTAssertNil(DevelopmentScenario(client: client, environment: env))
        XCTAssertNil(DevelopmentScenario(client: client, environment: [:]))
    }

    func testRendererEvidencePrecedesReadiness() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = Logfire(serviceName: "test", configuration: nil)
        let scenario = try XCTUnwrap(DevelopmentScenario(client: client, environment: ["LOGFIRE_SESSION_ID": client.sessionID,
            "LOGFIRE_SCENARIO_ID": "renderer", "LOGFIRE_SCENARIO_STATUS": folder.appendingPathComponent("scenario.json").path]))
        let window = FrameWindow(started: Date(), ended: Date(), callbackFPS: 60, gpuMeanMilliseconds: nil, attributes: ["frames": .int(300)])
        try scenario.record(window)
        XCTAssertTrue(scenario.isReady)
        let frame = try Data(contentsOf: folder.appendingPathComponent("performance.jsonl"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: frame) as? [String: Int])?["frames"], 300)
        try scenario.finish(passed: true)
        try scenario.record(window)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("performance.jsonl")), frame)
    }
}

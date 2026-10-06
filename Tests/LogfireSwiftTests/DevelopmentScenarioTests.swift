import Foundation
import XCTest
import OpenTelemetrySdk
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
        XCTAssertThrowsError(try scenario.finish(passed: true)) { error in
            XCTAssertEqual(error as? DevelopmentScenarioError, .notReady)
        }
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

    func testFinishReleasesScenarioLockWhileExporterRunsAndStopsAcceptingFrames() throws {
        final class BlockingExporter: SpanExporter, @unchecked Sendable {
            let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
            func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
                entered.signal(); _ = resume.wait(timeout: .now() + 5); return .success
            }
            func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
            func shutdown(explicitTimeout: TimeInterval?) {}
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exporter = BlockingExporter()
        let monitored = Logfire(serviceName: "test", exporter: exporter)
        let scenario = try XCTUnwrap(DevelopmentScenario(client: monitored, environment: ["LOGFIRE_SESSION_ID": monitored.sessionID,
            "LOGFIRE_SCENARIO_ID": "finish", "LOGFIRE_SCENARIO_STATUS": folder.appendingPathComponent("scenario.json").path]))
        try scenario.markReady()
        let done = expectation(description: "finish publishes completion")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do { try scenario.finish(passed: true) } catch { XCTFail("Unexpected finish error: \(error)") }
        }
        XCTAssertEqual(exporter.entered.wait(timeout: .now() + 2), .success)
        let responsive = expectation(description: "scenario stays accessible during export")
        DispatchQueue.global().async {
            XCTAssertTrue(scenario.isReady)
            do {
                try scenario.record(FrameWindow(started: Date(), ended: Date(), callbackFPS: 60,
                    gpuMeanMilliseconds: nil, attributes: ["frames": .int(300)]))
            } catch { XCTFail("Unexpected record error: \(error)") }
            responsive.fulfill()
        }
        wait(for: [responsive], timeout: 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("performance.jsonl").path))
        exporter.resume.signal(); exporter.resume.signal()
        wait(for: [done], timeout: 3)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("scenario.json"))) as? [String: Any])
        XCTAssertEqual(value["phase"] as? String, "passed")
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

    func testResponsivenessEvidenceRetainsIdentityAndDoesNotSupplyReadiness() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = Logfire(serviceName: "test", configuration: nil)
        let scenario = try XCTUnwrap(DevelopmentScenario(client: client, environment: ["LOGFIRE_SESSION_ID": client.sessionID,
            "LOGFIRE_SCENARIO_ID": "probe", "LOGFIRE_SCENARIO_STATUS": folder.appendingPathComponent("scenario.json").path]))
        try scenario.recordResponsiveness(["window_seconds": .double(5), "main_queue.pending_age_max_ms": .double(1100)], ended: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(scenario.isReady)
        let file = folder.appendingPathComponent("responsiveness.jsonl")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(row["session_id"] as? String, client.sessionID)
        XCTAssertEqual(row["pid"] as? Int32, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(row["recorded_at"] as? Double, 100)
        XCTAssertEqual(row["main_queue.pending_age_max_ms"] as? Double, 1100)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

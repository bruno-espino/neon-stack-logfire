import Foundation
import XCTest
@testable import LogfireAppleSupport

#if os(macOS)
final class CompanionTests: XCTestCase {
    func testCommandDispatchRejectsUnknownCommandsAndRoutesHelp() throws {
        XCTAssertThrowsError(try Companion.run(arguments: ["unknown"])) {
            XCTAssertEqual($0 as? CompanionError, .unknownCommand("unknown"))
        }
        for command in ["configure", "doctor", "build", "test-game", "run", "analyze", "diagnose", "profile", "gpu-capture", "capture", "attach"] {
            XCTAssertEqual(try Companion.run(arguments: [command, "--help"]), 0, command)
        }
    }

    func testStructuredAttributesKeepBooleansDistinctFromZeroAndOneCounts() throws {
        let values = Companion.attributes(["partial": true, "samples": 1, "gaps": 0])
        XCTAssertEqual(values["partial"], .bool(true))
        XCTAssertEqual(values["samples"], .double(1))
        XCTAssertEqual(values["gaps"], .double(0))
        let structured = try Companion.structuredAttribute("diagnostic.details", encoded: ["gaps": ["missing CPU"]], type: "object")
        guard case .string(let schema) = structured["logfire.json_schema"], case .string(let payload) = structured["diagnostic.details"] else {
            return XCTFail("Structured attributes require JSON and schema metadata")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(object["properties"] as? [String: [String: String]])
        XCTAssertEqual(properties["diagnostic.details"]?["type"], "object")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: [String]])?["gaps"], ["missing CPU"])
    }
    func testTypedStructuredFramesPreserveTheirWireFields() throws {
        let attributes = try Companion.structuredAttribute("call_path.frames", encoded: [CPUFrame(symbol: "draw", image: "Game", imageUUID: "binary-id")], type: "array")
        guard case .string(let payload) = attributes["call_path.frames"], case .string(let schema) = attributes["logfire.json_schema"] else {
            return XCTFail("Expected structured OTLP attributes")
        }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: String]],
            [["symbol": "draw", "image": "Game", "imageUUID": "binary-id"]])
        let description = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        XCTAssertEqual((description["properties"] as? [String: [String: String]])?["call_path.frames"], ["type": "array"])
    }

    func testCredentialSetupKeepsFilePrivateAndRejectsInvalidReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.env")
        try Companion.saveCredentials(token: "synthetic-write-token", region: "eu", file: file)
        let data = try Data(contentsOf: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("https://logfire-eu.pydantic.dev"))
        XCTAssertThrowsError(try Companion.saveCredentials(token: "invalid\ntoken", region: "us", file: file))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testNativeParserKeepsProcessResourcesAndFiltersOtherProcesses() {
        let process: [String: Any] = ["PID": 42, "Resource Usage": ["Physical Footprint (MiB)": 128, "CPU User Time (Seconds)": 3],
            "Layers": [["Performance Stats": ["Presented Frame Stats": ["FPS": 59.5, "Frame Count": 300,
                "On-GPU Walltime Stats": ["Count": 0, "Average (ms)": 99]],
                "Frame-On-Glass Interval Stats": ["Count": 299, "Average (ms)": 16.8]]]]]
        XCTAssertTrue(NativeMeasurements.summaries(process, pid: 43).isEmpty)
        let values = NativeMeasurements.summaries(process, pid: 42)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0]["process.memory_mib"] as? Int, 128)
        XCTAssertEqual(values[0]["process.cpu_user_seconds"] as? Int, 3)
        XCTAssertEqual(values[1]["presented_fps"] as? Double, 59.5)
        XCTAssertEqual(values[1]["frame_on_glass_mean_ms"] as? Double, 16.8)
        XCTAssertNil(values[1]["gpu_wall_mean_ms"])
    }

    func testJsonStreamHandlesSplitUnicodeAndBracesInsideStrings() throws {
        let data = Data("{\"PID\":42,\"name\":\"é { \\\" }\"}\n{\"PID\":43}".utf8)
        var decoder = JSONUpdates(); var updates: [[String: Any]] = []
        for byte in data { updates += try decoder.feed(Data([byte])) }
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0]["name"] as? String, "é { \" }")
        XCTAssertEqual(updates[1]["PID"] as? Int, 43)
    }

    func testShaderMeasurementsKeepWindowCountsSeparateFromLifetimeTotals() throws {
        let process: [String: Any] = ["PID": 42, "Layers": [["Performance Stats": [
            "Start Date": "2026-10-07T16:54:37.349Z", "End Date": "2026-10-07T16:54:38.349Z",
            "Presented Frame Stats": ["Shader Compiler": ["Pipeline States": 1, "Shader Compilations": 2,
                "Cached Shader Compilations": 0, "Shader Compilation Time": 0.014857708,
                "Total Pipeline States": 5, "Total Shader Compilations": 4, "Total Cached Shader Compilations": 0,
                "Total Shader Compilation Time": 0.033267708]]]]]]
        let value = try XCTUnwrap(NativeMeasurements.summaries(process, pid: 42).first)
        XCTAssertEqual(value["shader_compilations"] as? Int, 2)
        XCTAssertEqual(value["shader_compilations_total"] as? Int, 4)
        XCTAssertEqual(value["shader_compilation_seconds"] as? Double, 0.014857708)
        XCTAssertEqual(value["shader_compilation_seconds_total"] as? Double, 0.033267708)
        XCTAssertEqual(value["cached_shader_compilations"] as? Int, 0)
        XCTAssertEqual(value["measurement.started_at"] as? String, "2026-10-07T16:54:37.349Z")
        XCTAssertTrue(NativeMeasurements.summaries(process, pid: 43).isEmpty)
    }

    func testUnavailableAndMalformedShaderMeasurementsDoNotBecomeZero() throws {
        let absent = try XCTUnwrap(NativeMeasurements.summaries(["PID": 42, "Layers": [[:]]], pid: 42).first)
        XCTAssertNil(absent["shader_compilations"])
        let malformed: [String: Any] = ["PID": 42, "Layers": [["Performance Stats": ["Presented Frame Stats": [
            "Shader Compiler": ["Shader Compilations": true, "Cached Shader Compilations": -1,
                "Pipeline States": 1.5, "Shader Compilation Time": Double.nan,
                "Total Shader Compilations": "4", "Total Shader Compilation Time": Double.infinity]]]]]]
        let value = try XCTUnwrap(NativeMeasurements.summaries(malformed, pid: 42).first)
        XCTAssertFalse(value.keys.contains { $0.hasPrefix("shader_") || $0.hasPrefix("cached_shader_") || $0.hasPrefix("pipeline_states") })
    }

    func testOverviewDoesNotTreatItsLastQuietShaderUpdateAsACaptureTotal() throws {
        let process: [String: Any] = ["PID": 42, "Layers": [["Total Session Stats": ["Presented Frame Stats": [
            "Shader Compiler": ["Shader Compilations": 0, "Shader Compilation Time": 0,
                "Total Shader Compilations": 4, "Total Shader Compilation Time": 0.033267708]]]]]]
        let value = try XCTUnwrap(NativeMeasurements.summaries(process, pid: 42).first)
        XCTAssertNil(value["shader_compilations"])
        XCTAssertNil(value["shader_compilation_seconds"])
        XCTAssertEqual(value["shader_compilations_total"] as? Int, 4)
        XCTAssertEqual(value["shader_compilation_seconds_total"] as? Double, 0.033267708)
    }

    func testRetainedShaderTimelinePreservesQuietWindowsDatesAndLayerIdentity() throws {
        func update(_ count: Int, seconds: Double) -> [String: Any] {
            ["Start Date": "2026-10-07T16:54:37.349Z", "End Date": "2026-10-07T16:54:38.349Z",
             "Presented Frame Stats": ["Shader Compiler": ["Shader Compilations": count, "Shader Compilation Time": seconds]],
             "Frame-On-Glass Interval Stats": ["Count": 60, "Average (ms)": 16.8, "Max (ms)": 34.1]]
        }
        var invalid = update(2, seconds: 0.01)
        invalid["End Date"] = "2026-10-07T16:54:36.349Z"
        let process: [String: Any] = ["PID": 42, "Layers": [
            ["Layer ID": 99, "Stats Timeline": [["Start Date": "missing"]]],
            ["Layer ID": 101, "Stats Timeline": [update(2, seconds: 0.014857708), update(0, seconds: 0), invalid]]]]
        let values = NativeMeasurements.shaderTimelineSummaries(process, pid: 42)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0]["measurement.scope"] as? String, "shader_compiler_update")
        XCTAssertEqual(values[0]["shader_compilations"] as? Int, 2)
        XCTAssertEqual(values[0]["shader_compilation_seconds"] as? Double, 0.014857708)
        XCTAssertEqual(values[0]["frame_on_glass_max_ms"] as? Double, 34.1)
        XCTAssertEqual(values[0]["measurement.started_at"] as? String, "2026-10-07T16:54:37.349Z")
        XCTAssertEqual(values[0]["layer_index"] as? Int, 1)
        XCTAssertEqual(values[0]["layer_id"] as? Int, 101)
        XCTAssertEqual(values[1]["shader_compilations"] as? Int, 0)
        XCTAssertTrue(NativeMeasurements.shaderTimelineSummaries(process, pid: 43).isEmpty)
    }

    func testSessionRejectsReusedPidOrWrongExecutable() throws {
        let marker: [String: Any] = ["session_id": UUID().uuidString, "pid": ProcessInfo.processInfo.processIdentifier,
            "executable": "/unrelated-app", "started_at": Date().timeIntervalSince1970]
        XCTAssertThrowsError(try NativeSession(marker: marker))
        XCTAssertThrowsError(try Companion.parse(["--seconds", "nan"]))
        XCTAssertThrowsError(try Companion.parse(["--last", "0s"]))
        XCTAssertEqual(try Companion.parse(["--last", "10s", "--service", "game"]).seconds, 10)
    }

    func testAppleCommandDeadlineReapsItsChild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let began = Date()
        XCTAssertThrowsError(try HostCommand.run("/bin/sleep", ["30"], output: directory.appendingPathComponent("stdout"),
            errors: directory.appendingPathComponent("stderr"), seconds: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
    }
}
#endif

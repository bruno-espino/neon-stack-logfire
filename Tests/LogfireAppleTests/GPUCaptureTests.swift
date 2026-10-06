import Foundation
import XCTest
@testable import LogfireAppleSupport
#if os(macOS)
final class GPUCaptureTests: XCTestCase {
    func testGPUOptionsBoundCaptureAndRequireUnambiguousSelection() throws {
        XCTAssertEqual(try GPUCaptureOptions([]).count, 1)
        let options = try GPUCaptureOptions(["--count", "3", "--profile", "--label", "Game.Frame", "--no-telemetry"])
        XCTAssertTrue(options.profile); XCTAssertTrue(options.local); XCTAssertEqual(options.label, "Game.Frame")
        for arguments in [["--count", "0"], ["--count", "4"], ["--boundary", "0"], ["--boundary", "1", "--label", "Frame"], ["--pid", "42"]] {
            XCTAssertThrowsError(try GPUCaptureOptions(arguments))
        }
    }

    func testGPUJSONHandlesConsecutivePrettyObjectsAndQuotedBrackets() throws {
        let data = Data("{\"children\":[{\"name\":\"a}b\\\"c\"}]}\n{\n\"Duration\":\"0.5291 ms\"\n}\n".utf8)
        let objects = try GPUJSON.objects(data)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects.last?["Duration"] as? String, "0.5291 ms")
        for text in ["", "{", "{} error: unavailable", "{\"error\":\"failed\"}", "{\"success\":false}", "{\"a\":NaN}"] {
            XCTAssertThrowsError(try GPUJSON.objects(Data(text.utf8)))
        }
    }

    func testGPUPropertiesRetainUnitsAndExcludeRawResources() throws {
        let properties: [String: Any] = ["Duration":"0.5291 ms", "Active time":"0.514 ms", "Cost":"99,72%",
            "Stage":"fragment", "Temp registers":"46", "Uniform registers":"68", "Spilled bytes":"128", "Wait":"2",
            "source":"/private/source", "resources":["secret":"raw"]]
        let values = GPUJSON.properties(properties)
        XCTAssertEqual(values["gpu.replay.duration_ms"] as? Double, 0.5291)
        XCTAssertEqual(values["gpu.replay.cost_fraction"] as? Double, 0.9972)
        XCTAssertEqual(values["gpu.shader.wait_instructions"] as? Double, 2)
        XCTAssertEqual(values["gpu.shader.spilled_bytes"] as? Double, 128)
        XCTAssertNil(values["source"]); XCTAssertNil(values["resources"])
        let shader = GPUJSON.properties(["Stage": "vertex", "Cost": "24.17%", "Wait": "0"])
        XCTAssertEqual(try XCTUnwrap(shader["gpu.replay.cost_fraction"] as? Double), 0.2417, accuracy: 0.0000001)
        XCTAssertEqual(shader["gpu.shader.stage"] as? String, "vertex")
        XCTAssertNil(shader["gpu.replay.duration_ms"])
        XCTAssertTrue(GPUJSON.properties(["Duration":"2 seconds", "Cost":"101%", "Spilled bytes":"nan", "Wait":"-2"]).isEmpty)
    }
}
#endif

import Foundation
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import LogfireSwift

final class FrameRecorderTests: XCTestCase {
    func testWindowUsesMeasurementTimeAndRetainsPercentiles() throws {
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "frame-test", exporter: exporter)
        let recorder = FrameRecorder(client: client, stateDomain: "test.frames.\(UUID())", spanName: "test.window", began: 0)
        let context = RenderContext(mode: "neon", width: 600, height: 1200)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for (time, frame, cpu, gpu) in [(1.0, 900.0, 90.0, 90.0), (2, 10, 1, 1), (3, 30, 3, 4), (7, 20, 2, 2)] {
            recorder.record(frameMilliseconds: frame, preparationMilliseconds: cpu, gpuMilliseconds: gpu,
                context: context, attributes: ["score": .int(42)], uptime: time, wallTime: date.addingTimeInterval(time))
        }
        recorder.finish()
        let window = try XCTUnwrap(exporter.spans.first { $0.name == "test.window" })
        XCTAssertEqual(window.startTime, date.addingTimeInterval(7))
        XCTAssertEqual(window.attributes["measurement.started_at"], .double(date.addingTimeInterval(2).timeIntervalSince1970))
        XCTAssertEqual(window.endTime, date.addingTimeInterval(7))
        XCTAssertEqual(window.attributes["frames"], .int(3))
        XCTAssertEqual(window.attributes["render_callback_fps"], .double(50))
        XCTAssertEqual(window.attributes["frame_interval_p95_ms"], .double(30))
        XCTAssertEqual(window.attributes["gpu_command_p95_ms"], .double(4))
        XCTAssertEqual(window.attributes["frame_encode_wall_p95_ms"], .double(3))
        XCTAssertEqual(window.attributes["score"], .int(42))
        XCTAssertEqual(window.attributes["cpu_frame.scope"], .string("frame_preparation_wall_time"))
        XCTAssertEqual(window.attributes["main_thread.measured"], .bool(false))
        XCTAssertEqual(window.attributes["session_id"], .string(client.sessionID))
    }

    func testDetailChangesDiscardMixedWorkloadSamples() throws {
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "frame-test", exporter: exporter)
        let recorder = FrameRecorder(client: client, stateDomain: "test.frames.\(UUID())", spanName: "test.window", began: 0)
        let low = RenderContext(mode: "aurora", width: 600, height: 1200, metadata: ["detail": .int(8)])
        let high = RenderContext(mode: "aurora", width: 600, height: 1200, metadata: ["detail": .int(48)])
        for (time, context, frame) in [(2.0, low, 10.0), (3, high, 80), (8, high, 82)] {
            recorder.record(frameMilliseconds: frame, preparationMilliseconds: 1, gpuMilliseconds: nil,
                context: context, attributes: [:], uptime: time, wallTime: Date(timeIntervalSince1970: time))
        }
        recorder.finish()
        let window = try XCTUnwrap(exporter.spans.first { $0.name == "test.window" })
        XCTAssertEqual(window.attributes["frames"], .int(2))
        XCTAssertEqual(window.attributes["detail"], .int(48))
        XCTAssertEqual(window.attributes["frame_interval_p95_ms"], .double(82))
        XCTAssertEqual(window.attributes["gpu_samples"], .int(0))
        XCTAssertNil(window.attributes["gpu_command_p95_ms"])
        XCTAssertEqual(exporter.spans.filter { $0.name == "app.state" }.count, 2)
    }

    func testInvalidDurationsDoNotCreateFakeGpuSamples() throws {
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "frame-test", exporter: exporter)
        var report: Data?
        let recorder = FrameRecorder(client: client, stateDomain: "test.frames.\(UUID())", spanName: "test.window", began: 0) {
            report = try? $0.encodedReport()
        }
        let context = RenderContext(mode: "classic", width: 600, height: 1200)
        for (time, frame, gpu) in [(2.0, 16.0, Double.nan), (3, Double.nan, 1), (7, 16, -2)] {
            recorder.record(frameMilliseconds: frame, preparationMilliseconds: 1, gpuMilliseconds: gpu,
                context: context, attributes: [:], uptime: time, wallTime: Date(timeIntervalSince1970: time))
        }
        recorder.finish()
        let value = try JSONSerialization.jsonObject(with: XCTUnwrap(report)) as? [String: Any]
        XCTAssertEqual(value?["frames"] as? Int, 2)
        XCTAssertEqual(value?["gpu_samples"] as? Int, 0)
        XCTAssertNil(value?["gpu_command_p95_ms"])
    }

#if os(macOS)
    func testApplicationLifecycleFlushesWithoutBlockingTheNotification() {
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "lifecycle-test", exporter: exporter)
        let flushed = expectation(description: "Lifecycle flush completes")
        let lifecycle = AppleLifecycle { client.flush(); flushed.fulfill() }
        client.event("before-background")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        wait(for: [flushed], timeout: 3)
        XCTAssertEqual(exporter.spans.map(\.name), ["before-background"])
        withExtendedLifetime(lifecycle) {}
    }
#endif
}

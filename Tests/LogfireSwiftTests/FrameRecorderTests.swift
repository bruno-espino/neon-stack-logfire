import Foundation
import XCTest
import OpenTelemetrySdk
import os
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

    func testDetailChangesPreserveSeparatePartialWindows() throws {
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
        let windows = exporter.spans.filter { $0.name == "test.window" }
        XCTAssertEqual(windows.count, 2)
        let partial = try XCTUnwrap(windows.first { $0.attributes["detail"] == .int(8) })
        XCTAssertEqual(partial.attributes["frames"], .int(1))
        XCTAssertEqual(partial.attributes["window.partial"], .bool(true))
        let window = try XCTUnwrap(windows.first { $0.attributes["detail"] == .int(48) })
        XCTAssertEqual(window.attributes["frames"], .int(2))
        XCTAssertEqual(window.attributes["detail"], .int(48))
        XCTAssertEqual(window.attributes["frame_interval_p95_ms"], .double(82))
        XCTAssertEqual(window.attributes["gpu_samples"], .int(0))
        XCTAssertNil(window.attributes["gpu_command_p95_ms"])
        XCTAssertEqual(exporter.spans.filter { $0.name == "app.state" }.count, 2)
    }

    func testFlushPublishesPartialSamplesOnceAndFinishStopsRecording() throws {
        let spans = CaptureExporter(), metrics = CaptureMetricExporter()
        let client = Logfire(serviceName: "partial-test", exporter: spans, metricExporter: metrics)
        let recorder = FrameRecorder(client: client, stateDomain: "test.partial", spanName: "window", began: 0)
        let context = RenderContext(mode: "test", width: 42, height: 42)
        for time in [2.0, 3.0] {
            recorder.record(frameMilliseconds: 10, preparationMilliseconds: 1, gpuMilliseconds: nil,
                context: context, attributes: [:], uptime: time, wallTime: Date(timeIntervalSince1970: time))
        }
        client.flush()
        client.flush()
        recorder.finish(uptime: 4)
        recorder.record(frameMilliseconds: 10, preparationMilliseconds: 1, gpuMilliseconds: nil,
            context: context, attributes: [:], uptime: 5, wallTime: Date())
        recorder.finish(uptime: 6)
        let windows = spans.spans.filter { $0.name == "window" }
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.attributes["frames"], .int(2))
        XCTAssertEqual(windows.first?.attributes["window.partial"], .bool(true))
        let histograms = metrics.metrics.filter { $0.name == "game.frame.interval" }
        XCTAssertEqual(histograms.flatMap { $0.data.points }.compactMap { ($0 as? HistogramPointData)?.count }.reduce(0, +), 2)
    }

    func testPresentedCadenceUsesSortedValidDisplayTimesAndExportsTheTail() throws {
        let spans = CaptureExporter(), metrics = CaptureMetricExporter()
        let client = Logfire(serviceName: "display-test", exporter: spans, metricExporter: metrics)
        let recorder = FrameRecorder(client: client, stateDomain: "test.display", spanName: "window", began: 0)
        let context = RenderContext(mode: "test", width: 42, height: 42)
        recorder.record(frameMilliseconds: 10, preparationMilliseconds: 1, gpuMilliseconds: nil,
            context: context, attributes: [:], uptime: 2, wallTime: Date(timeIntervalSince1970: 2))
        for time in [100.0 + 2.0 / 30, 100.0, 100.0 + 1.0 / 30, 0, Double.nan] {
            recorder.recordPresentation(time: time, target: 100, context: context)
        }
        recorder.record(frameMilliseconds: 10, preparationMilliseconds: 1, gpuMilliseconds: nil,
            context: context, attributes: [:], uptime: 7, wallTime: Date(timeIntervalSince1970: 7))
        recorder.recordPresentation(time: 100 + 3.0 / 30, context: context)
        recorder.finish(uptime: 7.1)
        let windows = spans.spans.filter { $0.name == "window" }
        XCTAssertEqual(windows.count, 2)
        let complete = try XCTUnwrap(windows.first { $0.attributes["window.partial"] == .bool(false) })
        XCTAssertEqual(complete.attributes["render_callback_fps"], .double(100))
        guard case .double(let fps) = complete.attributes["display_presented_fps"] else { return XCTFail("Missing presented FPS") }
        XCTAssertEqual(fps, 30, accuracy: 0.001)
        XCTAssertEqual(complete.attributes["display_presented_frames"], .int(3))
        XCTAssertEqual(complete.attributes["display_timestamp_unavailable"], .int(2))
        let tail = try XCTUnwrap(windows.first { $0.attributes["window.partial"] == .bool(true) })
        XCTAssertEqual(tail.attributes["frames"], .int(0))
        XCTAssertEqual(tail.attributes["display_presented_frames"], .int(1))
        XCTAssertNil(tail.attributes["render_callback_fps"])
        let intervals = metrics.metrics.filter { $0.name == "game.display.present.interval" }
        XCTAssertEqual(intervals.flatMap { $0.data.points }.compactMap { ($0 as? HistogramPointData)?.count }.reduce(0, +), 3)
        let confirmed = metrics.metrics.filter { $0.name == "game.display.present.count" }
        XCTAssertEqual(confirmed.flatMap { $0.data.points }.compactMap { ($0 as? LongPointData)?.value }.reduce(0, +), 4)
    }

    func testConcurrentReportCallbacksCanRequestFlushWithoutWaitingOnEachOther() {
        let spans = CaptureExporter()
        let client = Logfire(serviceName: "callback-flush", exporter: spans)
        let reports = expectation(description: "Both callbacks return from flush")
        reports.expectedFulfillmentCount = 2
        let arrived = DispatchGroup()
        arrived.enter(); arrived.enter()
        let callback: @Sendable (FrameWindow) -> Void = { _ in
            arrived.leave()
            _ = arrived.wait(timeout: .now() + 1)
            client.flush()
            reports.fulfill()
        }
        let first = FrameRecorder(client: client, stateDomain: "first", spanName: "window", began: 0, onWindow: callback)
        let second = FrameRecorder(client: client, stateDomain: "second", spanName: "window", began: 0, onWindow: callback)
        let context = RenderContext(mode: "test", width: 42, height: 42)
        for recorder in [first, second] {
            for time in [2.0, 7.0] {
                recorder.record(frameMilliseconds: 10, preparationMilliseconds: 1, gpuMilliseconds: nil,
                    context: context, attributes: [:], uptime: time, wallTime: Date(timeIntervalSince1970: time))
            }
        }
        wait(for: [reports], timeout: 3)
        client.flush()
        XCTAssertEqual(spans.spans.filter { $0.name == "window" }.count, 2)
        withExtendedLifetime([first, second]) {}
    }

    func testInvalidDurationsDoNotCreateFakeGpuSamples() throws {
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "frame-test", exporter: exporter)
        let report = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let recorder = FrameRecorder(client: client, stateDomain: "test.frames.\(UUID())", spanName: "test.window", began: 0) {
            let data = try? $0.encodedReport()
            report.withLock { $0 = data }
        }
        let context = RenderContext(mode: "classic", width: 600, height: 1200)
        for (time, frame, gpu) in [(2.0, 16.0, Double.nan), (3, Double.nan, 1), (7, 16, -2)] {
            recorder.record(frameMilliseconds: frame, preparationMilliseconds: 1, gpuMilliseconds: gpu,
                context: context, attributes: [:], uptime: time, wallTime: Date(timeIntervalSince1970: time))
        }
        recorder.finish()
        let value = try JSONSerialization.jsonObject(with: XCTUnwrap(report.withLock { $0 })) as? [String: Any]
        XCTAssertEqual(value?["frames"] as? Int, 2)
        XCTAssertEqual(value?["gpu_samples"] as? Int, 0)
        XCTAssertNil(value?["gpu_command_p95_ms"])
        XCTAssertEqual(value?["session_id"] as? String, client.sessionID)
        XCTAssertEqual(value?["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
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

import Foundation
import XCTest
@testable import LogfireAppleSupport
#if os(macOS)
final class WorkflowTests: XCTestCase {
    private let context = ["host.model": "SyntheticMac", "gpu.name": "SyntheticGPU", "host.memory_bytes": "16000000000",
        "host.processors": "8", "os.version": "SyntheticOS", "seed": "777", "test.seconds": "20", "test.protocol": "test-v1"]

    private func report(_ metrics: [String: Double], workload: String = "offscreen", native: Bool = false, issues: [String] = []) -> SessionReport {
        SessionReport(sessionID: UUID().uuidString, build: ["build.id": UUID().uuidString],
            cohort: context.merging(["configuration": "Release", "workload": workload]) { _, value in value },
            metrics: metrics, windows: 3, nativeExpected: native, nativeLayers: native ? 1 : 0, issues: issues)
    }
    private var metrics: [String: Double] { ["sdk_callback_hz": 60, "sdk_slow_frame_fraction": 0,
        "sdk_worst_window_frame_interval_p95_ms": 17, "sdk_worst_window_gpu_command_p95_ms": 3] }

    func testBuildParserKeepsTotalsWithoutInventingIntervals() {
        var parser = BuildOutput()
        for line in ["CompileSwift 99 seconds", "warning: example", "error: example", "Build Timing Summary",
                     "  SwiftCompile (2 tasks) | 1.2 seconds", "  SwiftCompile 0.3 seconds", "Link 0.4 seconds", "done", "Link 88 seconds"] { parser.line(line) }
        XCTAssertEqual(parser.timings["SwiftCompile"] ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(parser.timings["Link"] ?? 0, 0.4, accuracy: 0.001)
        XCTAssertNil(parser.timings["CompileSwift"])
        XCTAssertEqual(parser.warnings, 1); XCTAssertEqual(parser.errors, 1)
        XCTAssertThrowsError(try BuildArguments(["--timeout", "nan", "--", "build"]))
        XCTAssertThrowsError(try BuildArguments(["--", "build", "LOGFIRE_BUILD_ID=other"]))
        XCTAssertEqual(try BuildArguments(["--no-telemetry", "--scenario", "example", "--", "build"]).scenario, "example")
    }

    func testComparisonRejectsDifferentWorkloadAndMissingNativeMetrics() {
        let base = report(metrics)
        XCTAssertEqual(SessionAnalysis.compare(report(metrics, workload: "onscreen"), baseline: base, threshold: 10).status, "not_comparable")
        let native = report(metrics, workload: "onscreen", native: true)
        XCTAssertEqual(SessionAnalysis.compare(native, baseline: native, threshold: 10).status, "incomplete")
        XCTAssertEqual(SessionAnalysis.compare(report(metrics, issues: ["capture gap"]), baseline: base, threshold: 10).status, "not_comparable")
    }

    func testComparisonDetectsFpsDropsAndNewSlowFramesFromZeroBaseline() {
        let base = report(metrics)
        var worse = metrics; worse["sdk_callback_hz"] = 50; worse["sdk_slow_frame_fraction"] = 0.01
        let compared = SessionAnalysis.compare(report(worse), baseline: base, threshold: 10)
        XCTAssertEqual(compared.exitCode, 1)
        XCTAssertTrue(compared.changes.first { $0.metric == "sdk_callback_hz" }?.regressed == true)
        XCTAssertTrue(compared.changes.first { $0.metric == "sdk_slow_frame_fraction" }?.regressed == true)
        XCTAssertEqual(SessionAnalysis.compare(base, baseline: base, threshold: 10).status, "passed")
    }

    func testSummaryUsesWorstWindowP95AndHarmonicCallbackRate() throws {
        let windows: [[String: Any]] = [10.0, 20.0, 30.0].map { value in
            ["frames": 100, "render_callback_fps": value, "frame_interval_p95_ms": value,
             "gpu_command_p95_ms": value / 10, "frames_over_25_ms": 10, "thermal_state": 0,
             "drawable_width": 600, "drawable_height": 1200, "render_mode": "neon", "workload": "offscreen", "aurora_layers": 0]
        }
        let summary = try SessionAnalysis.summarize(windows: windows, native: [], sessionID: "test", build: ["build.configuration": "Release"],
            context: context, nativeExpected: false, issues: [])
        XCTAssertEqual(summary.metrics["sdk_worst_window_frame_interval_p95_ms"], 30)
        XCTAssertEqual(summary.metrics["sdk_callback_hz"] ?? 0, 16.363636, accuracy: 0.001)
        XCTAssertEqual(summary.metrics["sdk_slow_frame_fraction"] ?? 0, 0.1, accuracy: 0.001)
        var mixed = windows; mixed[1]["drawable_width"] = 800
        XCTAssertThrowsError(try SessionAnalysis.summarize(windows: mixed, native: [], sessionID: "test", build: [:], context: context, nativeExpected: false, issues: []))
    }

    func testNativeStateGroupsKeepSeparateContext() {
        let layer: [String: Any] = ["Performance Stats": ["Presented Frame Stats": ["FPS": 55, "Frame Count": 100]]]
        let process: [String: Any] = ["PID": 42, "Domain": "example.graphics", "Groups": [
            ["State Label": "High", "Stable State": ["detail": 48], "Total Duration (sec)": 3, "Layers": [layer]]]]
        let values = NativeMeasurements.stateSummaries(process, pid: 42)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0]["measurement.scope"] as? String, "state_layer")
        XCTAssertEqual(values[0]["state.label"] as? String, "High")
        XCTAssertEqual(values[0]["presented_fps"] as? Int, 55)
        XCTAssertTrue(NativeMeasurements.stateSummaries(process, pid: 43).isEmpty)
    }

    func testNativeComparisonUsesMatchingStateSliceAndRejectsIncompleteCoverage() throws {
        let window: [String: Any] = ["frames": 300, "window_seconds": 5, "render_callback_fps": 60,
            "frame_interval_p95_ms": 17, "gpu_command_p95_ms": 3, "frames_over_25_ms": 0, "thermal_state": 0,
            "drawable_width": 600, "drawable_height": 1200, "render_mode": "aurora", "workload": "onscreen", "aurora_layers": 8]
        let metadata: [String: Any] = ["drawable_width": 600, "drawable_height": 1200, "render_mode": "aurora", "workload": "onscreen", "aurora_layers": 8]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self)
        var state: [String: Any] = ["measurement.scope": "state_layer", "state.domain": "dev.example.NeonStack.rendering",
            "state.label": "aurora", "state.metadata": encoded, "presented_frames": 900, "presented_fps": 60,
            "frame_on_glass_mean_ms": 16.7, "gpu_wall_mean_ms": 2, "window_seconds": 14.5,
            "measurement.started_at": "2026-01-01T00:00:00.250Z", "measurement.ended_at": "2026-01-01T00:00:14.750Z"]
        let fullCapture: [String: Any] = ["measurement.scope": "layer", "presented_fps": 40, "presented_frames": 1000]
        func summarize(_ native: [[String: Any]]) throws -> SessionReport {
            let windows = ["05", "10", "15"].map { seconds in
                window.merging(["recorded_at": "2026-01-01T00:00:\(seconds).000Z"]) { _, timestamp in timestamp }
            }
            return try SessionAnalysis.summarize(windows: windows, native: native, sessionID: "example",
                build: ["build.configuration": "Release"], context: context, nativeExpected: true, issues: [])
        }
        let result = try summarize([fullCapture, state])
        XCTAssertEqual(result.metrics["native_presented_fps"], 60)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.metrics["native_sdk_interval_coverage"] ?? 0, 14.5 / 15, accuracy: 0.001)
        state["window_seconds"] = 10
        XCTAssertFalse(try summarize([state]).issues.isEmpty)
        state["state.label"] = "neon"
        XCTAssertNil(try summarize([state]).metrics["native_presented_fps"])
        let origin = try XCTUnwrap(NativeMeasurements.date("2026-01-01T00:00:00.500Z"))
        let interval = origin.addingTimeInterval(2.25)...origin.addingTimeInterval(17.25)
        let offsets = try NativeMeasurements.aggregationOffsets(interval, origin: origin)
        XCTAssertEqual(offsets.lowerBound, 2)
        XCTAssertEqual(offsets.upperBound, 18)
        XCTAssertThrowsError(try NativeMeasurements.aggregationOffsets(origin.addingTimeInterval(-10)...origin.addingTimeInterval(-5), origin: origin))
    }

    func testMeasuredIntervalPreservesFractionalDates() throws {
        let interval = try GameTest.measuredInterval([["recorded_at": "2026-01-01T00:00:10.750Z", "window_seconds": 5.25]])
        XCTAssertEqual(interval.upperBound.timeIntervalSince(interval.lowerBound), 5.25, accuracy: 0.0001)
        XCTAssertEqual(interval.upperBound.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.75, accuracy: 0.0001)
        XCTAssertThrowsError(try GameTestOptions(["--app", "example.app", "--seed", "-1"]))
        XCTAssertFalse(try GameTestOptions(["--app", "example.app", "--offscreen"]).native)
    }

    func testCommandCancellationReapsDescendantAndPreservesExitCode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("child.pid")
        let script = "sleep 30 & child=$!; echo $child > '\(pidFile.path)'; trap 'wait $child; exit 143' TERM; wait $child"
        let result = try CommandRunner.run("/bin/sh", ["-c", script], output: folder.appendingPathComponent("stdout"),
            errors: folder.appendingPathComponent("stderr"), seconds: 0.3)
        XCTAssertTrue(result.timedOut)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(try CommandRunner.run("/bin/sh", ["-c", "exit 65"], output: folder.appendingPathComponent("stdout"),
            errors: folder.appendingPathComponent("stderr"), seconds: 2).exitCode, 65)
    }
}
#endif

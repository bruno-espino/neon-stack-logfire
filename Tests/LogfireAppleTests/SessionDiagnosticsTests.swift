import Foundation
import XCTest
@testable import LogfireAppleSupport
#if os(macOS)
final class SessionDiagnosticsTests: XCTestCase {
    private func report(profile: String = "none") -> [String: Any] {
        ["session_id": "A06360A1-8FD6-4DD1-9037-847434F5E457", "schema_version": 1,
            "app.pid": 42, "run.started_at": 100.0, "app.duration_seconds": 12.0, "profile.requested": profile, "issues": [String]()]
    }

    func testBusyAndIdleStallWindowsSelectDifferentInvestigationsWithoutClaimingCause() {
        for (cpu, expected) in [(0.9, "Time Profiler"), (0.01, "System Trace")] {
            let diagnostic = SessionDiagnostics.make(report: report(), folder: URL(fileURLWithPath: "/synthetic"), windows: [],
                responsiveness: [["main_queue.pending_age_max_ms": 1200, "main_thread.cpu.utilization": cpu,
                    "recorded_at": 110, "window_seconds": 5]], cpu: nil, artifacts: [], gaps: [])
            XCTAssertEqual(diagnostic.findings.map(\.id), ["main_queue_delay"])
            XCTAssertTrue(diagnostic.findings[0].nextInvestigation.contains(expected))
            XCTAssertEqual(diagnostic.findings[0].signals["main_queue.worst_delay_ms"], 1200)
            XCTAssertTrue(diagnostic.limitations.contains { $0.contains("same instant") })
            XCTAssertFalse(diagnostic.findings[0].observation.contains("blocked"))
            XCTAssertEqual(diagnostic.findings[0].intervals.first?.startedAt, 105)
            XCTAssertEqual(diagnostic.findings[0].intervals.first?.endedAt, 110)
        }
    }

    func testGPUCommandSumDoesNotBecomeAMissedDeadlineAndMissingEvidenceDoesNotPassPerformance() {
        let diagnostic = SessionDiagnostics.make(report: report(profile: "gpu"), folder: URL(fileURLWithPath: "/synthetic"),
            windows: [["frames": 300, "frames_over_25_ms": 0, "frame_interval_p95_ms": 17, "gpu_command_p95_ms": 50]],
            responsiveness: [], cpu: nil, artifacts: [], gaps: [])
        XCTAssertTrue(diagnostic.findings.isEmpty)
        XCTAssertTrue(diagnostic.summary.contains("Missing evidence"))
        XCTAssertTrue(diagnostic.observationGaps.contains { $0.contains("unprofiled matched Release") })
        XCTAssertTrue(diagnostic.observationGaps.contains { $0.contains("No decoded CPU") })
    }

    func testRareSlowFramesRemainVisibleEvenWhenP95LooksNormal() {
        let diagnostic = SessionDiagnostics.make(report: report(), folder: URL(fileURLWithPath: "/synthetic"),
            windows: [["frames": 100, "frames_over_25_ms": 1, "frame_interval_p95_ms": 17],
                      ["frames": 300, "frames_over_25_ms": 0, "frame_interval_p95_ms": 17]],
            responsiveness: [], cpu: nil, artifacts: [], gaps: [])
        XCTAssertEqual(diagnostic.observations["frames.over_25ms_fraction"], 0.0025)
        XCTAssertEqual(diagnostic.findings.map(\.id), ["slow_callback_intervals"])
    }

    func testFrameIntervalsParseSDKDatesAndExcludeWindowsWithoutSlowCallbacks() {
        let diagnostic = SessionDiagnostics.make(report: report(), folder: URL(fileURLWithPath: "/synthetic"),
            windows: [["frames": 300, "frames_over_25_ms": 1, "recorded_at": "1970-01-01T00:01:47Z", "window_seconds": 5],
                ["frames": 300, "frames_over_25_ms": 0, "recorded_at": "1970-01-01T00:01:52Z", "window_seconds": 5]],
            responsiveness: [], cpu: nil, artifacts: [], gaps: [])
        XCTAssertEqual(diagnostic.findings.first?.intervals.count, 1)
        XCTAssertEqual(diagnostic.findings.first?.intervals.first?.startedAt, 102)
        XCTAssertEqual(diagnostic.findings.first?.intervals.first?.endedAt, 107)
    }

    func testRetainedProbeRejectsAnotherSessionProcessAndInterval() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var row: [String: Any] = ["schema_version": 1, "session_id": report()["session_id"]!, "pid": 42,
            "recorded_at": 110.0, "window_seconds": 5.0, "main_queue.delay_max_ms": 0.5]
        func write() throws { try JSONSerialization.data(withJSONObject: row).write(to: file) }
        try write()
        XCTAssertEqual(try SessionDiagnostics.responsiveness(at: file, report: report()).count, 1)
        for (key, value) in [("session_id", UUID().uuidString as Any), ("pid", 99), ("recorded_at", 150.0), ("main_queue.delay_max_ms", -1.0)] {
            let original = row[key]; row[key] = value; try write()
            XCTAssertThrowsError(try SessionDiagnostics.responsiveness(at: file, report: report())) { error in
                XCTAssertEqual(error as? DiagnosticEvidenceError, key == "main_queue.delay_max_ms" ?
                    .invalidResponsivenessField(key) : .invalidResponsivenessIdentity)
            }
            row[key] = original
        }
    }

    func testShaderManifestAppearsInTheExistingDiagnosticArtifactList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let capture = folder.appendingPathComponent("profile/session/capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var run = report(profile: "shader"); run["binary.sha256"] = "synthetic-hash"
        let manifest: [String: Any] = ["session_id": run["session_id"]!, "process.pid": 42,
            "binary.sha256": "synthetic-hash", "capture.shader_timeline_requested": true,
            "capture.measurements": [["measurement.scope": "shader_compiler_update", "shader_compilations": 2]]]
        let path = capture.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: path)
        let diagnostic = SessionDiagnostics.build(report: run, folder: folder, windows: [])
        let artifact = try XCTUnwrap(diagnostic.artifacts.first { $0.kind == "shader" })
        XCTAssertEqual(URL(fileURLWithPath: artifact.path).resolvingSymlinksInPath(), path.resolvingSymlinksInPath())
        XCTAssertFalse(diagnostic.observationGaps.contains { $0.contains("manifests are invalid") })
    }

    func testSavedCPUExportAddsCallerPathsAndRejectsChangedEvidence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let capture = folder.appendingPathComponent("profile/session/capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let xml = """
        <trace-query-result><node><schema name="time-profile"/><row><process><pid>42</pid></process>
        <thread-state>Running</thread-state><thread fmt="Main Thread (0x1)"/><weight>1000000</weight>
        <tagged-backtrace><frame name="draw"><binary id="b" name="Game" UUID="one"/></frame>
        <frame name="update"><binary ref="b"/></frame></tagged-backtrace></row></node></trace-query-result>
        """
        let start = "1970-01-01T00:01:42Z", end = "1970-01-01T00:01:47Z"
        let toc = """
        <trace-toc><run number="1"><info><target><process pid="42"/></target><summary>
        <start-date>\(start)</start-date><end-date>\(end)</end-date><duration>5</duration>
        <instruments-version>27</instruments-version></summary></info></run></trace-toc>
        """
        let cpuFile = capture.appendingPathComponent("cpu.xml"), tocFile = capture.appendingPathComponent("toc.xml")
        try Data(xml.utf8).write(to: cpuFile); try Data(toc.utf8).write(to: tocFile)
        var run = report(); run["binary.sha256"] = "synthetic-hash"
        var summary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CPUProfileSummary())) as? [String: Any])
        summary.removeValue(forKey: "callPaths")
        let manifest: [String: Any] = ["session_id": run["session_id"]!, "process.pid": 42, "binary.sha256": "synthetic-hash",
            "profile.started_at": start, "profile.ended_at": end, "cpu.summary": summary,
            "artifacts": ["cpu.xml": try Companion.fileHash(cpuFile), "toc.xml": try Companion.fileHash(tocFile)]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: capture.appendingPathComponent("manifest.json"))
        let valid = SessionDiagnostics.build(report: run, folder: folder, windows: [])
        XCTAssertEqual(valid.observations["cpu.running_samples"], 1)
        XCTAssertEqual(valid.cpuCallPaths.first?.frames.map(\.symbol), ["update", "draw"])
        XCTAssertEqual(valid.cpuCallers?.first { $0.function.symbol == "update" }?.function.weightNanoseconds, 1_000_000)
        XCTAssertTrue(valid.artifacts.contains { $0.kind == "cpu" })
        try Data((xml + " ").utf8).write(to: cpuFile)
        let changed = SessionDiagnostics.build(report: run, folder: folder, windows: [])
        XCTAssertTrue(changed.cpuCallPaths.isEmpty)
        XCTAssertNil(changed.cpuCallers)
        XCTAssertTrue(changed.observationGaps.contains { $0.contains("manifests are invalid") })
    }
}
#endif

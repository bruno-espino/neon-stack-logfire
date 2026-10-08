import Foundation
import XCTest

@testable import LogfireAppleSupport

#if os(macOS)
    final class ThreadTimelineTests: XCTestCase {
        private func schema(_ name: String, _ fields: [(String, String)]) -> String {
            "<schema name=\"\(name)\">"
                + fields.map {
                    "<col><mnemonic>\($0.0)</mnemonic><engineering-type>\($0.1)</engineering-type></col>"
                }.joined() + "</schema>"
        }

        private func thread(pid: Int = 42, tid: Int = 123, main: Bool = true) -> String {
            "<thread fmt=\"\(main ? "Main Thread (0x7b)" : "Worker")\"><tid>\(tid)</tid><process><pid>\(pid)</pid></process></thread>"
        }

        private func state(_ name: String, start: Int, duration: Int, pid: Int = 42, tid: Int = 123, main: Bool = true)
            -> String
        {
            "<row><start-time>\(start)</start-time>\(thread(pid: pid, tid: tid, main: main))<thread-state>\(name)</thread-state>"
                + "<duration>\(duration)</duration><process><pid>\(pid)</pid></process><sentinel/></row>"
        }

        private func states(_ rows: String) -> Data {
            Data(
                ("<trace-query-result><node>"
                    + schema(
                        "thread-state",
                        [
                            ("start", "start-time"), ("thread", "thread"), ("state", "thread-state"),
                            ("duration", "duration"), ("process", "process"), ("waittime", "duration-waiting"),
                        ]) + rows + "</node></trace-query-result>").utf8)
        }

        private func call(start: Int, duration: Int, wait: Int? = nil, pid: Int = 42, tid: Int = 123) -> String {
            let waiting = wait.map { "<duration-waiting>\($0)</duration-waiting>" } ?? "<sentinel/>"
            return
                "<row><start-time>\(start)</start-time>\(thread(pid: pid, tid: tid))<syscall>BSC_semwait_signal</syscall>"
                + "<duration>\(duration)</duration><process><pid>\(pid)</pid></process>\(waiting)<syscall-arg>0xPRIVATE</syscall-arg></row>"
        }

        private func calls(_ rows: String = "") -> Data {
            Data(
                ("<trace-query-result><node>"
                    + schema(
                        "syscall",
                        [
                            ("start", "start-time"), ("thread", "thread"), ("call", "syscall"),
                            ("duration", "duration"),
                            ("process", "process"), ("waittime", "duration-waiting"), ("arg1", "syscall-arg"),
                        ]) + rows + "</node></trace-query-result>").utf8)
        }

        private func decode(_ data: Data, syscall: Data? = nil, interval: ClosedRange<Double> = 100...101) throws
            -> ThreadTimelineEvidence
        {
            try ThreadTimeline.decode(
                states: data, syscalls: syscall ?? calls(), pid: 42,
                recordingStart: 100, interval: interval, captureID: UUID().uuidString)
        }

        func testMainThreadStatesClipLifetimeAndKeepRunnableSeparateFromBlocked() throws {
            let rows =
                state("Blocked", start: 0, duration: 200_000_000)
                + state("Running", start: 200_000_000, duration: 100_000_000)
                + state("Runnable", start: 300_000_000, duration: 100_000_000)
                + state("Blocked", start: 400_000_000, duration: 600_000_000)
                + state("Blocked", start: 0, duration: 1_000_000_000, tid: 9, main: false)
                + state("Blocked", start: 0, duration: 1_000_000_000, pid: 99)
            let syscalls =
                call(start: 400_000_000, duration: 300_000_000, wait: 250_000_000)
                + call(start: 0, duration: 200_000_000) + call(start: 800_000_000, duration: 200_000_000)
                + call(start: 0, duration: 500_000_000, pid: 99)
            let evidence = try decode(states(rows), syscall: calls(syscalls), interval: 100.1...100.9)
            XCTAssertEqual(evidence.mainThreadID, 123)
            XCTAssertEqual(evidence.statesMilliseconds["Blocked"]!, 600, accuracy: 0.001)
            XCTAssertEqual(evidence.statesMilliseconds["Runnable"]!, 100, accuracy: 0.001)
            XCTAssertEqual(evidence.statesMilliseconds["Running"]!, 100, accuracy: 0.001)
            XCTAssertEqual(evidence.unobservedMilliseconds, 0, accuracy: 0.001)
            XCTAssertEqual(evidence.longestNonRunning.first?.state, "Blocked")
            XCTAssertEqual(evidence.longestNonRunning.first!.milliseconds, 500, accuracy: 0.001)
            XCTAssertEqual(evidence.boundarySyscallsOmitted, 2)
            XCTAssertEqual(evidence.syscalls.first?.calls, 1)
            XCTAssertEqual(evidence.syscalls.first?.wallMilliseconds, 300)
            XCTAssertEqual(evidence.syscalls.first?.waitMilliseconds, 250)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("PRIVATE"))
            XCTAssertTrue(evidence.limitations.contains { $0.contains("normal sleeps") })
        }

        func testPartialCoverageAndMissingWaitTimeRemainExplicit() throws {
            let evidence = try decode(
                states(state("Blocked", start: 100_000_000, duration: 200_000_000)),
                syscall: calls(call(start: 100_000_000, duration: 100_000_000)))
            XCTAssertEqual(evidence.unobservedMilliseconds, 800, accuracy: 0.001)
            XCTAssertEqual(evidence.syscalls.first?.calls, 1)
            XCTAssertEqual(evidence.syscalls.first?.measuredWaitCalls, 0)
        }

        func testReferencesResolveWithoutConfusingPositionalSentinels() throws {
            let first = state("Blocked", start: 0, duration: 500_000_000)
                .replacingOccurrences(
                    of: "<thread-state>Blocked</thread-state>", with: "<thread-state id=\"b\">Blocked</thread-state>")
            let second = state("Blocked", start: 500_000_000, duration: 500_000_000)
                .replacingOccurrences(of: "<thread-state>Blocked</thread-state>", with: "<thread-state ref=\"b\"/>")
            XCTAssertEqual(try decode(states(first + second)).statesMilliseconds["Blocked"], 1000)
            XCTAssertThrowsError(try decode(states(second))) { XCTAssertEqual($0 as? ThreadTimelineError, .reference) }
            XCTAssertThrowsError(try decode(states(first + first))) {
                XCTAssertEqual($0 as? ThreadTimelineError, .reference)
            }
        }

        func testOverlappingStatesAndAmbiguousThreadsCannotBecomeAValidSummary() throws {
            let first = state("Blocked", start: 0, duration: 700_000_000)
            XCTAssertThrowsError(
                try decode(states(first + state("Runnable", start: 500_000_000, duration: 100_000_000)))
            ) {
                XCTAssertEqual($0 as? ThreadTimelineError, .overlappingStates)
            }
            XCTAssertThrowsError(
                try decode(states(first + state("Running", start: 700_000_000, duration: 100_000_000, tid: 124)))
            ) {
                XCTAssertEqual($0 as? ThreadTimelineError, .identity)
            }
            XCTAssertThrowsError(try decode(states(state("Blocked", start: 0, duration: 100_000_000, main: false)))) {
                XCTAssertEqual($0 as? ThreadTimelineError, .missingMainThread)
            }
            XCTAssertThrowsError(
                try decode(states(first), syscall: calls(call(start: 0, duration: 100_000_000, tid: 124)))
            ) {
                XCTAssertEqual($0 as? ThreadTimelineError, .identity)
            }
        }

        func testSchemaAndNumericFailuresAreTyped() throws {
            let valid = String(decoding: states(state("Blocked", start: 0, duration: 1_000_000_000)), as: UTF8.self)
            for (text, expected) in [
                (
                    valid.replacingOccurrences(of: "<mnemonic>state</mnemonic>", with: "<mnemonic>process</mnemonic>"),
                    ThreadTimelineError.schema("thread-state")
                ),
                (
                    valid.replacingOccurrences(of: "<duration>1000000000</duration>", with: "<duration>nan</duration>"),
                    .field("duration")
                ),
                (valid.replacingOccurrences(of: "<sentinel/>", with: ""), .field("row width")),
            ] {
                XCTAssertThrowsError(try decode(Data(text.utf8))) {
                    XCTAssertEqual($0 as? ThreadTimelineError, expected)
                }
            }
        }

        func testSelectedDetailsAreBoundedAndKeepCompleteStateTotals() throws {
            let rows = (0..<40).map { state("Blocked", start: $0 * 25_000_000, duration: 25_000_000) }.joined()
            let evidence = try decode(states(rows))
            XCTAssertEqual(evidence.stateIntervals, 40)
            XCTAssertEqual(evidence.longestNonRunning.count, 20)
            XCTAssertEqual(evidence.statesMilliseconds["Blocked"]!, 1000, accuracy: 0.001)
        }

        func testWindowCorrelationUsesAllStatesBeyondTheTwentyRetainedIntervals() throws {
            let rows = (0..<40).map { state("Blocked", start: $0 * 25_000_000, duration: 25_000_000) }.joined()
            let requests = [
                TimelineWindowRequest(
                    findingID: "main_queue_delay", source: "sdk.main_thread_monitor",
                    startedAt: 100.5, endedAt: 101)
            ]
            let evidence = try ThreadTimeline.decode(
                states: states(rows), syscalls: calls(), pid: 42,
                recordingStart: 100, interval: 100...101, captureID: UUID().uuidString, requests: requests)
            XCTAssertEqual(evidence.longestNonRunning.count, 20)
            let window = try XCTUnwrap(evidence.windows?.first)
            XCTAssertEqual(window.statesMilliseconds["Blocked"] ?? 0, 500, accuracy: 0.001)
            XCTAssertEqual(window.coverageFraction, 1, accuracy: 0.001)
            XCTAssertTrue(evidence.limitations.contains { $0.contains("not exact stall timestamps") })
        }

        func testWindowCoverageRetainsMissingTimeAndKeepsOverlappingWindowsSeparate() throws {
            let requests = [
                TimelineWindowRequest(
                    findingID: "main_queue_delay", source: "sdk.main_thread_monitor", startedAt: 100, endedAt: 102),
                TimelineWindowRequest(
                    findingID: "slow_callback_intervals", source: "sdk.frame_recorder", startedAt: 100, endedAt: 101),
                TimelineWindowRequest(
                    findingID: "main_queue_delay", source: "sdk.main_thread_monitor", startedAt: 103, endedAt: 104),
            ]
            let evidence = try ThreadTimeline.decode(
                states: states(state("Runnable", start: 0, duration: 500_000_000)),
                syscalls: calls(), pid: 42, recordingStart: 100, interval: 100...101,
                captureID: UUID().uuidString, requests: requests)
            XCTAssertEqual(evidence.windows?.map(\.coverageFraction), [0.25, 0.5, 0])
            XCTAssertEqual(evidence.windows?.last?.statesMilliseconds.count, 0)
            XCTAssertEqual(evidence.statesMilliseconds["Runnable"], 500)
            XCTAssertNil(evidence.statesMilliseconds["Blocked"])
            let bounded = try ThreadTimeline.decode(
                states: states(state("Running", start: 0, duration: 1_000_000_000)),
                syscalls: calls(), pid: 42, recordingStart: 100, interval: 100...101,
                captureID: UUID().uuidString, requests: Array(repeating: requests[0], count: 21))
            XCTAssertEqual(bounded.windows?.count, 20)
            XCTAssertEqual(bounded.omittedWindowRequests, 1)
        }

        func testOnlyIdentifiedSDKWindowsCorrelateAndInvalidOptionalFilesDoNotLoseNativeStates() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            var (report, capture) = try fixture(folder)
            report["run.started_at"] = 100.0
            report["app.duration_seconds"] = 10.0
            var frame: [String: Any] = [
                "frames": 10, "window_seconds": 5.0, "render_callback_fps": 10,
                "frame_interval_p95_ms": 30, "frames_over_25_ms": 1, "drawable_width": 600, "drawable_height": 1200,
                "workload": "onscreen", "render_mode": "classic", "thermal_state": 0,
                "recorded_at": "1970-01-01T00:01:45Z",
            ]
            let file = folder.appendingPathComponent("performance.jsonl")
            func save() throws { try JSONSerialization.data(withJSONObject: frame).write(to: file) }
            try save()
            let legacy = try TimelineImport.requests(report: report, folder: folder)
            XCTAssertTrue(legacy.windows.isEmpty)
            XCTAssertEqual(legacy.gaps.count, 1)
            frame["session_id"] = report["session_id"]
            frame["pid"] = 42
            try save()
            let valid = try TimelineImport.decode(
                folder: capture, runFolder: folder, report: report, captureID: UUID().uuidString)
            XCTAssertEqual(valid.windows?.first?.request.findingID, "slow_callback_intervals")
            XCTAssertEqual(valid.windows?.first?.coverageFraction ?? 0, 0.2, accuracy: 0.001)
            XCTAssertEqual(valid.windows?.first?.statesMilliseconds["Blocked"] ?? 0, 1000, accuracy: 0.001)
            frame["pid"] = 99
            try save()
            XCTAssertTrue(try TimelineImport.requests(report: report, folder: folder).windows.isEmpty)
            try Data("invalid".utf8).write(to: folder.appendingPathComponent("responsiveness.jsonl"))
            let partial = try TimelineImport.decode(
                folder: capture, runFolder: folder, report: report, captureID: UUID().uuidString)
            XCTAssertEqual(partial.statesMilliseconds["Blocked"] ?? 0, 1000, accuracy: 0.001)
            XCTAssertEqual(partial.correlationGaps?.count, 2)
            var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(partial)) as! [String: Any]
            for key in ["windows", "omittedWindowRequests", "correlationGaps"] { legacyJSON.removeValue(forKey: key) }
            XCTAssertNil(
                try JSONDecoder().decode(
                    ThreadTimelineEvidence.self,
                    from: JSONSerialization.data(withJSONObject: legacyJSON)
                ).windows)
        }

        private func fixture(_ folder: URL) throws -> ([String: Any], URL) {
            let session = UUID().uuidString
            let report: [String: Any] = [
                "schema_version": 1, "session_id": session, "app.pid": 42,
                "run.started_at": 100.1, "app.duration_seconds": 0.8,
                "binary.sha256": String(repeating: "a", count: 64),
            ]
            let marker: [String: Any] = [
                "session_id": session, "pid": 42, "started_at": 100.2, "executable": "/synthetic/Game",
            ]
            let capture = folder.appendingPathComponent("profile/\(session)/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: marker).write(
                to: folder.appendingPathComponent("sessions/42.json"))
            let toc = """
                <trace-toc><run number="1"><info><target><process pid="42"/></target><summary>
                <start-date>1970-01-01T00:01:40Z</start-date><end-date>1970-01-01T00:01:41Z</end-date><duration>1</duration>
                </summary></info><processes><process pid="42" path="/synthetic/Game"/></processes>
                <data><table schema="thread-state"/><table schema="syscall"/></data></run></trace-toc>
                """
            try Data(toc.utf8).write(to: capture.appendingPathComponent("toc.xml"))
            try states(state("Blocked", start: 0, duration: 1_000_000_000)).write(
                to: capture.appendingPathComponent("thread-state.xml"))
            try calls(call(start: 200_000_000, duration: 100_000_000, wait: 90_000_000)).write(
                to: capture.appendingPathComponent("syscall.xml"))
            let manifest: [String: Any] = [
                "session_id": session, "process.pid": 42, "binary.sha256": report["binary.sha256"]!,
                "measurement.source": "apple.xctrace.thread-state", "capture.id": capture.lastPathComponent,
                "timeline.summary": ["fabricated": true],
                "artifacts": try Dictionary(
                    uniqueKeysWithValues:
                        TimelineImport.files.map { ($0, try Companion.fileHash(capture.appendingPathComponent($0))) }),
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(
                to: capture.appendingPathComponent("manifest.json"))
            return (report, capture)
        }

        func testOfflineDiagnosisVerifiesRawEvidenceAndIgnoresCachedSummary() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let (report, capture) = try fixture(folder)
            let path = folder.appendingPathComponent("report.json")
            try JSONSerialization.data(withJSONObject: report).write(to: path)
            XCTAssertEqual(try SessionDiagnostics.run(["--report", path.path]), 0)
            let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            let diagnostic = try JSONDecoder().decode(
                SessionDiagnostic.self, from: JSONSerialization.data(withJSONObject: updated["diagnostic"]!))
            XCTAssertEqual(diagnostic.threadTimelines?.first?.mainThreadID, 123)
            XCTAssertEqual(diagnostic.threadTimelines?.first?.statesMilliseconds["Blocked"] ?? 0, 800, accuracy: 0.001)
            XCTAssertTrue(diagnostic.artifacts.contains { $0.kind == "thread-timeline" })
            XCTAssertTrue(diagnostic.findings.isEmpty)
            var legacy = try SessionDiagnostics.object(diagnostic)
            legacy.removeValue(forKey: "threadTimelines")
            XCTAssertNil(
                try JSONDecoder().decode(SessionDiagnostic.self, from: JSONSerialization.data(withJSONObject: legacy))
                    .threadTimelines)
            try Data("changed".utf8).write(to: capture.appendingPathComponent("thread-state.xml"))
            let invalid = SessionDiagnostics.build(report: report, folder: folder, windows: [])
            XCTAssertNil(invalid.threadTimelines)
            XCTAssertTrue(invalid.observationGaps.contains { $0.contains("manifests are invalid") })
        }

        func testImportRejectsDifferentProcessPathSessionAndNonOverlappingLifetime() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let (report, capture) = try fixture(folder)
            let toc = try Data(contentsOf: capture.appendingPathComponent("toc.xml"))
            for (key, value) in [("app.pid", 99 as Any), ("session_id", UUID().uuidString), ("run.started_at", 200.0)] {
                var other = report
                other[key] = value
                XCTAssertThrowsError(try TimelineImport.identity(toc: toc, report: other, folder: folder))
            }
            let changed = String(decoding: toc, as: UTF8.self).replacingOccurrences(
                of: "/synthetic/Game", with: "/synthetic/Other")
            XCTAssertThrowsError(try TimelineImport.identity(toc: Data(changed.utf8), report: report, folder: folder)) {
                XCTAssertEqual($0 as? ThreadTimelineError, .identity)
            }
            XCTAssertThrowsError(
                try SessionDiagnostics.run([
                    "--report", folder.appendingPathComponent("missing.json").path, "--publish",
                ]))
        }
    }
#endif

import Foundation
import LogfireSwift

#if os(macOS)
    enum TimelineImport {
        static let files = ["toc.xml", "thread-state.xml", "syscall.xml"]

        static func identity(toc: Data, report: [String: Any], folder: URL) throws -> (
            Int32, Double, ClosedRange<Double>
        ) {
            guard let sessionID = report["session_id"] as? String, UUID(uuidString: sessionID) != nil,
                let process = SessionAnalysis.number(report["app.pid"]), process > 0, process.rounded() == process,
                process <= Double(Int32.max), let started = SessionAnalysis.number(report["run.started_at"]),
                started >= 0,
                let duration = SessionAnalysis.number(report["app.duration_seconds"]), duration > 0,
                (started + duration).isFinite, let hash = report["binary.sha256"] as? String,
                hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            else { throw ThreadTimelineError.identity }
            let pid = Int32(process)
            let markerFile = folder.appendingPathComponent("sessions/\(pid).json")
            guard markerFile.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
                let marker = try JSONSerialization.jsonObject(with: SessionDiagnostics.data(markerFile, limit: 65536))
                    as? [String: Any],
                marker["session_id"] as? String == sessionID, SessionAnalysis.number(marker["pid"]) == process,
                let markerStart = SessionAnalysis.number(marker["started_at"]), markerStart >= started,
                markerStart <= started + duration,
                report.filter({ $0.key.hasPrefix("build.") }).allSatisfy({ key, value in
                    (value as? String) != nil && value as? String == marker[key] as? String
                })
            else { throw ThreadTimelineError.identity }
            let session = try NativeSession(marker: marker, verify: false)
            let recording = try InstrumentsXML.recording(toc, pid: pid)
            let document = try InstrumentsXML.document(toc)
            guard try document.nodes(forXPath: "/trace-toc/run").count == 1,
                try document.nodes(forXPath: "/trace-toc/run/info/target/process").count == 1,
                try document.nodes(forXPath: "/trace-toc/run/processes/process[@pid='\(pid)']").count == 1,
                let recordedProcess = try document.nodes(forXPath: "/trace-toc/run/processes/process[@pid='\(pid)']")
                    .first as? XMLElement,
                let path = recordedProcess.attribute(forName: "path")?.stringValue, path.hasPrefix("/"),
                URL(fileURLWithPath: path).resolvingSymlinksInPath() == session.executable.resolvingSymlinksInPath(),
                let start = (recording["profile.started_at"] as? String).flatMap(NativeMeasurements.date)?
                    .timeIntervalSince1970,
                let end = (recording["profile.ended_at"] as? String).flatMap(NativeMeasurements.date)?
                    .timeIntervalSince1970
            else {
                throw ThreadTimelineError.identity
            }
            for schema in ["thread-state", "syscall"] {
                guard try document.nodes(forXPath: "/trace-toc/run/data/table[@schema='\(schema)']").count == 1 else {
                    throw ThreadTimelineError.schema(schema)
                }
            }
            let lower = max(start, started)
            let upper = min(end, started + duration)
            guard upper > lower else { throw ThreadTimelineError.identity }
            return (pid, start, lower...upper)
        }

        static func decode(
            folder: URL, runFolder: URL, report: [String: Any], captureID: String,
            verifyDrawableChecksum: Bool = false, drawableChecksum: String? = nil
        ) throws
            -> ThreadTimelineEvidence
        {
            let (pid, start, interval) = try identity(
                toc: SessionDiagnostics.data(folder.appendingPathComponent("toc.xml")),
                report: report, folder: runFolder)
            let selection = try requests(report: report, folder: runFolder)
            var evidence = try ThreadTimeline.decode(
                states: SessionDiagnostics.data(
                    folder.appendingPathComponent("thread-state.xml"), limit: 64 * 1024 * 1024),
                syscalls: SessionDiagnostics.data(
                    folder.appendingPathComponent("syscall.xml"), limit: 64 * 1024 * 1024),
                pid: pid, recordingStart: start, interval: interval, captureID: captureID,
                requests: selection.windows)
            evidence.correlationGaps = selection.gaps
            let drawable = folder.appendingPathComponent(DrawableWaits.filename)
            if FileManager.default.fileExists(atPath: drawable.path) {
                do {
                    let toc = try InstrumentsXML.document(
                        SessionDiagnostics.data(folder.appendingPathComponent("toc.xml")))
                    guard
                        try toc.nodes(
                            forXPath: "/trace-toc/run[@number='1']/data/table[@schema='\(DrawableWaits.schema)']"
                        ).count == 1
                    else {
                        throw ThreadTimelineError.schema(DrawableWaits.schema)
                    }
                    guard
                        drawable.resolvingSymlinksInPath().path.hasPrefix(
                            runFolder.resolvingSymlinksInPath().path + "/")
                    else {
                        throw ThreadTimelineError.identity
                    }
                    let data = try SessionDiagnostics.data(drawable, limit: 64 * 1024 * 1024)
                    if verifyDrawableChecksum {
                        guard let drawableChecksum, drawableChecksum == (try Companion.fileHash(drawable)) else {
                            throw ThreadTimelineError.identity
                        }
                    }
                    try DrawableWaits.attach(data, pid: pid, recordingStart: start, evidence: &evidence)
                } catch {
                    evidence.correlationGaps?.append(
                        "Native next-drawable waits failed validation. Main-thread state evidence remains available.")
                }
            } else {
                evidence.correlationGaps?.append(DrawableWaits.unavailable)
            }
            return evidence
        }

        static func requests(report: [String: Any], folder: URL) throws -> (
            windows: [TimelineWindowRequest], gaps: [String]
        ) {
            guard let started = SessionAnalysis.number(report["run.started_at"]),
                let duration = SessionAnalysis.number(report["app.duration_seconds"])
            else { throw ThreadTimelineError.identity }
            let frameFile = folder.appendingPathComponent("performance.jsonl")
            let responseFile = folder.appendingPathComponent("responsiveness.jsonl")
            var frames: [[String: Any]] = []
            var response: [[String: Any]] = []
            var gaps: [String] = []
            if FileManager.default.fileExists(atPath: frameFile.path) {
                do {
                    _ = try SessionDiagnostics.data(frameFile, limit: 1024 * 1024)
                    let rows = try SessionAnalysis.windows(at: frameFile)
                    frames = rows.filter { row in
                        guard row["session_id"] as? String == report["session_id"] as? String,
                            SessionAnalysis.number(row["pid"]) == SessionAnalysis.number(report["app.pid"]),
                            let interval = SessionDiagnostics.intervals([row], source: "sdk.frame_recorder").first,
                            interval.startedAt >= started, interval.endedAt <= started + duration + 1
                        else { return false }
                        return true
                    }
                    if frames.count != rows.count {
                        gaps.append(
                            "Some renderer windows lack matching session/PID/interval identity and were not correlated."
                        )
                    }
                } catch {
                    gaps.append(
                        "Renderer windows are invalid. Native state evidence remains available without renderer correlation."
                    )
                }
            }
            if FileManager.default.fileExists(atPath: responseFile.path) {
                do { response = try SessionDiagnostics.responsiveness(at: responseFile, report: report) } catch {
                    gaps.append(
                        "Responsiveness windows are invalid. Native state evidence remains available without queue correlation."
                    )
                }
            }
            let diagnosis = SessionDiagnostics.make(
                report: report, folder: folder, windows: frames,
                responsiveness: response, cpu: nil, artifacts: [], gaps: [])
            var windows: [TimelineWindowRequest] = []
            for finding in diagnosis.findings {
                for interval in finding.intervals {
                    windows.append(
                        TimelineWindowRequest(
                            findingID: finding.id, source: interval.source,
                            startedAt: interval.startedAt, endedAt: interval.endedAt))
                }
            }
            windows.sort {
                $0.startedAt == $1.startedAt ? $0.source < $1.source : $0.startedAt < $1.startedAt
            }
            return (windows, gaps)
        }

        static func read(_ manifest: [String: Any], folder: URL, runFolder: URL, report: [String: Any]) throws
            -> ThreadTimelineEvidence
        {
            guard manifest["measurement.source"] as? String == "apple.xctrace.thread-state",
                let id = manifest["capture.id"] as? String, UUID(uuidString: id) != nil,
                let hashes = manifest["artifacts"] as? [String: String]
            else { throw ThreadTimelineError.identity }
            for name in files {
                let file = folder.appendingPathComponent(name)
                guard file.resolvingSymlinksInPath().path.hasPrefix(runFolder.resolvingSymlinksInPath().path + "/"),
                    (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize.map({ $0 <= 64 * 1024 * 1024 }) == true,
                    hashes[name] == (try Companion.fileHash(file))
                else { throw ThreadTimelineError.identity }
            }
            return try decode(
                folder: folder, runFolder: runFolder, report: report, captureID: id,
                verifyDrawableChecksum: true, drawableChecksum: hashes[DrawableWaits.filename])
        }

        static func run(trace: URL, report: [String: Any], runFolder: URL, publish: Bool) throws -> Int32 {
            guard let session = report["session_id"] as? String, UUID(uuidString: session) != nil else {
                throw ThreadTimelineError.identity
            }
            let id = UUID().uuidString
            let folder = runFolder.appendingPathComponent("profile/\(session)/\(id)")
            let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath()
            guard parent.path.hasPrefix(runFolder.resolvingSymlinksInPath().path + "/") else {
                throw ThreadTimelineError.identity
            }
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, selection) in [
                ("toc.xml", ["--toc"]),
                ("thread-state.xml", ["--xpath", "/trace-toc/run[@number='1']/data/table[@schema='thread-state']"]),
                ("syscall.xml", ["--xpath", "/trace-toc/run[@number='1']/data/table[@schema='syscall']"]),
            ] {
                let code = try HostCommand.run(
                    "/usr/bin/xcrun",
                    ["xctrace", "export", "--input", trace.path] + selection + [
                        "--output", folder.appendingPathComponent(name).path,
                    ],
                    output: folder.appendingPathComponent(name + ".stdout"),
                    errors: folder.appendingPathComponent(name + ".stderr"), seconds: 30)
                try HostCommand.requireSuccess(code, message: "Native timeline export failed. Inspect \(folder.path)")
                if name == "toc.xml" {
                    _ = try identity(
                        toc: SessionDiagnostics.data(folder.appendingPathComponent(name)), report: report,
                        folder: runFolder)
                }
            }
            let toc = try InstrumentsXML.document(SessionDiagnostics.data(folder.appendingPathComponent("toc.xml")))
            if try toc.nodes(forXPath: "/trace-toc/run[@number='1']/data/table[@schema='\(DrawableWaits.schema)']")
                .count == 1
            {
                let output = folder.appendingPathComponent(DrawableWaits.filename)
                let code = try HostCommand.run(
                    "/usr/bin/xcrun",
                    [
                        "xctrace", "export", "--input", trace.path,
                        "--xpath", "/trace-toc/run[@number='1']/data/table[@schema='\(DrawableWaits.schema)']",
                        "--output", output.path,
                    ],
                    output: folder.appendingPathComponent(DrawableWaits.filename + ".stdout"),
                    errors: folder.appendingPathComponent(DrawableWaits.filename + ".stderr"), seconds: 30)
                if [130, 143].contains(code) { return code }
                if code != 0 { try? FileManager.default.removeItem(at: output) }
            }
            let evidence = try decode(folder: folder, runFolder: runFolder, report: report, captureID: id)
            let context = report.filter {
                $0.key.hasPrefix("build.")
                    || ["session_id", "binary.sha256", "git.commit", "scenario.id"].contains($0.key)
            }
            .merging([
                "capture.id": id, "capture.kind": "instruments-thread-timeline", "process.pid": report["app.pid"]!,
                "measurement.source": "apple.xctrace.thread-state", "measurement.scope": "main_thread_states",
                "profile.instrumented": true, "capture.storage": "local", "capture.path": trace.path,
                "timeline.identity_basis": "pid_executable_session_interval", "timeline.binary_hash_verified": false,
                "source.run_trace_id": report["trace_id"] as? String ?? "unavailable",
            ]) { _, actual in actual }
            var manifest = context
            let retainedFiles =
                files
                + (FileManager.default.fileExists(atPath: folder.appendingPathComponent(DrawableWaits.filename).path)
                    ? [DrawableWaits.filename] : [])
            manifest["artifacts"] = try Dictionary(
                uniqueKeysWithValues: retainedFiles.map {
                    ($0, try Companion.fileHash(folder.appendingPathComponent($0)))
                })
            manifest["timeline.summary"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence))
            let manifestFile = folder.appendingPathComponent("manifest.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(
                to: manifestFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestFile.path)
            print("Native main-thread timeline: \(evidence.stateIntervals) intervals. Capture ID: \(id)")
            print("External host load was not controlled. This is diagnostic evidence, not a performance baseline.")
            var code: Int32 = 0
            if publish {
                let client = Companion.client(local: false, service: "logfire-apple-analysis", resource: context)
                try client.withSpan("development.timeline.import", attributes: Companion.attributes(context)) {
                    try self.publish(evidence, client: client, context: context)
                }
                client.flush()
                Companion.printDelivery(client)
                let delivery = client.delivery
                code =
                    delivery.enabled && delivery.failedSpans == 0
                        && delivery.exportedSpans == evidence.syscalls.count + (evidence.windows?.count ?? 0)
                            + (evidence.drawableWaits == nil ? 0 : 1) + 2
                    ? 0 : 2
            }
            print("Timeline manifest: \(folder.appendingPathComponent("manifest.json").path)")
            return code
        }

        static func publish(_ evidence: ThreadTimelineEvidence, client: Logfire, context: [String: Any]) throws {
            var values = context.merging([
                "thread.id": String(evidence.mainThreadID), "timeline.state_intervals": evidence.stateIntervals,
                "timeline.unobserved_ms": evidence.unobservedMilliseconds,
                "timeline.boundary_syscalls_omitted": evidence.boundarySyscallsOmitted,
            ]) { _, actual in actual }
            for (state, duration) in evidence.statesMilliseconds { values["thread.state.\(state).ms"] = duration }
            let details = try Companion.structuredAttribute("timeline.details", encoded: evidence, type: "object")
            client.window(
                "development.thread.timeline", started: Date(timeIntervalSince1970: evidence.startedAt),
                ended: Date(timeIntervalSince1970: evidence.endedAt),
                attributes: Companion.attributes(values).merging(details) { _, actual in actual })
            for call in evidence.syscalls {
                var attributes = context.merging([
                    "measurement.source": "apple.xctrace.syscall", "measurement.scope": "main_thread_syscall",
                    "thread.id": String(evidence.mainThreadID), "syscall.name": call.name, "syscall.calls": call.calls,
                    "syscall.wall_ms": call.wallMilliseconds,
                    "syscall.measured_wait_calls": call.measuredWaitCalls,
                    "syscall.longest_ms": call.longestMilliseconds,
                ]) { _, actual in actual }
                if call.measuredWaitCalls > 0 { attributes["syscall.wait_ms"] = call.waitMilliseconds }
                client.window(
                    "development.thread.syscall", started: Date(timeIntervalSince1970: evidence.startedAt),
                    ended: Date(timeIntervalSince1970: evidence.endedAt), attributes: Companion.attributes(attributes))
            }
            if let waits = evidence.drawableWaits {
                let values = context.merging([
                    "measurement.source": "apple.xctrace.ca-client-buffer-wait-interval",
                    "measurement.scope": "complete_main_thread_next_drawable_calls",
                    "thread.id": String(evidence.mainThreadID), "drawable.wait.calls": waits.calls,
                    "drawable.wait.wall_ms": waits.wallMilliseconds,
                    "drawable.wait.longest_ms": waits.longestMilliseconds,
                    "drawable.wait.boundary_calls_omitted": waits.boundaryCallsOmitted,
                ]) { _, actual in actual }
                client.window(
                    "development.metal.drawable_wait", started: Date(timeIntervalSince1970: evidence.startedAt),
                    ended: Date(timeIntervalSince1970: evidence.endedAt), attributes: Companion.attributes(values))
            }
            for window in evidence.windows ?? [] {
                var values = context.merging([
                    "measurement.scope": "main_thread_states_in_sdk_window", "thread.id": String(evidence.mainThreadID),
                    "diagnostic.finding_id": window.request.findingID, "window.source": window.request.source,
                    "window.coverage_fraction": window.coverageFraction,
                    "window.observed_ms": window.observedMilliseconds,
                    "window.requested_ms": (window.request.endedAt - window.request.startedAt) * 1000,
                    "window.correlation": "temporal_overlap_not_causation",
                ]) { _, actual in actual }
                for (state, duration) in window.statesMilliseconds { values["thread.state.\(state).ms"] = duration }
                if let wait = window.drawableWaitMilliseconds {
                    values["window.drawable_wait_ms"] = wait
                    values["window.drawable_wait_scope"] = "clipped_main_thread_next_drawable_intervals"
                }
                client.window(
                    "development.thread.window", started: Date(timeIntervalSince1970: window.request.startedAt),
                    ended: Date(timeIntervalSince1970: window.request.endedAt), attributes: Companion.attributes(values)
                )
            }
        }
    }
#endif

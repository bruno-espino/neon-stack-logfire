import Foundation
import LogfireSwift
#if os(macOS)

enum DiagnosticEvidenceError: Error, Equatable, CustomStringConvertible {
    case tooLarge, invalidResponsivenessIdentity, invalidResponsivenessField(String), invalidRunReport

    var description: String {
        switch self {
        case .tooLarge: return "Diagnostic evidence exceeds its size limit"
        case .invalidResponsivenessIdentity: return "Responsiveness evidence does not identify this run and interval"
        case .invalidResponsivenessField(let key): return "Invalid responsiveness field \(key)"
        case .invalidRunReport: return "Supply a retained scenario-run report"
        }
    }
}

struct DiagnosticFinding: Codable {
    let id: String
    let observation: String
    let signals: [String: Double]
    let nextInvestigation: String
    var intervals: [DiagnosticInterval] = []
}

struct DiagnosticInterval: Codable {
    let source: String
    let startedAt: Double
    let endedAt: Double
}

struct DiagnosticArtifact: Codable {
    let kind: String
    let path: String
}

struct SessionDiagnostic: Codable {
    var schemaVersion = 1
    let summary: String
    let observations: [String: Double]
    let findings: [DiagnosticFinding]
    var observationGaps: [String]
    let limitations: [String]
    let artifacts: [DiagnosticArtifact]
    let cpuCallPaths: [CPUCallPath]
}

/// The hosted overview omits caller paths because each path has its own bounded record.
private struct DiagnosticDetails: Encodable {
    let schemaVersion: Int
    let summary: String
    let observations: [String: Double]
    let findings: [DiagnosticFinding]
    let observationGaps: [String]
    let limitations: [String]
    let artifacts: [DiagnosticArtifact]

    init(_ report: SessionDiagnostic) {
        schemaVersion = report.schemaVersion; summary = report.summary
        observations = report.observations; findings = report.findings
        observationGaps = report.observationGaps; limitations = report.limitations; artifacts = report.artifacts
    }
}

/// Findings select an investigation. They do not establish a performance regression or its cause.
enum SessionDiagnostics {
    static func intervals(_ rows: [[String: Any]], source: String) -> [DiagnosticInterval] {
        rows.compactMap { row in
            let ended = SessionAnalysis.number(row["recorded_at"]) ?? (row["recorded_at"] as? String)
                .flatMap(NativeMeasurements.date)?.timeIntervalSince1970
            guard let ended, let seconds = SessionAnalysis.number(row["window_seconds"]), seconds > 0 else { return nil }
            return DiagnosticInterval(source: source, startedAt: ended - seconds, endedAt: ended)
        }
    }
    static func data(_ file: URL, limit: Int = 16 * 1024 * 1024) throws -> Data {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit + 1
        guard size <= limit else { throw DiagnosticEvidenceError.tooLarge }
        let data = try Data(contentsOf: file)
        guard data.count <= limit else { throw DiagnosticEvidenceError.tooLarge }
        return data
    }

    static func responsiveness(at file: URL, report: [String: Any]) throws -> [[String: Any]] {
        let text = String(decoding: try data(file, limit: 1024 * 1024), as: UTF8.self)
        return try text.split(separator: "\n").map { line in
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  SessionAnalysis.number(row["schema_version"]) == 1,
                  row["session_id"] as? String == report["session_id"] as? String,
                  SessionAnalysis.number(row["pid"]) == SessionAnalysis.number(report["app.pid"]),
                  let ended = SessionAnalysis.number(row["recorded_at"]),
                  let started = SessionAnalysis.number(report["run.started_at"]),
                  let duration = SessionAnalysis.number(report["app.duration_seconds"]),
                  ended >= started, ended <= started + duration + 1,
                  let seconds = SessionAnalysis.number(row["window_seconds"]), seconds >= 5,
                  seconds <= ended - started + 1 else {
                throw DiagnosticEvidenceError.invalidResponsivenessIdentity
            }
            for key in ["main_queue.delay_max_ms", "main_queue.pending_age_max_ms", "main_thread.cpu.utilization", "process.cpu.utilization"] {
                if row[key] != nil {
                    guard let number = SessionAnalysis.number(row[key]), number >= 0 else {
                        throw DiagnosticEvidenceError.invalidResponsivenessField(key)
                    }
                }
            }
            return row
        }
    }

    static func make(report: [String: Any], folder: URL, windows: [[String: Any]], responsiveness: [[String: Any]],
                     cpu: CPUProfileSummary?, artifacts: [DiagnosticArtifact], gaps: [String]) -> SessionDiagnostic {
        var observations: [String: Double] = ["frame.windows": Double(windows.count), "responsiveness.windows": Double(responsiveness.count)]
        var findings: [DiagnosticFinding] = []
        var missing = (report["issues"] as? [String] ?? []) + gaps
        let frames = windows.compactMap { SessionAnalysis.number($0["frames"]) }.reduce(0, +)
        let slow = windows.compactMap { SessionAnalysis.number($0["frames_over_25_ms"]) }.reduce(0, +)
        if frames > 0 {
            observations["frames.observed"] = frames; observations["frames.over_25ms"] = slow
            observations["frames.over_25ms_fraction"] = slow / frames
            observations["frame.worst_window_p95_ms"] = windows.compactMap { SessionAnalysis.number($0["frame_interval_p95_ms"]) }.max()
            if slow > 0 {
                findings.append(DiagnosticFinding(id: "slow_callback_intervals", observation: "Renderer callbacks include intervals above 25 ms.",
                    signals: ["frames.over_25ms": slow, "frames.over_25ms_fraction": slow / frames],
                    nextInvestigation: "Inspect the affected interval in Metal presentation evidence and correlate CPU activity. Callback cadence does not prove a missed display deadline.",
                    intervals: intervals(windows.filter { (SessionAnalysis.number($0["frames_over_25_ms"]) ?? 0) > 0 }, source: "sdk.frame_recorder")))
            }
        } else { missing.append("No complete renderer windows. This report cannot assess callback cadence.") }
        let stalled = responsiveness.filter {
            max(SessionAnalysis.number($0["main_queue.delay_max_ms"]) ?? 0,
                SessionAnalysis.number($0["main_queue.pending_age_max_ms"]) ?? 0) >= 100
        }
        if !stalled.isEmpty {
            let maxDelay = stalled.map { max(SessionAnalysis.number($0["main_queue.delay_max_ms"]) ?? 0,
                SessionAnalysis.number($0["main_queue.pending_age_max_ms"]) ?? 0) }.max()!
            observations["main_queue.worst_delay_ms"] = maxDelay
            let cpuValues = stalled.compactMap { SessionAnalysis.number($0["main_thread.cpu.utilization"]) }
            let cpuPeak = cpuValues.max()
            if let cpuPeak { observations["main_thread.cpu_peak_in_stall_windows"] = cpuPeak }
            let busy = cpuPeak.map { $0 >= 0.5 } ?? false
            findings.append(DiagnosticFinding(id: "main_queue_delay", observation: "A main-queue probe took at least 100 ms or remained pending that long.",
                signals: observations.filter { $0.key.hasPrefix("main_") },
                nextInvestigation: busy ? "Inspect main-thread Time Profiler call paths within the delayed interval. High average CPU in this window suggests expensive work." :
                    "Inspect the delayed interval with System Trace or Swift Concurrency. Low or unavailable window CPU does not identify a blocking resource.",
                intervals: intervals(stalled, source: "sdk.main_thread_monitor")))
        }
        if responsiveness.isEmpty { missing.append("No retained responsiveness windows. Renderer preparation does not measure all main-thread work.") }
        if let cpu {
            observations["cpu.running_samples"] = Double(cpu.samples)
            observations["cpu.unresolved_leaf_samples"] = Double(cpu.unresolvedSamples)
            observations["cpu.partial_path_samples"] = Double(cpu.partialPathSamples)
            observations["cpu.main_thread_sampled_weight_ms"] = cpu.mainThreadWeightNanoseconds / 1_000_000
            if cpu.samples == 0 { missing.append("The CPU capture contains no selected running samples.") }
            if cpu.unresolvedSamples > 0 || cpu.partialPathSamples > 0 {
                missing.append("Some CPU symbols or call paths are unavailable. Retain the matching binary and dSYM for Instruments.")
            }
            if cpu.callPaths.isEmpty { missing.append("The CPU summary contains no caller paths.") }
        } else { missing.append("No decoded CPU recording. SDK CPU ratios cannot identify expensive functions.") }
        if !artifacts.contains(where: { $0.kind == "gpu" }) {
            missing.append("No GPU replay evidence. GPU command sums do not measure utilization or presentation latency.")
        }
        let requested = report["profile.requested"] as? String ?? "none"
        if requested != "none" { missing.append("This run requested a profiler. Use an unprofiled matched Release run for a performance baseline.") }
        let limitations = [
            "The 25 ms callback and 100 ms queue thresholds select investigations. They are not display budgets or regression gates.",
            "CPU ratios average five-second windows. A stall and CPU activity in the same window may not occur at the same instant.",
            "Sampled call paths describe running work. Their weights are not wall time, blocked time, or a chronological flame graph.",
            "CPU path fractions use all running weight in their main or background thread scope. Partial and unresolved samples remain in that denominator.",
            "Apple captures remain on this Mac. A retained artifact does not imply successful delivery to Logfire."
        ]
        return SessionDiagnostic(summary: findings.isEmpty ? "No investigation threshold was crossed in the available windows. Missing evidence still limits this result." :
            "Available evidence suggests \(findings.count) investigation(s). Confirm each cause in the affected interval.",
            observations: observations, findings: findings, observationGaps: Array(Set(missing)).sorted(),
            limitations: limitations, artifacts: artifacts, cpuCallPaths: cpu?.callPaths ?? [])
    }

    static func build(report: [String: Any], folder: URL, windows: [[String: Any]]) -> SessionDiagnostic {
        var gaps: [String] = []
        var artifacts: [DiagnosticArtifact] = []
        var response: [[String: Any]] = []
        var cpu: CPUProfileSummary?
        let responseFile = folder.appendingPathComponent("responsiveness.jsonl")
        if FileManager.default.fileExists(atPath: responseFile.path) {
            do {
                response = try responsiveness(at: responseFile, report: report)
                artifacts.append(DiagnosticArtifact(kind: "responsiveness", path: responseFile.path))
            } catch { gaps.append("Retained responsiveness evidence is invalid or belongs to another run.") }
        }
        let profile = folder.appendingPathComponent("profile")
        // Manifests are two levels below profile. Do not scan the contents of Apple's recording bundles.
        do {
            let groups = FileManager.default.fileExists(atPath: profile.path) ? try FileManager.default.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil) : []
            guard groups.count <= 8 else { throw CompanionError.message("Too many profile groups") }
            for group in groups {
                let captures = try FileManager.default.contentsOfDirectory(at: group, includingPropertiesForKeys: nil)
                guard captures.count <= 8 else { throw CompanionError.message("Too many captures") }
                for capture in captures {
                    let manifest = capture.appendingPathComponent("manifest.json")
                    guard manifest.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else {
                        throw CompanionError.message("Profile evidence is outside the run directory")
                    }
                    if !FileManager.default.fileExists(atPath: manifest.path) {
                        let trace = capture.appendingPathComponent("Instruments.trace")
                        if FileManager.default.fileExists(atPath: trace.path) { artifacts.append(DiagnosticArtifact(kind: "cpu-recording-unanalysed", path: trace.path)) }
                        continue
                    }
                    guard let values = try JSONSerialization.jsonObject(with: data(manifest)) as? [String: Any],
                          values["session_id"] as? String == report["session_id"] as? String,
                          values["binary.sha256"] as? String == report["binary.sha256"] as? String,
                          SessionAnalysis.number(values["process.pid"]) == SessionAnalysis.number(report["app.pid"]) else {
                        throw CompanionError.message("Profile manifest does not identify this run")
                    }
                    if var summary = values["cpu.summary"] as? [String: Any] {
                        guard cpu == nil else { throw CompanionError.message("More than one CPU recording requires separate reports") }
                        let export = capture.appendingPathComponent("cpu.xml")
                        if (summary["callPaths"] == nil || values["cpu.summary_available"] as? Bool == false),
                           FileManager.default.fileExists(atPath: export.path) {
                            let pid = Int32(SessionAnalysis.number(report["app.pid"])!)
                            let toc = capture.appendingPathComponent("toc.xml")
                            let hashes = values["artifacts"] as? [String: String] ?? [:]
                            for file in [toc, export] {
                                guard file.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
                                      hashes[file.lastPathComponent] == (try Companion.fileHash(file)) else {
                                    throw CompanionError.message("CPU export checksum does not match its capture manifest")
                                }
                            }
                            let interval = try InstrumentsXML.recording(data(toc), pid: pid)
                            guard interval["profile.started_at"] as? String == values["profile.started_at"] as? String,
                                  interval["profile.ended_at"] as? String == values["profile.ended_at"] as? String else {
                                throw CompanionError.message("CPU export interval does not match its capture manifest")
                            }
                            cpu = try InstrumentsXML.cpu(data(export, limit: 64 * 1024 * 1024), pid: pid)
                        }
                        for key in ["pathSamples", "partialPathSamples"] where summary[key] == nil { summary[key] = 0 }
                        if summary["callPaths"] == nil { summary["callPaths"] = [] }
                        if cpu == nil { cpu = try JSONDecoder().decode(CPUProfileSummary.self, from: JSONSerialization.data(withJSONObject: summary)) }
                        artifacts.append(DiagnosticArtifact(kind: "cpu", path: manifest.path))
                    } else if values["gpu.measurements"] != nil {
                        artifacts.append(DiagnosticArtifact(kind: "gpu", path: manifest.path))
                        gaps += values["issues"] as? [String] ?? []
                    } else if values["capture.measurements"] != nil {
                        let kind = values["capture.shader_timeline_requested"] as? Bool == true ? "shader" : "native"
                        artifacts.append(DiagnosticArtifact(kind: kind, path: manifest.path))
                    } else if FileManager.default.fileExists(atPath: capture.appendingPathComponent("Instruments.trace").path) {
                        artifacts.append(DiagnosticArtifact(kind: "cpu-recording", path: capture.appendingPathComponent("Instruments.trace").path))
                    }
                }
            }
        } catch { gaps.append("Some profiler manifests are invalid or unavailable. Inspect retained recordings.") }
        for (kind, name) in [("frames", "performance.jsonl"), ("host", "host-samples.json"), ("scenario", "scenario.json")] {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { artifacts.append(DiagnosticArtifact(kind: kind, path: file.path)) }
        }
        return make(report: report, folder: folder, windows: windows, responsiveness: response, cpu: cpu, artifacts: artifacts, gaps: gaps)
    }

    static func object(_ diagnostic: SessionDiagnostic) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any] ?? [:]
    }

    static func publish(_ diagnostic: SessionDiagnostic, client: Logfire, context: [String: Any]) throws {
        client.event("development.diagnostic.summary", attributes: try Companion.attributes(context.merging([
            "diagnostic.schema_version": diagnostic.schemaVersion, "diagnostic.summary": diagnostic.summary,
            "diagnostic.findings": diagnostic.findings.count, "diagnostic.observation_gaps": diagnostic.observationGaps.count,
        ]) { _, value in value }).merging(Companion.structuredAttribute("diagnostic.details", encoded: DiagnosticDetails(diagnostic), type: "object")) { _, structured in structured })
        for finding in diagnostic.findings {
            var attributes = Companion.attributes(context.merging([
                "diagnostic.finding_id": finding.id, "diagnostic.observation": finding.observation,
                "diagnostic.next_investigation": finding.nextInvestigation,
            ]) { _, value in value }.merging(finding.signals) { _, value in value })
            attributes.merge(try Companion.structuredAttribute("diagnostic.intervals", encoded: finding.intervals, type: "array")) { _, structured in structured }
            client.event("development.diagnostic.finding", attributes: attributes)
        }
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments == ["--help"] {
            print("Usage: logfire-apple diagnose --report REPORT. Rebuild a local diagnostic report without launching an app or exporting telemetry.")
            return 0
        }
        guard arguments.count == 2, arguments[0] == "--report" else { throw CompanionError.message("Use diagnose --report REPORT") }
        let file = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        guard var report = try JSONSerialization.jsonObject(with: data(file)) as? [String: Any],
              SessionAnalysis.number(report["schema_version"]) == 1,
              let session = report["session_id"] as? String, UUID(uuidString: session) != nil,
              let pid = SessionAnalysis.number(report["app.pid"]), pid.rounded() == pid, pid > 0, pid <= Double(Int32.max),
              let started = SessionAnalysis.number(report["run.started_at"]), started >= 0,
              let duration = SessionAnalysis.number(report["app.duration_seconds"]), duration >= 0 else {
            throw DiagnosticEvidenceError.invalidRunReport
        }
        let folder = file.deletingLastPathComponent()
        let frames = folder.appendingPathComponent("performance.jsonl")
        let windows: [[String: Any]]
        if FileManager.default.fileExists(atPath: frames.path) {
            do { _ = try data(frames, limit: 1024 * 1024); windows = try SessionAnalysis.windows(at: frames) }
            catch { windows = []; report["issues"] = (report["issues"] as? [String] ?? []) + ["Frame evidence is invalid."] }
        } else { windows = [] }
        let diagnostic = build(report: report, folder: folder, windows: windows)
        report["diagnostic"] = try object(diagnostic)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        print(diagnostic.summary)
        for finding in diagnostic.findings { print("\(finding.id): \(finding.nextInvestigation)") }
        print("Diagnostic report: \(file.path)")
        return 0
    }
}
#endif

import Foundation
import LogfireSwift
import OpenTelemetryApi
#if os(macOS)
import Darwin

enum ScenarioError: Error, Equatable, CustomStringConvertible {
    case payloadTooLarge(String)
    case invalidDefinition(String)
    case reservedEnvironmentKey(String)
    case invalidStatus(String)
    case missingOptionValue(String)
    case unknownOption(String)
    case invalidOptionValue(String)
    case missingRequiredOption(String)

    var description: String {
        switch self {
        case .payloadTooLarge(let kind): return "Scenario \(kind) exceeds 64 KiB"
        case .invalidDefinition(let field): return "Invalid scenario definition field: \(field)"
        case .reservedEnvironmentKey(let key): return "Scenario environment cannot override reserved key: \(key)"
        case .invalidStatus(let field): return "Scenario status does not identify this ready application run: \(field)"
        case .missingOptionValue(let flag): return "Missing value for \(flag)"
        case .unknownOption(let flag): return "Unknown run option \(flag)"
        case .invalidOptionValue(let flag): return "Invalid value for \(flag). Use --seconds between 1 and 300 or --profile cpu|gpu|shader"
        case .missingRequiredOption(let flag): return "Supply \(flag) for the scenario run"
        }
    }
}

enum ScenarioOutcome: Equatable {
    case passed, incomplete, assertionFailed, timedOut
    case processFailed(Int32), interrupted(Int32)

    var exitCode: Int32 {
        switch self {
        case .passed: return 0
        case .incomplete: return 2
        case .assertionFailed: return 1
        case .timedOut: return 124
        case .processFailed(let code), .interrupted(let code): return code
        }
    }
    var status: String {
        switch self {
        case .passed: return "passed"
        case .incomplete: return "incomplete"
        default: return "failed"
        }
    }
    static func evaluate(result: CommandResult, phase: String?, windows: Int, required: Bool, issues: [String],
                         failure: Bool = false, completedLate: Bool = false, analysisInterruption: Int32? = nil) -> Self {
        if let analysisInterruption { return .interrupted(analysisInterruption) }
        if result.timedOut || completedLate { return .timedOut }
        let code = result.requestedStop && [0, 143].contains(result.exitCode) ? 0 : result.exitCode
        if [130, 143].contains(code) { return .interrupted(code) }
        if code != 0 { return .processFailed(code) }
        if failure { return .assertionFailed }
        guard phase == "passed", !required || windows > 0 else { return .assertionFailed }
        return issues.isEmpty ? .passed : .incomplete
    }
}

struct ScenarioDefinition: Codable {
    let schemaVersion: Int
    let id: String
    let arguments: [String]
    let environment: [String: String]
    let requireFrameWindows: Bool
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, arguments, environment
        case requireFrameWindows = "require_frame_windows"
    }
    static func load(_ url: URL) throws -> ScenarioDefinition {
        let data = try Data(contentsOf: url)
        guard data.count <= 65536 else { throw ScenarioError.payloadTooLarge("definition") }
        let definition = try JSONDecoder().decode(Self.self, from: data)
        try definition.validate()
        return definition
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw ScenarioError.invalidDefinition("schema_version") }
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
            throw ScenarioError.invalidDefinition("id")
        }
        guard arguments.count <= 32 else { throw ScenarioError.invalidDefinition("arguments.count") }
        for (index, argument) in arguments.enumerated() {
            guard argument.utf8.count <= 2048, !argument.contains("\0") else {
                throw ScenarioError.invalidDefinition("arguments[\(index)]")
            }
        }
        guard environment.count <= 32 else { throw ScenarioError.invalidDefinition("environment.count") }
        for (key, value) in environment {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil else {
                throw ScenarioError.invalidDefinition("environment.key")
            }
            guard !["LOGFIRE_", "OTEL_", "MTL_", "METAL_"].contains(where: key.hasPrefix), key != "NEON_PERF_REPORT" else {
                throw ScenarioError.reservedEnvironmentKey(key)
            }
            guard value.utf8.count <= 2048, !value.contains("\0") else {
                throw ScenarioError.invalidDefinition("environment[\(key)]")
            }
        }
    }
}

struct ScenarioRunOptions {
    var app: URL?
    var scenario: URL?
    var seconds: Double = 20
    var profile: String?
    var local = false
    var output = URL(fileURLWithPath: ".xcode-observe/runs", isDirectory: true)
    init(_ arguments: [String]) throws {
        var i = 0
        while i < arguments.count {
            let flag = arguments[i]
            if flag == "--no-telemetry" { local = true; i += 1; continue }
            guard i + 1 < arguments.count else { throw ScenarioError.missingOptionValue(flag) }
            let value = arguments[i + 1]
            switch flag {
            case "--app": app = URL(fileURLWithPath: value)
            case "--scenario": scenario = URL(fileURLWithPath: value)
            case "--seconds":
                guard let number = Double(value), number.isFinite, (1...300).contains(number) else { throw ScenarioError.invalidOptionValue(flag) }
                seconds = number
            case "--profile":
                guard ["cpu", "gpu", "shader"].contains(value) else { throw ScenarioError.invalidOptionValue(flag) }
                profile = value
            case "--output": output = URL(fileURLWithPath: value)
            default: throw ScenarioError.unknownOption(flag)
            }
            i += 2
        }
        guard app != nil else { throw ScenarioError.missingRequiredOption("--app") }
        guard scenario != nil else { throw ScenarioError.missingRequiredOption("--scenario") }
    }
}

struct ScenarioSignal: Decodable {
    struct Delivery: Decodable {
        let enabled: Bool
        let exportedSpans: Int
        let failedSpans: Int
        let failedRequests: Int?
        let retriedRequests: Int?
        let lastFailure: String?
        enum CodingKeys: String, CodingKey {
            case enabled, exportedSpans = "exported_spans", failedSpans = "failed_spans"
            case failedRequests = "failed_requests", retriedRequests = "retried_requests", lastFailure = "last_failure"
        }
    }
    let schemaVersion: Int
    let scenarioID: String
    let sessionID: String
    let pid: Int32
    let ready: Bool
    let phase: String
    let recordedAt: Double
    let details: [String: String]
    struct MetricDelivery: Decodable {
        let enabled: Bool
        let exportedMetrics: Int
        let failedMetrics: Int
        enum CodingKeys: String, CodingKey { case enabled, exportedMetrics = "exported_metrics", failedMetrics = "failed_metrics" }
    }
    let delivery: Delivery?
    let metricDelivery: MetricDelivery?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", scenarioID = "scenario_id", sessionID = "session_id"
        case pid, ready, phase, recordedAt = "recorded_at", details, delivery, metricDelivery = "metric_delivery"
    }
    static func read(_ url: URL, id: String, session: NativeSession) throws -> ScenarioSignal {
        let data = try Data(contentsOf: url)
        guard data.count <= 65536 else { throw ScenarioError.payloadTooLarge("status") }
        let signal = try JSONDecoder().decode(Self.self, from: data)
        for (field, valid) in [("schema_version", signal.schemaVersion == 1), ("scenario_id", signal.scenarioID == id),
            ("session_id", signal.sessionID == session.id), ("pid", signal.pid == session.pid), ("ready", signal.ready),
            ("phase", ["ready", "passed", "failed"].contains(signal.phase)),
            ("recorded_at", signal.recordedAt.isFinite && signal.recordedAt >= session.started && signal.recordedAt <= Date().timeIntervalSince1970 + 1)] {
            guard valid else { throw ScenarioError.invalidStatus(field) }
        }
        return signal
    }
}

/// The app owns scenario assertions. The companion owns lifetime and evidence.
enum ScenarioRun {
    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.contains("--help") {
            print("Usage: logfire-apple run --app APP --scenario FILE [--seconds 20] [--profile cpu|gpu|shader] [--no-telemetry] [--output DIRECTORY]")
            print("The app must publish session identity, readiness, and completion. Profiling is optional and has a separate bounded duration.")
            return 0
        }
        let options = try ScenarioRunOptions(arguments)
        let definition = try ScenarioDefinition.load(options.scenario!)
        guard let bundle = Bundle(url: options.app!), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw CompanionError.message("Supply a built macOS app") }
        let build = Logfire.buildMetadata(bundle: bundle)
        let id = UUID().uuidString
        let folder = options.output.appendingPathComponent(id).standardizedFileURL
        let sessions = folder.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let status = folder.appendingPathComponent("scenario.json")
        let client = Companion.client(local: options.local, service: "logfire-apple-run", resource: build.merging(["session_id": id, "scenario.id": definition.id]) { _, run in run })
        let context: [String: Any] = build.merging(["scenario.id": definition.id, "binary.sha256": try Companion.fileHash(executable)]) { _, value in value }
            .reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
            .merging(["session_id": id, "measurement.source": "native.scenario_runner"]) { _, value in value }
        var environment = ProcessInfo.processInfo.environment.filter {
            !["LOGFIRE_", "OTEL_", "MTL_", "METAL_", "DYLD_", "XCTest", "XCTEST_"].contains(where: $0.key.hasPrefix) && $0.key != "NEON_PERF_REPORT"
        }
        environment.merge(definition.environment) { _, value in value }
        environment.merge(["LOGFIRE_DEV_DIRECT": client.delivery.enabled ? "1" : "0", "LOGFIRE_SESSION_ID": id,
            "LOGFIRE_SESSION_DIR": sessions.path, "LOGFIRE_SCENARIO_ID": definition.id, "LOGFIRE_SCENARIO_STATUS": status.path]) { _, value in value }
        if options.profile == "gpu" { environment["MTL_CAPTURE_ENABLED"] = "1" }
        if options.profile == "shader" {
            environment["MTL_HUD_ENABLED"] = "1"
            environment["MTL_HUD_LOG_SHADER_ENABLED"] = "1"
        }
        var session: NativeSession?
        var signal: ScenarioSignal?
        var issues: [String] = []
        if !options.local, !client.delivery.enabled { issues.append("Telemetry is unavailable. Configure the project write token on this Mac.") }
        var failure: String?
        var host = SessionHostSamples()
        var pid: Int32 = 0
        var processStarted: Double?
        var readyElapsed: Double?
        var readinessObservation = "polled"
        var profiled = false
        var capturedGPU: CapturedGPUWorkload?
        var capturedCPU: CapturedCPURecording?
        var appDuration: Double = 0
        var analysisDuration: Double = 0
        var analysisInterruption: Int32?
        var retained: [String: Any] = [:]
        var finalOutcome = ScenarioOutcome.processFailed(127)
        let began = ProcessInfo.processInfo.systemUptime
        let beganDate = Date()
        // This runner owns the unreaped child. Its PID cannot be reused during status polling.
        // Verify the marker against the retained launch identity even if the app has just exited.
        func readSession() throws -> NativeSession {
            let marker = sessions.appendingPathComponent("\(pid).json")
            let candidate = try NativeSession(marker: JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any] ?? [:], verify: false)
            guard let processStarted, candidate.started >= processStarted, candidate.started - processStarted < 60,
                  candidate.id == id, candidate.pid == pid, candidate.executable.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath(),
                  build["build.id"] == candidate.metadata["build.id"] as? String else {
                throw CompanionError.message("SDK identity does not match the launched app")
            }
            return candidate
        }
        var result = CommandResult(exitCode: 127, timedOut: false, requestedStop: false)
        try client.withSpan("development.run", attributes: Companion.attributes(context)) {
            let runSpan = OpenTelemetry.instance.contextProvider.activeSpan
            let runParent = client.activeTraceParent
            if let runParent { environment["LOGFIRE_TRACE_PARENT"] = runParent }
            do {
                result = try CommandRunner.run(executable.path, definition.arguments, output: folder.appendingPathComponent("console.log"),
                    errors: folder.appendingPathComponent("console.stderr"), environment: environment, seconds: options.seconds,
                    onLaunch: {
                        pid = $0
                        var info = proc_bsdinfo()
                        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else {
                            throw CompanionError.message("Cannot retain the launched process identity")
                        }
                        processStarted = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
                    }, onTick: {
                        let marker = sessions.appendingPathComponent("\(pid).json")
                        if session == nil, FileManager.default.fileExists(atPath: marker.path) {
                            session = try readSession()
                        }
                        host.tick(client: client, context: context.merging(["process.pid": pid]) { _, value in value })
                        guard let session, FileManager.default.fileExists(atPath: status.path) else { return false }
                        signal = try ScenarioSignal.read(status, id: definition.id, session: session)
                        if readyElapsed == nil { readyElapsed = ProcessInfo.processInfo.systemUptime - began }
                        if !profiled, let profile = options.profile {
                            profiled = true
                            var args = ["--sessions", sessions.path, "--output", folder.appendingPathComponent("profile").path]
                            if options.local { args += ["--no-telemetry"] }
                            do {
                                let remaining = max(0.1, options.seconds - (ProcessInfo.processInfo.systemUptime - began))
                                if profile == "cpu" {
                                    capturedCPU = try client.withSpan("development.cpu.record", attributes: Companion.attributes(context)) {
                                        try InstrumentsProfile.record(args + ["--seconds", "5"], timeout: remaining, onTick: {
                                            host.tick(client: client, context: context.merging(["process.pid": pid]) { _, value in value })
                                            return false
                                        })
                                    }
                                } else if profile == "gpu" {
                                    capturedGPU = try client.withSpan("development.gpu.capture", attributes: Companion.attributes(context)) {
                                        try GPUCapture.capture(GPUCaptureOptions(args + ["--profile"]), seconds: min(30, remaining))
                                    }
                                }
                            } catch { issues.append("Optional \(profile) profile failed. Inspect retained profile evidence.") }
                            // Profiling may span scenario completion. Read the app's latest assertion before stopping it.
                            signal = try ScenarioSignal.read(status, id: definition.id, session: session)
                        }
                        return signal?.phase == "passed" || signal?.phase == "failed"
                    })
            } catch {
                result = CommandResult(exitCode: 1, timedOut: false, requestedStop: false)
                failure = "Run identity or scenario protocol failed. Inspect retained SDK marker, status, and console output."
            }
            appDuration = ProcessInfo.processInfo.systemUptime - began
            // The runner reaps the app before either profiler analyzes its recording.
            let interruptedRun = !result.requestedStop && [130, 143].contains(result.exitCode)
            if interruptedRun, capturedCPU != nil || capturedGPU != nil {
                issues.append("Profile analysis was skipped after run interruption. The recording remains local.")
            }
            if let capturedCPU, !interruptedRun {
                let analysisStarted = ProcessInfo.processInfo.systemUptime
                do {
                    let code = try client.withSpan("development.cpu.analysis", attributes: Companion.attributes(context)) { try InstrumentsProfile.analyze(capturedCPU) }
                    if code != 0 {
                        issues.append("Optional CPU profile is incomplete. Inspect retained profile evidence.")
                    }
                } catch CompanionError.interrupted(let code) {
                    analysisInterruption = code
                    issues.append("CPU analysis was interrupted. The recording remains local.")
                } catch { issues.append("Optional CPU analysis failed. Inspect retained profile evidence.") }
                analysisDuration = ProcessInfo.processInfo.systemUptime - analysisStarted
            }
            if let capturedGPU, !interruptedRun {
                let analysisStarted = ProcessInfo.processInfo.systemUptime
                do {
                    let code = try client.withSpan("development.gpu.analysis", attributes: Companion.attributes(context)) { try GPUCapture.analyze(capturedGPU) }
                    if code != 0 {
                        issues.append("Optional GPU profile is incomplete. Inspect retained profile evidence.")
                    }
                } catch CompanionError.interrupted(let code) {
                    analysisInterruption = code
                    issues.append("GPU analysis was interrupted. The recording remains local.")
                } catch { issues.append("Optional GPU analysis failed. Inspect retained profile evidence.") }
                analysisDuration = ProcessInfo.processInfo.systemUptime - analysisStarted
            }
            if failure == nil {
                do {
                    guard try Companion.fileHash(executable) == context["binary.sha256"] as? String,
                          Logfire.buildMetadata(bundle: bundle) == build else {
                        throw CompanionError.message("The app on disk changed during the scenario")
                    }
                } catch { failure = "The app identity changed or became unavailable during the scenario." }
            }
            // The process can exit between polls. Its final atomic assertion still needs validation.
            if failure == nil, FileManager.default.fileExists(atPath: status.path) {
                do {
                    let retainedSession = try readSession()
                    signal = try ScenarioSignal.read(status, id: definition.id, session: retainedSession)
                    if readyElapsed == nil {
                        readyElapsed = signal!.recordedAt - beganDate.timeIntervalSince1970
                        readinessObservation = "terminal-assertion"
                    }
                }
                catch { failure = "Final scenario assertion is invalid." }
            }
            if options.profile == "shader", let session, !interruptedRun {
                let analysisStarted = ProcessInfo.processInfo.systemUptime
                do {
                    guard session.id == id, session.pid == pid,
                          try Companion.fileHash(executable) == context["binary.sha256"] as? String else {
                        throw CompanionError.message("Retained shader capture identity changed")
                    }
                    let shaderFolder = folder.appendingPathComponent("profile").appendingPathComponent(session.id).appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: shaderFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let end = beganDate.addingTimeInterval(appDuration)
                    let measurements = try client.withSpan("development.shader.analysis", attributes: Companion.attributes(context)) {
                        // The runner already verified and reaped this process. Limit lookback to its owned lifetime.
                        try Companion.capture(session: session, folder: shaderFolder, seconds: appDuration, client: client,
                            interval: beganDate...end, validateLiveSession: false, includeShaderTimeline: true)
                    }
                    if !measurements.contains(where: { $0["measurement.scope"] as? String == "shader_compiler_update" }) {
                        issues.append("Apple's capture has no shader compiler measurements.")
                    }
                } catch CompanionError.interrupted(let code) {
                    analysisInterruption = code
                    issues.append("Shader analysis was interrupted. The recording remains local.")
                } catch { issues.append("Optional shader analysis failed. Inspect retained profile evidence.") }
                analysisDuration = ProcessInfo.processInfo.systemUptime - analysisStarted
            }
            if signal?.phase != "passed", failure == nil { failure = result.timedOut ? "Scenario deadline expired." : "No successful scenario completion." }
            if readyElapsed == nil, failure == nil { failure = "No readiness signal was observed." }
            let completedLate = signal.map { $0.phase != "ready" && $0.recordedAt > beganDate.timeIntervalSince1970 + options.seconds } ?? false
            if completedLate { failure = "Scenario completion exceeded its deadline." }
            if options.profile != nil, !profiled { issues.append("Requested profile could not start before the app exited.") }
            if let delivery = signal?.delivery, delivery.failedSpans > 0 { issues.append("App telemetry delivery failed for some records.") }
            if let delivery = signal?.metricDelivery, delivery.failedMetrics > 0 { issues.append("App metrics delivery failed for some instruments.") }
            let windows: [[String: Any]]
            let frames = folder.appendingPathComponent("performance.jsonl")
            if FileManager.default.fileExists(atPath: frames.path) {
                do { windows = try SessionAnalysis.windows(at: frames) }
                catch { windows = []; issues.append("Frame evidence is invalid.") }
            } else { windows = [] }
            if definition.requireFrameWindows, windows.isEmpty { failure = "Scenario requires a complete renderer window." }
            if let failure { issues.insert(failure, at: 0) }
            try host.write(to: folder.appendingPathComponent("host-samples.json"))
            let outcome = ScenarioOutcome.evaluate(result: result, phase: signal?.phase, windows: windows.count,
                required: definition.requireFrameWindows, issues: issues, failure: failure != nil,
                completedLate: completedLate, analysisInterruption: analysisInterruption)
            let code = outcome.exitCode
            var report: [String: Any] = context.merging([
                "schema_version": 1, "status": outcome.status,
                "exit_code": code, "app.exit_code": result.exitCode, "app.pid": pid, "app.requested_stop": result.requestedStop,
                "run.started_at": beganDate.timeIntervalSince1970, "run.duration_seconds": ProcessInfo.processInfo.systemUptime - began,
                "app.duration_seconds": appDuration, "profile.analysis.duration_seconds": analysisDuration,
                "run.deadline_seconds": options.seconds, "scenario.phase": signal?.phase ?? "missing", "scenario.details": signal?.details ?? [:],
                "readiness.seconds": readyElapsed as Any? ?? NSNull(), "frame.windows": windows.count,
                "readiness.observation": readinessObservation,
                "host.samples": host.records.count, "profile.requested": options.profile ?? "none", "profile.attempted": profiled,
                "issues": issues, "telemetry.app_direct_enabled": client.delivery.enabled,
                "scenario.arguments": definition.arguments, "scenario.environment": definition.environment,
                "profile.directory": profiled ? folder.appendingPathComponent("profile").path : "",
                "app.delivery": signal?.delivery.map {
                    ["enabled": $0.enabled, "exported_spans": $0.exportedSpans, "failed_spans": $0.failedSpans,
                     "failed_requests": $0.failedRequests as Any? ?? NSNull(), "retried_requests": $0.retriedRequests as Any? ?? NSNull(),
                     "last_failure": $0.lastFailure as Any? ?? NSNull()] as [String: Any]
                } as Any? ?? NSNull(),
            ]) { _, value in value }
            if let runParent { report["trace_id"] = runParent.components(separatedBy: "-")[1] }
            let diagnostic = SessionDiagnostics.build(report: report, folder: folder, windows: windows)
            report["diagnostic"] = try SessionDiagnostics.object(diagnostic)
            try SessionDiagnostics.publish(diagnostic, client: client, context: context)
            runSpan?.setAttribute(key: "app.duration_seconds", value: appDuration)
            runSpan?.setAttribute(key: "profile.analysis.duration_seconds", value: analysisDuration)
            runSpan?.setAttribute(key: "run.exit_code", value: Int(code))
            runSpan?.setAttribute(key: "scenario.phase", value: signal?.phase ?? "missing")
            if code != 0 {
                runSpan?.status = .error(description: analysisInterruption != nil ? "Profiler analysis interrupted" :
                    outcome == .incomplete ? "Requested observation is incomplete" : "Development scenario failed")
            }
            client.event("development.run.summary", attributes: Companion.attributes(context.merging([
                "run.exit_code": code, "scenario.phase": signal?.phase ?? "missing", "frame.windows": windows.count,
                "run.observation_gaps": issues.count, "profile.requested": options.profile ?? "none",
                "run.duration_seconds": ProcessInfo.processInfo.systemUptime - began,
                "app.duration_seconds": appDuration, "profile.analysis.duration_seconds": analysisDuration,
                "readiness.seconds": readyElapsed as Any? ?? NSNull(),
                "app.delivery.exported_spans": signal?.delivery?.exportedSpans as Any? ?? NSNull(),
                "app.delivery.failed_spans": signal?.delivery?.failedSpans as Any? ?? NSNull(),
                "app.delivery.failed_requests": signal?.delivery?.failedRequests as Any? ?? NSNull(),
                "app.delivery.retried_requests": signal?.delivery?.retriedRequests as Any? ?? NSNull(),
                "app.delivery.last_failure": signal?.delivery?.lastFailure as Any? ?? NSNull(),
                "app.metric_delivery.failed_metrics": signal?.metricDelivery?.failedMetrics as Any? ?? NSNull(),
            ]) { _, value in value }))
            retained = report
            finalOutcome = outcome
        }
        client.flush(); Companion.printDelivery(client)
        if client.delivery.enabled, client.delivery.failedSpans > 0 || client.delivery.exportedSpans < host.records.count + 2 {
            retained["issues"] = issues + ["Runner telemetry was not fully acknowledged."]
            if finalOutcome == .passed { finalOutcome = .incomplete }
        }
        if let delivery = client.metrics?.delivery {
            retained["runner.metric_delivery"] = ["enabled": delivery.enabled, "exported_metrics": delivery.exportedMetrics, "failed_metrics": delivery.failedMetrics]
            if delivery.failedMetrics > 0 {
                retained["issues"] = (retained["issues"] as? [String] ?? []) + ["Runner metrics delivery failed."]
                if finalOutcome == .passed { finalOutcome = .incomplete }
            }
        }
        retained["status"] = finalOutcome.status
        retained["exit_code"] = finalOutcome.exitCode
        retained["app.metric_delivery"] = signal?.metricDelivery.map { ["enabled": $0.enabled, "exported_metrics": $0.exportedMetrics, "failed_metrics": $0.failedMetrics] as [String: Any] } as Any? ?? NSNull()
        let delivery = client.delivery
        retained["runner.delivery"] = ["enabled": delivery.enabled, "exported_spans": delivery.exportedSpans, "failed_spans": delivery.failedSpans,
                                      "failed_requests": delivery.failedRequests, "retried_requests": delivery.retriedRequests,
                                      "last_failure": delivery.lastFailure as Any? ?? NSNull()]
        if var diagnostic = retained["diagnostic"] as? [String: Any] {
            let gaps = (diagnostic["observationGaps"] as? [String] ?? []) + (retained["issues"] as? [String] ?? [])
            diagnostic["observationGaps"] = Array(Set(gaps)).sorted()
            retained["diagnostic"] = diagnostic
        }
        try JSONSerialization.data(withJSONObject: retained, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        print("Scenario report: \(folder.appendingPathComponent("report.json").path)")
        return finalOutcome.exitCode
    }
}
#endif

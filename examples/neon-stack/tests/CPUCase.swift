import Foundation

// Run explicitly with a Release app. The default development check does not launch this experiment.
enum CaseError: Error { case invalid(String) }
typealias Object = [String: Any]

func object(_ url: URL) throws -> Object {
    guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Object else {
        throw CaseError.invalid("Expected an object at \(url.path)")
    }
    return result
}
func rows(_ url: URL) throws -> [Object] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        guard let row = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? Object else {
            throw CaseError.invalid("Expected a window at \(url.path)")
        }
        return row
    }
}
func number(_ row: Object, _ key: String) throws -> Double {
    guard let value = row[key] as? NSNumber, value.doubleValue.isFinite else {
        throw CaseError.invalid("Missing finite measurement \(key)")
    }
    return value.doubleValue
}
func weighted(_ rows: [Object], _ value: String, weight: String) throws -> Double {
    let denominator = try rows.reduce(0.0) { try $0 + number($1, weight) }
    guard !rows.isEmpty, denominator > 0 else { throw CaseError.invalid("No complete measurement windows") }
    return try rows.reduce(0.0) { try $0 + number($1, value) * number($1, weight) } / denominator
}

do {
    guard CommandLine.arguments.count == 3 else {
        print("Usage: xcrun swift examples/neon-stack/tests/CPUCase.swift RELEASE_APP OUTPUT_DIRECTORY")
        exit(2)
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let app = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(UUID().uuidString)
    let cli =
        ProcessInfo.processInfo.environment["LOGFIRE_APPLE_BIN"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/logfire-apple").path
    try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let identity = try object(app.appendingPathComponent("Contents/Resources/LogfireBuild.json"))
    guard identity["build.configuration"] as? String == "Release" else { throw CaseError.invalid("Use a Release app") }
    var results: [Object] = []
    var failures: [String] = []
    var referenceGameplay: [String: String]?
    var referenceContext: [String]?

    // Each process starts cold. The discarded pair warms shared OS, shader, and tool caches for both policies.
    for pair in 0...5 {
        for variant in ["every-frame", "bounded"] {
            let folder = output.appendingPathComponent("\(pair)-\(variant)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let log = folder.appendingPathComponent("run.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = [
                "run", "--app", app.path, "--scenario",
                root.appendingPathComponent("examples/neon-stack/scenarios/log-roll-hud-\(variant).json").path,
                "--output", folder.path,
            ]
            process.standardOutput = handle
            process.standardError = handle
            let began = ProcessInfo.processInfo.systemUptime
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw CaseError.invalid("Runner exit \(process.terminationStatus)")
                }
                let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                let reports = entries.map { $0.appendingPathComponent("report.json") }.filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                guard reports.count == 1 else { throw CaseError.invalid("Expected one retained run report") }
                let report = try object(reports[0])
                let runFolder = reports[0].deletingLastPathComponent()
                guard report["status"] as? String == "passed", report["profile.requested"] as? String == "none",
                    report["build.id"] as? String == identity["build.id"] as? String,
                    report["build.source_digest"] as? String == identity["build.source_digest"] as? String,
                    let details = report["scenario.details"] as? [String: String], details["hud_policy"] == variant,
                    details["mazes_cleared"] == "2", details["game_over"] == "true", details["failure"] == ""
                else {
                    throw CaseError.invalid("Run identity, policy, or game assertions differ")
                }
                let gameplay = details.filter {
                    ["mazes_cleared", "game_over", "moves", "turns", "simulation_seconds"].contains($0.key)
                }
                if let referenceGameplay, referenceGameplay != gameplay {
                    throw CaseError.invalid("Gameplay differs between policies")
                }
                referenceGameplay = gameplay
                guard let publications = details["hud_publications"].flatMap(Int.init), publications > 0,
                    let maps = details["map_publications"].flatMap(Int.init), maps > 0,
                    variant != "every-frame" || publications == maps
                else { throw CaseError.invalid("Missing publication work") }
                let frames = try rows(runFolder.appendingPathComponent("performance.jsonl"))
                let responsiveness = try rows(runFolder.appendingPathComponent("responsiveness.jsonl"))
                let contexts = frames.map { row in
                    ["render_mode", "drawable_width", "drawable_height", "workload", "particles", "gpu_time.scope"]
                        .map { String(describing: row[$0] ?? "missing") }.joined(separator: "/")
                }
                guard let context = contexts.first, contexts.allSatisfy({ $0 == context }),
                    referenceContext == nil || referenceContext == [context],
                    responsiveness.allSatisfy({ $0["session_id"] as? String == report["session_id"] as? String })
                else {
                    throw CaseError.invalid("Render context or responsiveness session differs")
                }
                referenceContext = [context]
                let sample: Object = [
                    "pair": pair, "variant": variant, "warmup": pair == 0,
                    "session_id": report["session_id"]!, "build.id": identity["build.id"]!, "report": reports[0].path,
                    "main_thread_cpu": try weighted(
                        responsiveness, "main_thread.cpu.utilization", weight: "window_seconds"),
                    "callback_fps": try weighted(frames, "render_callback_fps", weight: "window_seconds"),
                    "gpu_worst_window_p95_ms": try frames.map { try number($0, "gpu_command_p95_ms") }.max()!,
                    "app_seconds": try number(report, "app.duration_seconds"),
                    "command_seconds": ProcessInfo.processInfo.systemUptime - began,
                    "hud_publications": publications, "map_publications": maps, "gameplay": gameplay,
                ]
                results.append(sample)
                print(
                    "Pair \(pair) \(variant): main-thread CPU \(sample["main_thread_cpu"]!), callback FPS \(sample["callback_fps"]!)."
                )
            } catch {
                failures.append("Pair \(pair) \(variant): \(error). Inspect \(log.path)")
                print(failures.last!)
            }
            try handle.close()
        }
    }
    var summary: Object = [
        "schema_version": 1, "build": identity, "results": results, "failures": failures,
        "measurement_scope": "complete_sdk_windows_unprofiled", "gameplay": referenceGameplay ?? [:],
        "render_context": referenceContext ?? [],
    ]
    for variant in ["every-frame", "bounded"] {
        let selected = results.filter { $0["variant"] as? String == variant && $0["warmup"] as? Bool == false }
        var statistics: Object = ["runs": selected.count]
        for key in [
            "main_thread_cpu", "callback_fps", "gpu_worst_window_p95_ms", "app_seconds", "command_seconds",
            "hud_publications", "map_publications",
        ] {
            let values = try selected.map { try number($0, key) }.sorted()
            if values.count == 5 { statistics[key] = ["median": values[2], "min": values.first!, "max": values.last!] }
        }
        summary[variant] = statistics
    }
    summary["status"] = failures.isEmpty && results.count == 12 ? "passed" : "incomplete"
    let file = output.appendingPathComponent("comparison.json")
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(
        to: file, options: .atomic)
    print("Comparison: \(file.path)")
    exit(failures.isEmpty && results.count == 12 ? 0 : 1)
} catch {
    print("CPU case cannot run: \(error)")
    exit(2)
}

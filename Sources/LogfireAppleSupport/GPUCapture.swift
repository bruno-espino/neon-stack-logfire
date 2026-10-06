import Foundation
import LogfireSwift
#if os(macOS)
import Darwin

struct GPUCaptureOptions {
    var service: String?
    var sessions = Logfire.developmentSessionsDirectory
    var output = URL(fileURLWithPath: ".xcode-observe/gpu", isDirectory: true)
    var count = 1
    var boundary: String?
    var label: String?
    var profile = false
    var local = false

    init(_ arguments: [String]) throws {
        var i = 0
        while i < arguments.count {
            let flag = arguments[i]
            if flag == "--profile" { profile = true; i += 1; continue }
            if flag == "--no-telemetry" { local = true; i += 1; continue }
            guard i + 1 < arguments.count else { throw CompanionError.message("Missing value for \(flag)") }
            let value = arguments[i + 1]
            switch flag {
            case "--count":
                guard let count = Int(value), (1...3).contains(count) else { throw CompanionError.message("Use --count between 1 and 3") }
                self.count = count
            case "--boundary":
                guard let id = UInt64(value), id > 0 else { throw CompanionError.message("Boundary must be a positive ID") }
                boundary = String(id)
            case "--label":
                guard !value.isEmpty, value.count <= 256 else { throw CompanionError.message("Use a nonempty boundary label up to 256 characters") }
                label = value
            case "--service": service = value
            case "--sessions": sessions = URL(fileURLWithPath: value, isDirectory: true)
            case "--output": output = URL(fileURLWithPath: value, isDirectory: true)
            default: throw CompanionError.message("Unknown GPU capture option \(flag)")
            }
            i += 2
        }
        guard boundary == nil || label == nil else { throw CompanionError.message("Select either --boundary or --label") }
    }
}

/// gpudebug emits consecutive JSON objects, including pretty-printed properties.
enum GPUJSON {
    static func objects(_ data: Data) throws -> [[String: Any]] {
        guard data.count <= 16 * 1024 * 1024 else { throw CompanionError.message("GPU inspection exceeds 16 MiB") }
        let bytes = Array(data)
        var start: Int?; var depth = 0; var quoted = false; var escaped = false
        var objects: [[String: Any]] = []
        for (i, byte) in bytes.enumerated() {
            if start == nil {
                if [9, 10, 13, 32].contains(byte) { continue }
                guard byte == 123 else { throw CompanionError.message("GPU inspection contains non-JSON output") }
                start = i; depth = 1; continue
            }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 {
                depth -= 1
                if depth == 0 {
                    guard let object = try JSONSerialization.jsonObject(with: Data(bytes[start!...i])) as? [String: Any] else {
                        throw CompanionError.message("GPU inspection is not an object")
                    }
                    objects.append(object); start = nil
                }
            }
        }
        guard start == nil, !objects.isEmpty else { throw CompanionError.message("GPU inspection is empty or incomplete") }
        guard !objects.contains(where: { $0["error"] != nil || ($0["success"] as? Bool) == false }) else {
            throw CompanionError.message("GPU inspection reports an operation error")
        }
        return objects
    }

    static func properties(_ object: [String: Any]) -> [String: Any] {
        let fields = ["Duration": "gpu.replay.duration_ms",
            "Cost": "gpu.replay.cost_fraction", "Temp registers": "gpu.shader.temp_registers",
            "Uniform registers": "gpu.shader.uniform_registers", "Spilled bytes": "gpu.shader.spilled_bytes",
            "Instructions": "gpu.instructions", "Wait": "gpu.shader.wait_instructions"]
        var values: [String: Any] = [:]
        for (key, target) in fields {
            guard let raw = object[key] as? String else { continue }
            let unit = key == "Duration" || key == "Active time" ? " ms" : key == "Cost" ? "%" : ""
            guard unit.isEmpty || raw.hasSuffix(unit) else { continue }
            let number = unit.isEmpty ? raw : String(raw.dropLast(unit.count))
            guard number.range(of: "^[0-9]+([.,][0-9]+)?$", options: .regularExpression) != nil,
                  let value = Double(number.replacingOccurrences(of: ",", with: ".")), value.isFinite,
                  key != "Cost" || value <= 100 else { continue }
            values[target] = key == "Cost" ? value / 100 : value
        }
        if let stage = object["Stage"] as? String, ["vertex", "fragment", "compute"].contains(stage) { values["gpu.shader.stage"] = stage }
        return values
    }
}

/// Retained workload identity permits analysis after the original process stops.
struct CapturedGPUWorkload {
    let options: GPUCaptureOptions
    let session: NativeSession
    let folder: URL
    let trace: URL
    let hash: String
    let start: String
    let end: String
}

enum GPUCapture {
    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.contains("--help") {
            print("Usage: logfire-apple gpu-capture [--count 1] [--profile] [--boundary ID | --label NAME] [--service NAME] [--no-telemetry] [--sessions DIRECTORY] [--output DIRECTORY]")
            print("Launch with MTL_CAPTURE_ENABLED=1 and wait for renderer activity. Counts mean boundary completions, not always frames.")
            return 0
        }
        do { return try analyze(capture(GPUCaptureOptions(arguments))) }
        catch CompanionError.interrupted(let code) { return code }
    }

    static func capture(_ options: GPUCaptureOptions, seconds: Double = 30) throws -> CapturedGPUWorkload {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/gpucapture"), FileManager.default.isExecutableFile(atPath: "/usr/bin/gpudebug") else {
            throw CompanionError.message("GPU capture and inspection require macOS 27 tools")
        }
        let session = try Companion.latestSession(directory: options.sessions, service: options.service)
        let folder = options.output.appendingPathComponent(session.id).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let trace = folder.appendingPathComponent("Frame.gputrace")
        let hash = try Companion.fileHash(session.executable)
        let app = session.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let symbols = URL(fileURLWithPath: app.path + ".dSYM")
        if FileManager.default.fileExists(atPath: symbols.path) { try FileManager.default.copyItem(at: symbols, to: folder.appendingPathComponent(symbols.lastPathComponent)) }
        try session.validate()
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.string(from: Date())
        var args = ["gpucapture", "start", "--pid", String(session.pid), "--count", String(options.count), "--output", trace.path]
        if let id = options.boundary { args += ["--boundary", id] }
        if let label = options.label { args += ["--label", label] }
        let code = try HostCommand.run("/usr/bin/xcrun", args, output: folder.appendingPathComponent("capture.stdout"), errors: folder.appendingPathComponent("capture.stderr"), seconds: seconds)
        try HostCommand.requireSuccess(code, message: "GPU capture failed. Inspect \(folder.path)")
        guard FileManager.default.fileExists(atPath: trace.path) else {
            throw CompanionError.message("GPU capture failed. Launch with MTL_CAPTURE_ENABLED=1, wait for renderer activity, and select a boundary if needed. Inspect \(folder.path)")
        }
        let end = formatter.string(from: Date())
        if kill(session.pid, 0) == 0 { try session.validate() }
        return CapturedGPUWorkload(options: options, session: session, folder: folder, trace: trace, hash: hash, start: start, end: end)
    }

    static func analyze(_ capture: CapturedGPUWorkload) throws -> Int32 {
        let options = capture.options, session = capture.session, folder = capture.folder, trace = capture.trace
        let hash = capture.hash, start = capture.start, end = capture.end
        let analysisStarted = ProcessInfo.processInfo.systemUptime
        var selected: [[String: Any]] = []; var issues: [String] = []
        func inspect(_ name: String, commands: [String]) throws -> [[String: Any]] {
            let output = folder.appendingPathComponent(name + ".json")
            let command = ["gpudebug", "--oneshot", "--json", "--timeout", "30", "--gputrace", trace.path] + commands.flatMap { ["-c", $0] }
            let status = try HostCommand.run("/usr/bin/xcrun", command, output: output, errors: folder.appendingPathComponent(name + ".stderr"), seconds: 60)
            try HostCommand.requireSuccess(status, message: "GPU inspection failed")
            return try GPUJSON.objects(Data(contentsOf: output))
        }
        var device = "unknown"
        var phase = "static-inspection"
        do {
            let records = try inspect("inspection", commands: ["status", "go commands", "go resources"])
            device = records.first?["device"] as? String ?? "unknown"
            if options.profile {
                phase = "replay-collection"
                let records = try inspect("replay", commands: ["profile run --gpu-state default --exec overlapping --embed"])
                guard records.contains(where: { $0["notification"] as? String == "Profile data collected." && $0["success"] as? Bool == true }) else {
                    throw CompanionError.message("GPU replay did not finish profiling")
                }
                phase = "ranked-table-reload"
                let loaded = try inspect("selection", commands: ["profile load", "go performance/encoders", "go performance/shaders"])
                let tables = loaded.filter { $0["children"] != nil }
                guard tables.count == 2, let encoders = tables[0]["children"] as? [[String: Any]],
                      let shaders = tables[1]["children"] as? [[String: Any]], !encoders.isEmpty else {
                    throw CompanionError.message("GPU replay did not provide encoder and shader tables")
                }
                var selections: [(String, String, String)] = []
                for (rows, scope, pattern) in [(encoders, "gpu_replay_encoder", "^(re|ce|be)[0-9]+$"),
                                                (shaders, "gpu_replay_shader", "^(vert|frag|comp)[0-9]+$")] {
                    for row in rows.prefix(3) {
                        guard let name = row["name"] as? String, name.range(of: pattern, options: .regularExpression) != nil else {
                            throw CompanionError.message("Unknown GPU profile node identity")
                        }
                        let values = row["values"] as? [Any]
                        let label = (values?.first as? [String: Any])?["value"] as? String ?? name
                        selections.append((name, scope, String(label.prefix(512))))
                    }
                }
                var commands = ["profile load", "go performance/encoders"]
                commands += selections.filter { $0.1 == "gpu_replay_encoder" }.map { "info " + $0.0 }
                commands += ["go performance/shaders"]
                commands += selections.filter { $0.1 == "gpu_replay_shader" }.map { "info " + $0.0 }
                phase = "ranked-properties"
                let details = try inspect("properties", commands: commands).filter { $0["Duration"] != nil || $0["Stage"] != nil }
                guard details.count == selections.count else { throw CompanionError.message("GPU profile properties are incomplete") }
                for (selection, properties) in zip(selections, details) {
                    var values = GPUJSON.properties(properties)
                    let complete = selection.1 == "gpu_replay_encoder" ? values["gpu.replay.duration_ms"] != nil : values["gpu.shader.stage"] != nil
                    guard complete, values["gpu.replay.cost_fraction"] != nil else {
                        throw CompanionError.message("GPU node has no recognized cost and scope properties")
                    }
                    values["gpu.node.id"] = selection.0; values["gpu.node.label"] = selection.2
                    values["measurement.scope"] = selection.1
                    selected.append(values)
                }
            }
        } catch CompanionError.interrupted(let code) {
            throw CompanionError.interrupted(code)
        } catch {
            issues.append("GPU summary is incomplete at \(phase). Inspect retained JSON and stderr.")
        }
        var context = session.metadata.merging([
            "capture.id": folder.lastPathComponent, "capture.path": folder.path, "capture.storage": "local",
            "capture.kind": "gpu-workload", "capture.tool": "apple.gpucapture", "binary.sha256": hash,
            "capture.started_at": start, "capture.ended_at": end, "capture.count_requested": options.count,
            "capture.boundary": options.boundary ?? options.label ?? "apple-default",
            "gpu.device": device, "gpu.replay.requested": options.profile, "gpu.replay.exec": "overlapping",
            "gpu.replay.state_requested": "default", "gpu.selection": "apple-cost-ranked-v1",
            "gpu.selection_limit_per_scope": 3, "profile.instrumented": true, "measurement.source": "apple.gpudebug",
        ]) { _, actual in actual }
        context["gpu.analysis.duration_seconds"] = ProcessInfo.processInfo.systemUptime - analysisStarted
        context["gpu.observation_gaps"] = issues.count
        if !issues.isEmpty { context["gpu.failure_stage"] = phase }
        var manifest = context; manifest["gpu.measurements"] = selected; manifest["issues"] = issues
        var checksums: [String: String] = [:]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            checksums[String(file.path.dropFirst(folder.path.count + 1))] = try Companion.fileHash(file)
        }
        manifest["artifacts"] = checksums
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        let client = Companion.client(local: options.local, service: session.metadata["service.name"] as? String ?? "apple-native", resource: context)
        client.event("game.profile.capture", attributes: Companion.attributes(context))
        for row in selected { client.event("game.gpu.replay", attributes: Companion.attributes(context.merging(row) { _, measurement in measurement })) }
        client.flush(); Companion.printDelivery(client)
        print("GPU manifest: \(folder.appendingPathComponent("manifest.json").path)")
        print("Replay measurements describe the captured GPU workload, not live frame latency or CPU waiting.")
        return issues.isEmpty ? 0 : 2
    }
}
#endif

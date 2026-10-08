import Foundation
import LogfireSwift
#if os(macOS)
import Darwin

struct CPUFunction: Codable {
    let symbol: String
    let image: String
    let imageUUID: String
    var samples: Int
    var weightNanoseconds: Double
}

struct CPUFrame: Codable, Hashable {
    let symbol: String
    let image: String
    let imageUUID: String
}

/// Frames run from the oldest caller to the sampled leaf. Paths describe running CPU work.
struct CPUCallPath: Codable {
    let threadScope: String
    let frames: [CPUFrame]
    let truncated: Bool
    let unresolvedFrames: Int
    var samples: Int
    var weightNanoseconds: Double
}

/// Each function counts once per sample, including recursive occurrences. Different callers' weights overlap.
struct CPUCaller: Codable {
    let threadScope: String
    let function: CPUFunction
}

private struct CPUCallerKey: Hashable {
    let threadScope: String
    let frame: CPUFrame
}

private struct CPUPathKey: Hashable {
    let threadScope: String
    let frames: [CPUFrame]
    let truncated: Bool
}

struct CPUProfileSummary: Codable {
    var samples = 0
    var otherProcessSamples = 0
    var nonRunningSamples = 0
    var unresolvedSamples = 0
    var weightNanoseconds: Double = 0
    var mainThreadWeightNanoseconds: Double = 0
    var functions: [CPUFunction] = []
    var callPaths: [CPUCallPath] = []
    var pathSamples = 0
    var partialPathSamples = 0
    var callers: [CPUCaller]?
}

/// xctrace weights describe sampled CPU work. They do not measure wall time or blocked threads.
enum InstrumentsXML {
    static func document(_ data: Data) throws -> XMLDocument {
        guard data.count <= 64 * 1024 * 1024 else { throw CompanionError.message("Instruments XML exceeds 64 MiB") }
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    static func cpu(_ data: Data, pid: Int32) throws -> CPUProfileSummary {
        let document = try document(data)
        guard let root = document.rootElement(),
              try root.nodes(forXPath: "node/schema[@name='time-profile']").count == 1 else {
            throw CompanionError.message("Instruments export does not contain one time-profile table")
        }
        var references: [String: XMLElement] = [:]
        for case let element as XMLElement in try root.nodes(forXPath: ".//*[@id]") {
            guard references.count < 100_000, let id = element.attribute(forName: "id")?.stringValue,
                  references.updateValue(element, forKey: id) == nil else {
                throw CompanionError.message("Instruments XML has too many or duplicate references")
            }
        }
        func resolve(_ element: XMLElement?) throws -> XMLElement {
            guard let element else { throw CompanionError.message("Instruments CPU sample is missing a field") }
            if let ref = element.attribute(forName: "ref")?.stringValue {
                guard let target = references[ref], target.name == element.name else {
                    throw CompanionError.message("Instruments CPU sample has an unresolved reference")
                }
                return target
            }
            return element
        }
        var result = CPUProfileSummary()
        var functions: [String: CPUFunction] = [:]
        var paths: [CPUPathKey: CPUCallPath] = [:]
        var callers: [CPUCallerKey: CPUFunction] = [:]
        for case let row as XMLElement in try root.nodes(forXPath: "node/row") {
            let process = try resolve(row.elements(forName: "process").first)
            let processPID = try resolve(process.elements(forName: "pid").first)
            guard Int32(processPID.stringValue ?? "") == pid else { result.otherProcessSamples += 1; continue }
            let state = try resolve(row.elements(forName: "thread-state").first)
            guard state.stringValue == "Running" else { result.nonRunningSamples += 1; continue }
            let weight = try resolve(row.elements(forName: "weight").first)
            guard let nanoseconds = Double(weight.stringValue ?? ""), nanoseconds.isFinite, nanoseconds > 0 else {
                throw CompanionError.message("Instruments CPU sample has an invalid weight")
            }
            result.samples += 1; result.weightNanoseconds += nanoseconds
            guard result.weightNanoseconds.isFinite else { throw CompanionError.message("Instruments CPU sample weights exceed the numeric range") }
            let thread = try resolve(row.elements(forName: "thread").first)
            let mainThread = thread.attribute(forName: "fmt")?.stringValue?.hasPrefix("Main Thread (") == true
            if mainThread {
                result.mainThreadWeightNanoseconds += nanoseconds
            }
            guard let stackElement = row.elements(forName: "tagged-backtrace").first else {
                guard row.elements(forName: "sentinel").count == 1 else { throw CompanionError.message("Instruments CPU sample is missing its backtrace field") }
                result.unresolvedSamples += 1
                continue
            }
            let stack = try resolve(stackElement)
            let stackFrames = stack.elements(forName: "frame")
            guard let first = stackFrames.first else { result.unresolvedSamples += 1; continue }
            var frames: [CPUFrame] = []
            var unresolved = 0
            for element in stackFrames.prefix(256) {
                let frame = try resolve(element)
                let rawSymbol = frame.attribute(forName: "name")?.stringValue ?? ""
                let symbol = !rawSymbol.isEmpty && !rawSymbol.hasPrefix("0x") && rawSymbol.count <= 512 ? rawSymbol : "<unresolved>"
                if symbol == "<unresolved>" { unresolved += 1 }
                let binary = try frame.elements(forName: "binary").first.map { try resolve($0) }
                frames.append(CPUFrame(symbol: symbol, image: binary?.attribute(forName: "name")?.stringValue ?? "unknown",
                    imageUUID: binary?.attribute(forName: "UUID")?.stringValue ?? "unknown"))
            }
            let truncated = stackFrames.count > 256
            let pathKey = CPUPathKey(threadScope: mainThread ? "main" : "background", frames: Array(frames.reversed()), truncated: truncated)
            for frame in Set(frames) where frame.symbol != "<unresolved>" {
                let key = CPUCallerKey(threadScope: pathKey.threadScope, frame: frame)
                guard callers[key] != nil || callers.count < 100_000 else {
                    throw CompanionError.message("Instruments export exceeds 100000 distinct callers")
                }
                var caller = callers[key] ?? CPUFunction(symbol: frame.symbol, image: frame.image,
                    imageUUID: frame.imageUUID, samples: 0, weightNanoseconds: 0)
                caller.samples += 1; caller.weightNanoseconds += nanoseconds; callers[key] = caller
            }
            guard paths[pathKey] != nil || paths.count < 50_000 else { throw CompanionError.message("Instruments export exceeds 50000 distinct call paths") }
            var path = paths[pathKey] ?? CPUCallPath(threadScope: pathKey.threadScope, frames: pathKey.frames,
                truncated: truncated, unresolvedFrames: unresolved, samples: 0, weightNanoseconds: 0)
            path.samples += 1; path.weightNanoseconds += nanoseconds; paths[pathKey] = path
            result.pathSamples += 1
            if truncated || unresolved > 0 { result.partialPathSamples += 1 }
            let leaf = try resolve(first)
            guard let symbol = leaf.attribute(forName: "name")?.stringValue, !symbol.isEmpty,
                  !symbol.hasPrefix("0x"), symbol.count <= 512 else { result.unresolvedSamples += 1; continue }
            let binary = try resolve(leaf.elements(forName: "binary").first)
            let image = binary.attribute(forName: "name")?.stringValue ?? "unknown"
            let uuid = binary.attribute(forName: "UUID")?.stringValue ?? "unknown"
            let key = "\(uuid)\0\(image)\0\(symbol)"
            var function = functions[key] ?? CPUFunction(symbol: symbol, image: image, imageUUID: uuid, samples: 0, weightNanoseconds: 0)
            function.samples += 1; function.weightNanoseconds += nanoseconds; functions[key] = function
        }
        result.functions = Array(functions.values.sorted {
            if $0.weightNanoseconds != $1.weightNanoseconds { return $0.weightNanoseconds > $1.weightNanoseconds }
            return "\($0.image)/\($0.symbol)" < "\($1.image)/\($1.symbol)"
        }.prefix(20))
        // Keep main-thread paths even when background work dominates the process total.
        result.callPaths = ["main", "background"].flatMap { scope in
            Array(paths.values.filter { $0.threadScope == scope }.sorted {
                if $0.weightNanoseconds != $1.weightNanoseconds { return $0.weightNanoseconds > $1.weightNanoseconds }
                return $0.frames.map { "\($0.image)/\($0.symbol)/\($0.imageUUID)" }.joined(separator: "\0") <
                    $1.frames.map { "\($0.image)/\($0.symbol)/\($0.imageUUID)" }.joined(separator: "\0")
            }.prefix(20))
        }
        result.callers = ["main", "background"].flatMap { scope in
            Array(callers.filter { $0.key.threadScope == scope }.values.sorted {
                if $0.weightNanoseconds != $1.weightNanoseconds { return $0.weightNanoseconds > $1.weightNanoseconds }
                return "\($0.imageUUID)/\($0.image)/\($0.symbol)" < "\($1.imageUUID)/\($1.image)/\($1.symbol)"
            }.prefix(20)).map { CPUCaller(threadScope: scope, function: $0) }
        }
        return result
    }

    static func recording(_ data: Data, pid: Int32) throws -> [String: Any] {
        let document = try document(data)
        guard let run = try document.nodes(forXPath: "/trace-toc/run[@number='1']").first,
              let process = try run.nodes(forXPath: "info/target/process").first as? XMLElement,
              process.attribute(forName: "pid")?.stringValue == String(pid),
              let start = try run.nodes(forXPath: "info/summary/start-date").first?.stringValue,
              let end = try run.nodes(forXPath: "info/summary/end-date").first?.stringValue,
              let duration = try run.nodes(forXPath: "info/summary/duration").first?.stringValue.flatMap(Double.init),
              duration.isFinite, duration > 0,
              let startDate = NativeMeasurements.date(start), let endDate = NativeMeasurements.date(end),
              endDate > startDate, abs(endDate.timeIntervalSince(startDate) - duration) < 0.1 else {
            throw CompanionError.message("Instruments recording does not identify the selected process and interval")
        }
        return ["profile.started_at": start, "profile.ended_at": end, "profile.duration_seconds": duration,
            "profile.instruments_version": try run.nodes(forXPath: "info/summary/instruments-version").first?.stringValue ?? "unknown"]
    }
}

/// The saved recording retains process identity after the app stops.
struct CapturedCPURecording {
    let options: Companion.Options
    let session: NativeSession
    let folder: URL
    let trace: URL
    let binaryHash: String
    let commandDuration: Double
}

enum InstrumentsProfile {
    static func timeLimit(seconds: Double) -> String { "\(Int((seconds * 1000).rounded()))ms" }

    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.contains("--help") {
            print("Usage: logfire-apple profile [--seconds 5] [--service NAME] [--no-telemetry] [--sessions DIRECTORY] [--output DIRECTORY]")
            return 0
        }
        do { return try analyze(record(arguments)) }
        catch CompanionError.interrupted(let code) { return code }
    }

    static func record(_ arguments: [String], timeout: Double? = nil, onTick: (() throws -> Bool)? = nil) throws -> CapturedCPURecording {
        guard !arguments.contains("--last") else { throw CompanionError.message("CPU profiling records a live interval. Use --seconds instead of --last.") }
        var options = try Companion.parse(arguments)
        if !arguments.contains("--seconds") { options.seconds = 5 }
        guard options.seconds <= 30 else { throw CompanionError.message("Use a profile duration between 1 and 30 seconds") }
        let session = try Companion.latestSession(directory: options.sessions, service: options.service)
        let folder = options.output.appendingPathComponent(session.id).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let trace = folder.appendingPathComponent("Instruments.trace")
        let binaryHash = try Companion.fileHash(session.executable)
        let app = session.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let symbols = URL(fileURLWithPath: app.path + ".dSYM")
        if FileManager.default.fileExists(atPath: symbols.path) {
            try FileManager.default.copyItem(at: symbols, to: folder.appendingPathComponent(symbols.lastPathComponent))
        }
        try session.validate()
        let began = ProcessInfo.processInfo.systemUptime
        let result = try HostCommand.run("/usr/bin/xcrun", ["xctrace", "record", "--template", "Time Profiler",
            "--attach", String(session.pid), "--time-limit", timeLimit(seconds: options.seconds), "--output", trace.path, "--no-prompt"],
            output: folder.appendingPathComponent("record.stdout"), errors: folder.appendingPathComponent("record.stderr"),
            seconds: min(options.seconds + 60, timeout ?? .infinity), onTick: onTick)
        try HostCommand.requireSuccess(result, message: "Instruments recording failed. Inspect \(folder.path)")
        guard FileManager.default.fileExists(atPath: trace.path) else { throw CompanionError.message("Instruments recording failed. Inspect \(folder.path)") }
        if kill(session.pid, 0) == 0 { try session.validate() }
        return CapturedCPURecording(options: options, session: session, folder: folder, trace: trace, binaryHash: binaryHash,
            commandDuration: ProcessInfo.processInfo.systemUptime - began)
    }

    static func analyze(_ capture: CapturedCPURecording) throws -> Int32 {
        let options = capture.options, session = capture.session, folder = capture.folder, trace = capture.trace
        let analysisStarted = ProcessInfo.processInfo.systemUptime
        let toc = folder.appendingPathComponent("toc.xml")
        let cpu = folder.appendingPathComponent("cpu.xml")
        for (output, selection) in [(toc, ["--toc"]), (cpu, ["--xpath", "/trace-toc/run[@number='1']/data/table[@schema='time-profile']"])] {
            let status = try HostCommand.run("/usr/bin/xcrun", ["xctrace", "export", "--input", trace.path] + selection + ["--output", output.path],
                output: folder.appendingPathComponent(output.lastPathComponent + ".stdout"),
                errors: folder.appendingPathComponent(output.lastPathComponent + ".stderr"), seconds: 30)
            try HostCommand.requireSuccess(status, message: "Instruments export failed. Recording remains at \(trace.path)")
        }
        let recording = try InstrumentsXML.recording(Data(contentsOf: toc), pid: session.pid)
        var summary = CPUProfileSummary()
        var summaryAvailable = true
        do { summary = try InstrumentsXML.cpu(Data(contentsOf: cpu), pid: session.pid) }
        catch { summaryAvailable = false; print("CPU summary unavailable. Inspect the retained export at \(cpu.path)") }
        var details: [String: Any] = recording.merging([
            "capture.id": folder.lastPathComponent, "capture.path": folder.path, "capture.storage": "local",
            "capture.kind": "instruments-cpu", "capture.tool": "apple.xctrace", "binary.sha256": capture.binaryHash,
            "profile.record.command_duration_seconds": capture.commandDuration,
            "profile.analysis.duration_seconds": ProcessInfo.processInfo.systemUptime - analysisStarted,
            "profile.template": "Time Profiler", "profile.requested_seconds": options.seconds,
            "profile.instrumented": true, "measurement.source": "apple.xctrace.time-profile",
            "measurement.scope": "process_cpu_samples", "cpu.samples": summary.samples,
            "cpu.sampled_weight_ms": summary.weightNanoseconds / 1_000_000,
            "cpu.main_thread_sampled_weight_ms": summary.mainThreadWeightNanoseconds / 1_000_000,
            "cpu.unresolved_samples": summary.unresolvedSamples, "cpu.other_process_samples": summary.otherProcessSamples,
            "cpu.non_running_samples": summary.nonRunningSamples,
            "cpu.path_samples": summary.pathSamples, "cpu.partial_path_samples": summary.partialPathSamples,
            "cpu.call_paths": summary.callPaths.count,
            "cpu.inclusive_callers": summary.callers?.count ?? 0,
            "cpu.summary_available": summaryAvailable,
        ]) { _, actual in actual }
        if !summaryAvailable { details["profile.observation_gap"] = "CPU export could not be decoded" }
        else if summary.samples == 0 { details["profile.observation_gap"] = "No running CPU samples" }
        let context = session.metadata.merging(details) { _, profile in profile }
        var manifest = context
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        var checksums: [String: String] = [:]
        for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            checksums[String(file.path.dropFirst(folder.path.count + 1))] = try Companion.fileHash(file)
        }
        manifest["artifacts"] = checksums
        manifest["cpu.summary"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary))
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        let client = Companion.client(local: options.local, service: session.metadata["service.name"] as? String ?? "apple-native", resource: context)
        client.event("game.profile.capture", attributes: Companion.attributes(context))
        client.event("game.cpu.profile", attributes: Companion.attributes(context))
        for (index, function) in summary.functions.enumerated() {
            let values: [String: Any] = ["measurement.scope": "cpu_leaf_function", "function.name": function.symbol,
                "function.image": function.image, "function.image_uuid": function.imageUUID,
                "function.samples": function.samples, "function.sampled_weight_ms": function.weightNanoseconds / 1_000_000,
                "function.rank": index + 1,
                "function.sampled_weight_fraction": function.weightNanoseconds / summary.weightNanoseconds]
            client.event("game.cpu.function", attributes: Companion.attributes(context.merging(values) { _, function in function }))
        }
        for scope in ["main", "background"] {
            let denominator = scope == "main" ? summary.mainThreadWeightNanoseconds : summary.weightNanoseconds - summary.mainThreadWeightNanoseconds
            for (index, caller) in (summary.callers ?? []).filter({ $0.threadScope == scope }).enumerated() {
                let function = caller.function
                let values: [String: Any] = ["measurement.scope": "cpu_inclusive_function", "cpu.thread_scope": scope,
                    "function.name": function.symbol, "function.image": function.image, "function.image_uuid": function.imageUUID,
                    "function.rank": index + 1, "function.samples": function.samples,
                    "function.inclusive_sampled_weight_ms": function.weightNanoseconds / 1_000_000,
                    "function.inclusive_sampled_weight_fraction": function.weightNanoseconds / denominator,
                    "function.denominator": "all_running_weight_in_thread_scope", "function.recursion": "counted_once_per_sample",
                    "function.weights_overlap": true]
                client.event("game.cpu.caller", attributes: Companion.attributes(context.merging(values) { _, caller in caller }))
            }
            for (index, path) in summary.callPaths.filter({ $0.threadScope == scope }).enumerated() {
                let display = path.frames.map(\.symbol).joined(separator: " → ")
                let values: [String: Any] = ["measurement.scope": "cpu_sampled_call_path", "cpu.thread_scope": scope,
                    "call_path.rank": index + 1, "call_path.samples": path.samples,
                    "call_path.sampled_weight_ms": path.weightNanoseconds / 1_000_000,
                    "call_path.sampled_weight_fraction": path.weightNanoseconds / denominator,
                    "call_path.denominator": "all_running_weight_in_thread_scope", "call_path.frame_order": "caller_to_leaf",
                    "call_path.partial": path.truncated || path.unresolvedFrames > 0, "call_path.truncated": path.truncated,
                    "call_path.unresolved_frames": path.unresolvedFrames,
                    "call_path.display": display.count > 8192 ? "… " + String(display.suffix(8192)) : display,
                    "call_path.display_truncated": display.count > 8192]
                client.event("game.cpu.call_path", attributes: try Companion.attributes(context.merging(values) { _, path in path })
                    .merging(Companion.structuredAttribute("call_path.frames", encoded: path.frames, type: "array")) { _, structured in structured })
            }
        }
        client.flush(); Companion.printDelivery(client)
        print("CPU samples: \(summary.samples). Top leaf functions: \(summary.functions.count). Call paths: \(summary.callPaths.count).")
        print("Profile manifest: \(folder.appendingPathComponent("manifest.json").path)")
        print("Open \(trace.path) in Instruments. Profiling overhead makes this unsuitable for baseline comparisons.")
        return summary.samples == 0 ? 2 : 0
    }
}
#endif

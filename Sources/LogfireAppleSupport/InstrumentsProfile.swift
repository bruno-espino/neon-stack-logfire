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

struct CPUProfileSummary: Codable {
    var samples = 0
    var otherProcessSamples = 0
    var nonRunningSamples = 0
    var unresolvedSamples = 0
    var weightNanoseconds: Double = 0
    var mainThreadWeightNanoseconds: Double = 0
    var functions: [CPUFunction] = []
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
            if thread.attribute(forName: "fmt")?.stringValue?.hasPrefix("Main Thread (") == true {
                result.mainThreadWeightNanoseconds += nanoseconds
            }
            let stack = try resolve(row.elements(forName: "tagged-backtrace").first)
            guard let first = stack.elements(forName: "frame").first else { result.unresolvedSamples += 1; continue }
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

enum InstrumentsProfile {
    static func timeLimit(seconds: Double) -> String { "\(Int((seconds * 1000).rounded()))ms" }

    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.contains("--help") {
            print("Usage: logfire-apple profile [--seconds 5] [--service NAME] [--no-telemetry] [--sessions DIRECTORY] [--output DIRECTORY]")
            return 0
        }
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
        let result = try HostCommand.run("/usr/bin/xcrun", ["xctrace", "record", "--template", "Game Performance Overview",
            "--attach", String(session.pid), "--time-limit", timeLimit(seconds: options.seconds), "--output", trace.path, "--no-prompt"],
            output: folder.appendingPathComponent("record.stdout"), errors: folder.appendingPathComponent("record.stderr"), seconds: options.seconds + 60)
        guard result == 0 else { throw CompanionError.message("Instruments recording failed. Inspect \(folder.path)") }
        if kill(session.pid, 0) == 0 { try session.validate() }
        let toc = folder.appendingPathComponent("toc.xml")
        let cpu = folder.appendingPathComponent("cpu.xml")
        for (output, selection) in [(toc, ["--toc"]), (cpu, ["--xpath", "/trace-toc/run[@number='1']/data/table[@schema='time-profile']"])] {
            let status = try HostCommand.run("/usr/bin/xcrun", ["xctrace", "export", "--input", trace.path] + selection + ["--output", output.path],
                output: folder.appendingPathComponent(output.lastPathComponent + ".stdout"),
                errors: folder.appendingPathComponent(output.lastPathComponent + ".stderr"), seconds: 30)
            guard status == 0 else { throw CompanionError.message("Instruments export failed. Recording remains at \(trace.path)") }
        }
        let recording = try InstrumentsXML.recording(Data(contentsOf: toc), pid: session.pid)
        var summary = CPUProfileSummary()
        var summaryAvailable = true
        do { summary = try InstrumentsXML.cpu(Data(contentsOf: cpu), pid: session.pid) }
        catch { summaryAvailable = false; print("CPU summary unavailable. Inspect the retained export at \(cpu.path)") }
        var details: [String: Any] = recording.merging([
            "capture.id": folder.lastPathComponent, "capture.path": folder.path, "capture.storage": "local",
            "capture.kind": "instruments-cpu", "capture.tool": "apple.xctrace", "binary.sha256": binaryHash,
            "profile.template": "Game Performance Overview", "profile.requested_seconds": options.seconds,
            "profile.instrumented": true, "measurement.source": "apple.xctrace.time-profile",
            "measurement.scope": "process_cpu_samples", "cpu.samples": summary.samples,
            "cpu.sampled_weight_ms": summary.weightNanoseconds / 1_000_000,
            "cpu.main_thread_sampled_weight_ms": summary.mainThreadWeightNanoseconds / 1_000_000,
            "cpu.unresolved_samples": summary.unresolvedSamples, "cpu.other_process_samples": summary.otherProcessSamples,
            "cpu.non_running_samples": summary.nonRunningSamples,
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
        let client = Companion.client(local: options.local, service: session.metadata["service.name"] as? String ?? "apple-native")
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
        client.flush(); Companion.printDelivery(client)
        print("CPU samples: \(summary.samples). Top leaf functions: \(summary.functions.count).")
        print("Profile manifest: \(folder.appendingPathComponent("manifest.json").path)")
        print("Open \(trace.path) in Instruments. Profiling overhead makes this unsuitable for baseline comparisons.")
        return summary.samples == 0 ? 2 : 0
    }
}
#endif

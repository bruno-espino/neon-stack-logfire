import CryptoKit
import Foundation
import LogfireSwift
#if os(macOS)
import Darwin

enum CompanionError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "Native command failed" }
}

struct NativeSession {
    let id: String
    let pid: Int32
    let executable: URL
    let started: TimeInterval
    let metadata: [String: Any]
    let stateDomains: Set<String>

    init(marker: [String: Any], verify: Bool = true) throws {
        guard let id = marker["session_id"] as? String, UUID(uuidString: id) != nil,
              let pid = marker["pid"] as? NSNumber, pid.int32Value > 0,
              let path = marker["executable"] as? String, let started = marker["started_at"] as? Double else {
            throw CompanionError.message("Invalid development session marker")
        }
        self.id = id; self.pid = pid.int32Value; executable = URL(fileURLWithPath: path); self.started = started
        stateDomains = Set(marker["state_domains"] as? [String] ?? [])
        metadata = marker.filter { key, _ in
            key.hasPrefix("build.") || ["git.commit", "xcode.version", "service.name"].contains(key)
        }.merging(["session_id": id, "process.pid": self.pid]) { _, session in session }
        if verify { try validate() }
    }

    func validate() throws {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
        else { throw CompanionError.message("The session no longer identifies a running application") }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else {
            throw CompanionError.message("Cannot verify the application process")
        }
        let processStarted = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        guard 0 <= started - processStarted, started - processStarted < 60 else {
            throw CompanionError.message("The session marker identifies an older process")
        }
        let identity = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/LogfireBuild.json")
        if let data = try? Data(contentsOf: identity), let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let build = metadata["build.id"] as? String, values["build.id"] as? String != build {
            throw CompanionError.message("The app on disk changed after this session started")
        }
    }
}

enum HostCommand {
    static func run(_ executable: String, _ arguments: [String], output: URL, errors: URL,
                    seconds: Double, stopAtDeadline: Bool = false, onTick: (() throws -> Bool)? = nil,
                    onOutput: ((Data) throws -> Void)? = nil) throws -> Int32 {
        let result = try CommandRunner.run(executable, arguments, output: output, errors: errors,
            seconds: seconds, onOutput: onOutput, onTick: onTick)
        if result.timedOut {
            if stopAtDeadline { return 0 }
            throw CompanionError.message("Apple command exceeded its time limit. Inspect \(errors.path)")
        }
        return result.exitCode
    }
}

public enum Companion {
    public static func run(arguments: [String]) throws -> Int32 {
        guard let action = arguments.first, action != "--help" else { print(usage); return 0 }
        let values = Array(arguments.dropFirst())
        if action == "configure" { return try configure(values) }
        if action == "doctor" {
            print("Swift SDK and native companion require no Python runtime.")
            print("Session markers: \(Logfire.developmentSessionsDirectory.path)")
            do { _ = try configuration(); print("Runtime credentials: configured") }
            catch { print("Runtime credentials: unavailable. Configure the private development credential file.") }
            print("Native Metal tools: \(FileManager.default.isExecutableFile(atPath: "/usr/bin/metalperftrace") ? "available" : "unavailable (macOS 27 required)")")
            return 0
        }
        if action == "build" { return try NativeBuild.run(values) }
        if action == "test-game" { return try GameTest.run(values) }
        if action == "analyze" { return try SessionAnalysis.run(values) }
        if action == "profile" { return try InstrumentsProfile.run(values) }
        guard ["capture", "attach"].contains(action) else { throw CompanionError.message(usage) }
        if values.contains("--help") { print(usage); return 0 }
        guard #available(macOS 27.0, *) else { throw CompanionError.message("Native Metal monitoring requires macOS 27") }
        let options = try parse(values)
        let session = try latestSession(directory: options.sessions, service: options.service)
        let folder = options.output.appendingPathComponent(session.id).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let client: Logfire
        do { client = Logfire(serviceName: session.metadata["service.name"] as? String ?? "apple-native", configuration: options.local ? nil : try configuration()) }
        catch { print("Telemetry unavailable. Artifacts remain local."); client = Logfire(serviceName: "apple-native", configuration: nil) }
        if action == "capture" { try capture(session: session, folder: folder, seconds: options.seconds, client: client) }
        else { try attach(session: session, folder: folder, seconds: options.seconds, client: client) }
        return 0
    }

    static func configuration() throws -> LogfireConfiguration? {
        var environment = ProcessInfo.processInfo.environment; environment["LOGFIRE_DEV_DIRECT"] = "1"
        return try LogfireConfiguration.development(environment: environment)
    }

    static func configure(_ arguments: [String]) throws -> Int32 {
        if arguments.contains("--help") { print("Usage: logfire-apple configure [--region us|eu]"); return 0 }
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--region" && ["us", "eu"].contains(arguments[1])) else {
            throw CompanionError.message("Use configure --region us or configure --region eu")
        }
        let region = arguments.isEmpty ? "us" : arguments[1]
        guard let pointer = getpass("Logfire project write token (input hidden): ") else {
            throw CompanionError.message("Cannot read the write token from the terminal")
        }
        let token = String(cString: pointer)
        try saveCredentials(token: token, region: region, file: LogfireConfiguration.developmentCredentialFile)
        print("Saved private runtime credentials. Enable LOGFIRE_DEV_DIRECT=1 in your development scheme.")
        return 0
    }

    static func saveCredentials(token: String, region: String, file: URL) throws {
        let previousMask = umask(0o077)
        defer { umask(previousMask) }
        let base = "https://logfire-\(region).pydantic.dev"
        _ = try LogfireConfiguration(endpoint: URL(string: base + "/v1/traces")!, token: token)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data("LOGFIRE_TOKEN=\(token)\nLOGFIRE_BASE_URL=\(base)\n".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    struct Options {
        var seconds: Double = 10
        var service: String?
        var sessions = Logfire.developmentSessionsDirectory
        var output = URL(fileURLWithPath: ".xcode-observe/native", isDirectory: true)
        var local = false
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options(); var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--no-telemetry" { options.local = true; index += 1; continue }
            guard index + 1 < arguments.count else { throw CompanionError.message("Missing value for \(flag)") }
            let value = arguments[index + 1]
            switch flag {
            case "--last", "--seconds":
                let raw = value.hasSuffix("s") ? String(value.dropLast()) : value
                guard let seconds = Double(raw), seconds.isFinite, (1...3600).contains(seconds) else {
                    throw CompanionError.message("Use a duration between 1 and 3600 seconds")
                }
                options.seconds = seconds
            case "--service": options.service = value
            case "--sessions": options.sessions = URL(fileURLWithPath: value, isDirectory: true)
            case "--output": options.output = URL(fileURLWithPath: value, isDirectory: true)
            default: throw CompanionError.message("Unknown option \(flag)")
            }
            index += 2
        }
        return options
    }

    static func latestSession(directory: URL, service: String?) throws -> NativeSession {
        let markers = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let sessions = markers.filter { $0.pathExtension == "json" }.compactMap { file -> NativeSession? in
            guard let data = try? Data(contentsOf: file), let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = try? NativeSession(marker: marker), service == nil || session.metadata["service.name"] as? String == service else { return nil }
            return session
        }
        guard let selected = sessions.max(by: { $0.started < $1.started }) else {
            throw CompanionError.message("No matching live development session. Run the app with Logfire.development first.")
        }
        return selected
    }

    @discardableResult
    static func capture(session: NativeSession, folder: URL, seconds: Double, client: Logfire,
                        interval: ClosedRange<Date>? = nil) throws -> [[String: Any]] {
        let ended = interval?.upperBound.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let requestedStart = max(session.started, interval?.lowerBound.timeIntervalSince1970 ?? ended - seconds)
        let started = interval == nil ? requestedStart : session.started
        let collectedEnd = interval == nil ? ended : Date().timeIntervalSince1970
        guard ended > requestedStart, ended <= collectedEnd else { throw CompanionError.message("Invalid capture interval") }
        let code = try HostCommand.run("/usr/bin/metalperftrace", ["collect", "--start", "@\(started)", "--end", "@\(collectedEnd)",
            "--json", folder.path], output: folder.appendingPathComponent("collect.json"), errors: folder.appendingPathComponent("collect.stderr"), seconds: 60)
        let traces = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "atrc" }
        guard code == 0, !traces.isEmpty else { throw CompanionError.message("Apple capture failed. Inspect \(folder.path)") }
        var measurements: [[String: Any]] = []
        for trace in traces {
            let overview = trace.deletingPathExtension().appendingPathExtension("overview.json")
            let status = try HostCommand.run("/usr/bin/metalperftrace", ["overview", "--json", "--include-state-transitions", "--predicate",
                "pid == \(session.pid)", trace.path], output: overview, errors: folder.appendingPathComponent("overview.stderr"), seconds: 30)
            guard status == 0 else { throw CompanionError.message("Apple overview failed. Inspect \(folder.path)") }
            let processes = try JSONSerialization.jsonObject(with: Data(contentsOf: overview)) as? [[String: Any]] ?? []
            measurements += processes.flatMap { NativeMeasurements.summaries($0, pid: session.pid, stateDomains: session.stateDomains) }
            for (index, domain) in session.stateDomains.sorted().enumerated() {
                let stateFile = trace.deletingPathExtension().appendingPathExtension("state-\(index).json")
                var command = ["overview", "--json", "--aggregate", "--domain", domain,
                    "--predicate", "pid == \(session.pid)"]
                let rawState = interval == nil ? stateFile : trace.deletingPathExtension().appendingPathExtension("state-context-\(index).json")
                let stateCode = try HostCommand.run("/usr/bin/metalperftrace", command + [trace.path], output: rawState,
                    errors: folder.appendingPathComponent("state-\(index).stderr"), seconds: 30)
                guard stateCode == 0 else { throw CompanionError.message("State aggregation failed. Inspect \(folder.path)") }
                var states = try JSONSerialization.jsonObject(with: Data(contentsOf: rawState)) as? [[String: Any]] ?? []
                if let interval {
                    guard let own = states.first(where: { ($0["PID"] as? NSNumber)?.int32Value == session.pid }),
                          let window = own["Aggregation Window"] as? [String: Any], let start = window["Start"] as? String,
                          let origin = NativeMeasurements.date(start) else { throw CompanionError.message("Native state context is missing") }
                    let offsets = try NativeMeasurements.aggregationOffsets(interval, origin: origin)
                    command += ["--start", "\(offsets.lowerBound)s", "--end", "\(offsets.upperBound)s", trace.path]
                    let sliced = try HostCommand.run("/usr/bin/metalperftrace", command, output: stateFile,
                        errors: folder.appendingPathComponent("state-slice-\(index).stderr"), seconds: 30)
                    guard sliced == 0 else { throw CompanionError.message("State measurement slice failed") }
                    states = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [[String: Any]] ?? []
                }
                measurements += states.flatMap { NativeMeasurements.stateSummaries($0, pid: session.pid) }
            }
        }
        try session.validate()
        let app = session.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let symbols = URL(fileURLWithPath: app.path + ".dSYM")
        if FileManager.default.fileExists(atPath: symbols.path) { try FileManager.default.copyItem(at: symbols, to: folder.appendingPathComponent(symbols.lastPathComponent)) }
        var checksums: [String: String] = [:]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            checksums[String(file.path.dropFirst(folder.path.count + 1))] = try fileHash(file)
        }
        let details: [String: Any] = ["capture.id": folder.lastPathComponent, "capture.started_at": started, "capture.ended_at": collectedEnd,
            "measurement.requested_start": requestedStart, "measurement.requested_end": ended,
            "capture.path": folder.path, "capture.tool": "apple.metalperftrace", "capture.storage": "local",
            "capture.kind": "native-lookback", "binary.sha256": try fileHash(session.executable)]
        var manifest = session.metadata.merging(details) { _, capture in capture }
        manifest["artifacts"] = checksums; manifest["capture.measurements"] = measurements
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        client.event("game.profile.capture", attributes: attributes(session.metadata.merging(details) { _, capture in capture }))
        for measurement in measurements {
            client.event("game.native.capture_summary", attributes: attributes(session.metadata.merging(details) { _, capture in capture }.merging(measurement) { _, measured in measured }))
        }
        client.flush()
        print("Captured \(measurements.count) native summaries: \(folder.appendingPathComponent("manifest.json").path)")
        printDelivery(client)
        return measurements
    }

    static func attach(session: NativeSession, folder: URL, seconds: Double, client: Logfire) throws {
        let output = folder.appendingPathComponent("native.jsonl")
        var updates = JSONUpdates()
        var count = 0
        var host = SessionHostSamples()
        let code = try HostCommand.run("/usr/bin/metalperftrace", ["listen", "--pid", "\(session.pid)", "--json", "--interval", "1"],
            output: output, errors: folder.appendingPathComponent("native.stderr"), seconds: seconds, stopAtDeadline: true, onTick: {
                if host.isDue { try session.validate(); host.tick(client: client, context: session.metadata) }
                return false
            }) { data in
                guard !data.isEmpty else { return }
                try session.validate()
                for update in try updates.feed(data) {
                    for measurement in NativeMeasurements.summaries(update, pid: session.pid, stateDomains: session.stateDomains) {
                        client.event("game.native.performance", attributes: attributes(session.metadata.merging(measurement) { _, measured in measured }))
                        count += 1
                    }
                }
            }
        try host.write(to: folder.appendingPathComponent("host-samples.json"))
        guard code == 0 else { throw CompanionError.message("Apple live observation failed. Inspect \(folder.path)") }
        client.flush()
        print("Retained \(count) live native summaries: \(output.path)")
        printDelivery(client)
    }

    static func decodeUpdates(_ text: String) throws -> [[String: Any]] {
        var updates = JSONUpdates()
        return try updates.feed(Data(text.utf8))
    }

    static func attributes(_ values: [String: Any]) -> [String: LogfireAttribute] {
        values.compactMapValues { value in
            if let string = value as? String { return .string(string) }
            if let number = value as? NSNumber { return .double(number.doubleValue) }
            return nil
        }
    }

    static func fileHash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func printDelivery(_ client: Logfire) {
        let status = client.delivery
        if status.enabled { print("Exporter acknowledged \(status.exportedSpans) spans; failed spans: \(status.failedSpans)") }
        else { print("Export disabled. Measurements remain local.") }
    }

    static func client(local: Bool, service: String) -> Logfire {
        do { return Logfire(serviceName: service, configuration: local ? nil : try configuration()) }
        catch { print("Telemetry unavailable. Reports remain local."); return Logfire(serviceName: service, configuration: nil) }
    }

    static let usage = """
    Usage: logfire-apple configure [--region us|eu]
           logfire-apple doctor
           logfire-apple capture --last 10s [--service NAME] [--no-telemetry]
           logfire-apple attach --seconds 30 [--service NAME] [--no-telemetry]
           logfire-apple profile --seconds 5 [--service NAME] [--no-telemetry]
           logfire-apple build [--scenario NAME] [--no-telemetry] -- [xcodebuild arguments]
           logfire-apple test-game --app APP [--seconds 20] [--render-mode neon] [--offscreen] [--no-telemetry]
           logfire-apple analyze --report REPORT [--baseline REPORT] [--max-regression-percent 10]
    Capture, attach, and profile select the latest verified live SDK session automatically.
    Optional overrides: --sessions DIRECTORY --output DIRECTORY.
    All actions use Swift and Apple tools. Full reports and captures remain local.
    """
}

struct JSONUpdates {
    private var depth = 0
    private var quoted = false
    private var escaped = false
    private var buffer = Data()

    mutating func feed(_ data: Data) throws -> [[String: Any]] {
        var updates: [[String: Any]] = []
        for byte in data {
            if depth == 0 && byte != 123 { continue }
            buffer.append(byte)
            if buffer.count > 2_000_000 { throw CompanionError.message("Native JSON update exceeds the input limit") }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 { depth -= 1 }
            if depth == 0 {
                if let value = try JSONSerialization.jsonObject(with: buffer) as? [String: Any] { updates.append(value) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        return updates
    }
}
#else
public enum Companion {
    public static func run(arguments: [String]) throws -> Int32 { print("The native companion requires macOS."); return 1 }
}
#endif

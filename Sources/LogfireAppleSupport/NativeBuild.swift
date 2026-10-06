import Foundation
import LogfireSwift
import OpenTelemetryApi
#if os(macOS)
import Darwin

struct BuildArguments {
    var output = URL(fileURLWithPath: ".xcode-observe/builds", isDirectory: true)
    var scenario = "manual"
    var cache = "unknown"
    var sampleInterval: Double = 1
    var timeout: Double = 3600
    var runID: String?
    var local = false
    var xcode: [String] = []

    init(_ arguments: [String]) throws {
        guard let separator = arguments.firstIndex(of: "--") else {
            throw CompanionError.message("Supply xcodebuild arguments after --")
        }
        var index = 0
        while index < separator {
            let flag = arguments[index]
            if flag == "--no-telemetry" { local = true; index += 1; continue }
            guard index + 1 < separator else { throw CompanionError.message("Missing value for \(flag)") }
            let value = arguments[index + 1]
            switch flag {
            case "--artifact-dir", "--output": output = URL(fileURLWithPath: value, isDirectory: true)
            case "--scenario": scenario = value
            case "--cache-state":
                guard ["unknown", "cold", "warm"].contains(value) else { throw CompanionError.message("Invalid cache state") }
                cache = value
            case "--run-id": runID = value
            case "--sample-interval", "--timeout":
                guard let number = Double(value), number.isFinite,
                      (flag == "--timeout" ? (1...86400).contains(number) : (0.1...60).contains(number)) else {
                    throw CompanionError.message("Invalid \(flag)")
                }
                if flag == "--timeout" { timeout = number } else { sampleInterval = number }
            default: throw CompanionError.message("Unknown build option \(flag)")
            }
            index += 2
        }
        xcode = Array(arguments.dropFirst(separator + 1))
        if xcode.first == "xcodebuild" { xcode.removeFirst() }
        guard !xcode.isEmpty else { throw CompanionError.message("Supply xcodebuild arguments after --") }
        guard !xcode.contains(where: { $0.hasPrefix("LOGFIRE_BUILD_") }) else {
            throw CompanionError.message("The build command owns LOGFIRE_BUILD_ID and LOGFIRE_BUILD_TRACE_ID")
        }
    }
}

struct BuildOutput {
    private(set) var timings: [String: Double] = [:]
    private(set) var warnings = 0
    private(set) var errors = 0
    private var summary = false
    private static let timing = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+(?:\(\d+\s+tasks?\)\s*\|\s*)?(\d+(?:\.\d+)?)\s+seconds?\s*$"#)
    mutating func line(_ text: String) {
        warnings += text.range(of: #"\bwarning:"#, options: [.regularExpression, .caseInsensitive]) == nil ? 0 : 1
        errors += text.range(of: #"\berror:"#, options: [.regularExpression, .caseInsensitive]) == nil ? 0 : 1
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "Build Timing Summary" { summary = true; return }
        guard summary else { return }
        let range = NSRange(text.startIndex..., in: text)
        if let match = Self.timing.firstMatch(in: text, range: range),
           let name = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text),
           let seconds = Double(text[value]), seconds.isFinite {
            timings[String(text[name]), default: 0] += seconds
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { summary = false }
    }
}

enum NativeBuild {
    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.contains("--help") {
            print("Usage: logfire-apple build [--scenario NAME] [--cache-state warm] [--sample-interval 1] [--timeout 3600] [--output DIRECTORY] [--no-telemetry] -- XCODEBUILD_ARGUMENTS")
            return 0
        }
        let options = try BuildArguments(arguments)
        let id = UUID().uuidString.lowercased()
        let folder = options.output.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var command = options.xcode
        let supplied = value(command, "-resultBundlePath")
        let bundle = supplied.map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("Build.xcresult")
        if !command.contains("-showBuildTimingSummary") { command.append("-showBuildTimingSummary") }
        if supplied == nil { command += ["-resultBundlePath", bundle.path] }
        command.append("LOGFIRE_BUILD_ID=\(id)")
        var metadata: [String: Any] = ["build.id": id, "build.scenario": options.scenario, "build.cache_state": options.cache,
            "host.model": HostSamples.model, "host.macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "measurement.source": "apple.xcodebuild"]
        for (flag, key) in [("-scheme", "build.scheme"), ("-configuration", "build.configuration"), ("-sdk", "build.sdk"),
                            ("-destination", "build.destination"), ("-project", "build.project"), ("-workspace", "build.workspace")] {
            if let entry = value(command, flag) { metadata[key] = ["-project", "-workspace"].contains(flag) ? URL(fileURLWithPath: entry).lastPathComponent : entry }
        }
        if let run = options.runID { metadata["walkthrough.run_id"] = run }
        let client = Companion.client(local: options.local, service: "logfire-apple-build")
        var report: [String: Any] = ["schema_version": 1, "build_id": id, "metadata": metadata]
        var samples: [[String: Any]] = []; var observerErrors: [String] = []
        var host = HostSamples(); let began = ProcessInfo.processInfo.systemUptime
        var nextSample = began + options.sampleInterval
        var result = CommandResult(exitCode: 127, timedOut: false, requestedStop: false)
        client.withSpan("xcode.build", attributes: Companion.attributes(metadata)) {
            let span = OpenTelemetry.instance.contextProvider.activeSpan
            if client.delivery.enabled, let context = span?.context, context.isValid {
                report["trace_id"] = context.traceId.hexString
                command.append("LOGFIRE_BUILD_TRACE_ID=\(context.traceId.hexString)")
            }
            do {
                result = try CommandRunner.run("/usr/bin/xcodebuild", command,
                    output: folder.appendingPathComponent("build.log"), errors: folder.appendingPathComponent("build.stderr"),
                    environment: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LOGFIRE_") && !$0.key.hasPrefix("OTEL_") },
                    seconds: options.timeout, echo: true, onTick: {
                        let now = ProcessInfo.processInfo.systemUptime
                        if now >= nextSample {
                            let sample = host.sample(elapsed: now - began)
                            samples.append(sample)
                            client.event("xcode.host.sample", attributes: Companion.attributes(metadata.merging(sample) { _, measured in measured }))
                            nextSample = now + options.sampleInterval
                        }
                        return false
                    })
            } catch { observerErrors.append("Build process could not complete. Inspect retained output.") }
            if result.timedOut { observerErrors.append("Build exceeded its configured timeout.") }
            let duration = ProcessInfo.processInfo.systemUptime - began
            var parser = BuildOutput()
            for name in ["build.log", "build.stderr"] {
                if let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) { parser.line(line) }
                }
            }
            var warnings = parser.warnings; var errors = parser.errors
            if FileManager.default.fileExists(atPath: bundle.path) {
                do {
                    let resultFile = folder.appendingPathComponent("build-results.json")
                    let inspected = try CommandRunner.run("/usr/bin/xcrun", ["xcresulttool", "get", "build-results", "--path", bundle.path, "--compact"],
                        output: resultFile, errors: folder.appendingPathComponent("result.stderr"), seconds: 10)
                    if inspected.exitCode == 0, let values = try JSONSerialization.jsonObject(with: Data(contentsOf: resultFile)) as? [String: Any] {
                        warnings = (values["warningCount"] as? NSNumber)?.intValue ?? warnings
                        errors = (values["errorCount"] as? NSNumber)?.intValue ?? errors
                    } else { observerErrors.append("Result-bundle inspection failed.") }
                } catch { observerErrors.append("Result-bundle inspection failed.") }
                report["result_bundle"] = bundle.path
            }
            report["duration_seconds"] = duration; report["exit_code"] = result.timedOut ? 124 : result.exitCode
            report["timings"] = parser.timings; report["warnings"] = warnings; report["errors"] = errors
            for (name, value) in ["build.duration_seconds": duration, "build.exit_code": Double(result.exitCode),
                                  "build.warnings": Double(warnings), "build.errors": Double(errors)] {
                span?.setAttribute(key: name, value: value)
            }
            if result.exitCode != 0 { span?.status = .error(description: "Xcode build failed") }
            for (name, seconds) in parser.timings {
                client.event("xcode.build.task_summary", attributes: Companion.attributes(metadata.merging([
                    "build.task": name, "build.task_seconds": seconds, "measurement.scope": "aggregate_task_total",
                ]) { _, measured in measured }))
            }
        }
        client.flush()
        report["host_samples"] = samples; report["observation_errors"] = observerErrors
        report["delivery"] = ["enabled": client.delivery.enabled, "acknowledged_spans": client.delivery.exportedSpans,
            "failed_spans": client.delivery.failedSpans]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        print("Build exit \(result.exitCode). Report: \(folder.appendingPathComponent("report.json").path)")
        Companion.printDelivery(client)
        return result.timedOut ? 124 : result.exitCode
    }

    static func value(_ arguments: [String], _ key: String) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

struct HostSamples {
    static let model: String = {
        var length = 0; sysctlbyname("hw.model", nil, &length, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, length))
        return sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 ? String(cString: bytes) : "unknown"
    }()
    private var previous: [UInt32] = []
    init() { previous = cpuTicks() }
    mutating func sample(elapsed: Double) -> [String: Any] {
        var result: [String: Any] = ["elapsed_seconds": elapsed, "measurement.scope": "whole_host"]
        let current = cpuTicks()
        if previous.count == 4, current.count == 4 {
            let delta = zip(current, previous).map { Double($0 &- $1) }; let total = delta.reduce(0, +)
            if total > 0 { result["cpu_utilization"] = 1 - delta[Int(CPU_STATE_IDLE)] / total }
        }
        previous = current
        var memory = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            result["memory_free_bytes"] = UInt64(memory.free_count) * UInt64(vm_kernel_page_size)
            result["memory_wired_bytes"] = UInt64(memory.wire_count) * UInt64(vm_kernel_page_size)
            result["memory_compressed_bytes"] = UInt64(memory.compressor_page_count) * UInt64(vm_kernel_page_size)
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: FileManager.default.currentDirectoryPath),
           let free = attributes[.systemFreeSize] as? NSNumber { result["disk_free_bytes"] = free }
        return result
    }
    private func cpuTicks() -> [UInt32] {
        var cpu = host_cpu_load_info(); var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return [] }
        return [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
    }
}
#endif

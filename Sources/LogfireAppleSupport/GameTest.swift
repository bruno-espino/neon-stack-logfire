import Foundation
import LogfireSwift
#if os(macOS)
import Metal
import Darwin

struct GameTestOptions {
    var app: URL?
    var seconds: Double = 20
    var seed: UInt64 = 777
    var mode = "neon"
    var layers = 24
    var offscreen = false
    var local = false
    var native = true
    var output = URL(fileURLWithPath: ".xcode-observe/tests", isDirectory: true)
    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if ["--offscreen", "--no-telemetry", "--no-native"].contains(flag) {
                if flag == "--offscreen" { offscreen = true }
                if flag == "--no-telemetry" { local = true }
                if flag == "--no-native" { native = false }
                index += 1; continue
            }
            guard index + 1 < arguments.count else { throw CompanionError.message("Missing value for \(flag)") }
            let value = arguments[index + 1]
            switch flag {
            case "--app": app = URL(fileURLWithPath: value)
            case "--seconds":
                guard let number = Double(value), number.isFinite, (12...300).contains(number) else { throw CompanionError.message("Use --seconds between 12 and 300") }
                seconds = number
            case "--seed":
                guard let number = UInt64(value) else { throw CompanionError.message("Seed must fit UInt64") }; seed = number
            case "--render-mode":
                guard ["classic", "neon", "aurora"].contains(value) else { throw CompanionError.message("Invalid rendering mode") }; mode = value
            case "--aurora-layers":
                guard let number = Int(value), (1...48).contains(number) else { throw CompanionError.message("Use 1 to 48 Aurora layers") }; layers = number
            case "--output", "--artifact-dir": output = URL(fileURLWithPath: value, isDirectory: true)
            default: throw CompanionError.message("Unknown test option \(flag)")
            }
            index += 2
        }
        guard app != nil else { throw CompanionError.message("Supply --app BUILT_NEONSTACK_APP") }
        if offscreen { native = false }
    }
}

/// This reference-game adapter controls inputs. Apple tools supply presentation measurements.
enum GameTest {
    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.contains("--help") {
            print("Usage: logfire-apple test-game --app APP [--seconds 20] [--seed 777] [--render-mode neon] [--aurora-layers 24] [--offscreen] [--no-native] [--no-telemetry] [--output DIRECTORY]")
            return 0
        }
        let options = try GameTestOptions(arguments)
        guard let bundle = Bundle(url: options.app!), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path), bundle.bundleIdentifier == "dev.example.NeonStack" else {
            throw CompanionError.message("The test-game action requires a built NeonStack macOS app")
        }
        if options.native {
            guard #available(macOS 27.0, *) else { throw CompanionError.message("Native game tests require macOS 27. Use --no-native for SDK-only tests.") }
        }
        let build = Logfire.buildMetadata(bundle: bundle)
        let id = UUID().uuidString
        let folder = options.output.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let windowFile = folder.appendingPathComponent("performance.jsonl")
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LOGFIRE_") && !$0.key.hasPrefix("OTEL_") && !$0.key.hasPrefix("NEON_") }
        environment.merge(["LOGFIRE_DEV_DIRECT": "0", "LOGFIRE_TOKEN": "", "NEON_PERF_REPORT": windowFile.path,
            "NEON_BENCHMARK": "1", "NEON_SEED": String(options.seed), "NEON_RENDER_MODE": options.mode,
            "NEON_BENCHMARK_SECONDS": String(options.offscreen ? options.seconds : options.seconds + 120),
            "NEON_OFFSCREEN": options.offscreen ? "1" : "0", "NEON_AURORA_LAYERS": String(options.layers), "NEON_SESSION_ID": id]) { _, test in test }
        let client = Companion.client(local: options.local, service: "logfire-apple-test")
        var context = ["host.model": HostSamples.model, "host.memory_bytes": String(ProcessInfo.processInfo.physicalMemory),
            "host.processors": String(ProcessInfo.processInfo.processorCount), "gpu.name": MTLCreateSystemDefaultDevice()?.name ?? "unknown",
            "os.version": ProcessInfo.processInfo.operatingSystemVersionString, "seed": String(options.seed),
            "test.seconds": String(options.seconds), "test.protocol": "neon-stack-autoplay-v1"]
        context["native.enabled"] = String(options.native)
        context["native.interval_policy"] = "apple-whole-seconds-retained-slices-v1"
        var session: NativeSession?
        var native: [[String: Any]] = []; var issues: [String] = []; var collected = false
        let began = ProcessInfo.processInfo.systemUptime
        var result = CommandResult(exitCode: 127, timedOut: false, requestedStop: false)
        client.withSpan("game.test", attributes: Companion.attributes(build.merging(context) { _, test in test }.merging(["session_id": id]) { _, test in test })) {
            do {
                result = try CommandRunner.run(executable.path, [], output: folder.appendingPathComponent("console.log"),
                    errors: folder.appendingPathComponent("console.stderr"), environment: environment,
                    seconds: options.seconds + 180, onLaunch: { pid in
                        session = try NativeSession(marker: build.merging(["service.name": "neon-stack"]) { _, value in value }.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }.merging([
                            "session_id": id, "pid": pid, "executable": executable.path,
                            "started_at": Date().timeIntervalSince1970, "state_domains": ["dev.example.NeonStack.rendering"],
                        ]) { _, process in process })
                    }, onTick: {
                        guard !options.offscreen, !collected, ProcessInfo.processInfo.systemUptime - began >= options.seconds else { return false }
                        collected = true
                        if options.native, let session {
                            do {
                                let windows = try SessionAnalysis.windows(at: windowFile)
                                let interval = try measuredInterval(windows)
                                let capture = folder.appendingPathComponent("native")
                                try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                                native = try Companion.capture(session: session, folder: capture, seconds: options.seconds, client: client, interval: interval)
                            } catch { issues.append("Native capture failed. Inspect retained native output.") }
                        }
                        return true
                    })
            } catch { issues.append("Test process could not complete. Inspect retained console output.") }
        }
        let code: Int32 = result.timedOut ? 124 : result.requestedStop && [0, 143].contains(result.exitCode) ? 0 : result.exitCode
        if code != 0 { issues.append("Test application exited with code \(code).") }
        let windows: [[String: Any]]
        do { windows = try SessionAnalysis.windows(at: windowFile) }
        catch {
            try SessionAnalysis.write(["session_id": id, "error": "No valid complete performance windows", "exit_code": String(code)], to: folder.appendingPathComponent("failure.json"))
            throw CompanionError.message("Test has no valid performance windows. Inspect \(folder.path)")
        }
        let report = try SessionAnalysis.summarize(windows: windows, native: native, sessionID: id, build: build,
            context: context, nativeExpected: options.native, issues: issues)
        try SessionAnalysis.write(report, to: folder.appendingPathComponent("report.json"))
        for window in windows {
            if let interval = try? measuredInterval([window]) {
                client.window("game.performance.window", started: interval.lowerBound, ended: interval.upperBound,
                    attributes: Companion.attributes(build.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }.merging(window) { _, measured in measured }.merging(["session_id": id, "game.seed": String(options.seed)]) { _, test in test }))
            }
        }
        client.event("game.test.summary", attributes: Companion.attributes(build.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }.merging([
            "session_id": id, "test.report_path": folder.appendingPathComponent("report.json").path,
            "test.windows": windows.count, "test.native_layers": report.nativeLayers, "test.observation_gaps": report.issues.count,
        ]) { _, test in test }.merging(report.metrics) { _, measured in measured }))
        client.flush(); Companion.printDelivery(client)
        print("Test report: \(folder.appendingPathComponent("report.json").path)")
        print("Analysis uses worst window p95 values. They are not session percentiles.")
        return code != 0 ? code : report.issues.isEmpty ? 0 : 2
    }

    static func measuredInterval(_ windows: [[String: Any]]) throws -> ClosedRange<Date> {
        let formatter = ISO8601DateFormatter()
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var starts: [Date] = []; var ends: [Date] = []
        for window in windows {
            guard let value = window["recorded_at"] as? String, let duration = SessionAnalysis.number(window["window_seconds"]), duration > 0,
                  let end = precise.date(from: value) ?? formatter.date(from: value) else { throw CompanionError.message("Invalid measurement dates") }
            starts.append(end.addingTimeInterval(-duration)); ends.append(end)
        }
        guard let first = starts.min(), let last = ends.max(), last > first else { throw CompanionError.message("Invalid measurement interval") }
        return first...last
    }
}
#endif

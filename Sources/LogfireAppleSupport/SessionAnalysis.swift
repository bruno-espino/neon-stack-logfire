import Foundation
#if os(macOS)

struct SessionReport: Codable {
    var schemaVersion = 1
    let sessionID: String
    let build: [String: String]
    let cohort: [String: String]
    let metrics: [String: Double]
    let windows: Int
    let nativeExpected: Bool
    let nativeLayers: Int
    let issues: [String]
}

struct Comparison: Codable {
    let status: String
    let reasons: [String]
    let changes: [Change]
    struct Change: Codable {
        let metric: String
        let baseline: Double
        let current: Double
        let regressionPercent: Double?
        let regressed: Bool
    }
    var exitCode: Int32 { status == "passed" ? 0 : status == "regressed" ? 1 : 2 }
}

enum SessionAnalysis {
    static let lowerIsBetter = ["sdk_worst_window_frame_interval_p95_ms", "sdk_worst_window_gpu_command_p95_ms",
        "sdk_slow_frame_fraction", "native_frame_on_glass_mean_ms", "native_gpu_wall_mean_ms"]
    static let higherIsBetter = ["sdk_callback_hz", "native_presented_fps"]

    static func windows(at file: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: file, encoding: .utf8)
        let values = try text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line -> [String: Any] in
            guard let data = line.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CompanionError.message("Invalid performance window")
            }
            for key in ["frames", "window_seconds", "render_callback_fps", "frame_interval_p95_ms", "drawable_width", "drawable_height"] {
                guard let value = number(object[key]), value > 0 else { throw CompanionError.message("Invalid window field \(key)") }
            }
            guard let slow = number(object["frames_over_25_ms"]), slow >= 0, slow <= number(object["frames"])!,
                  let thermal = number(object["thermal_state"]), (0...3).contains(thermal),
                  ["onscreen", "offscreen"].contains(object["workload"] as? String ?? ""),
                  let mode = object["render_mode"] as? String, !mode.isEmpty, mode.count <= 128 else {
                throw CompanionError.message("Invalid window cohort or frame counts")
            }
            return object
        }
        guard !values.isEmpty else { throw CompanionError.message("No complete performance windows") }
        return values
    }

    static func summarize(windows: [[String: Any]], native: [[String: Any]], sessionID: String,
                          build: [String: String], context: [String: String], nativeExpected: Bool, issues: [String]) throws -> SessionReport {
        guard let first = windows.first else { throw CompanionError.message("No complete performance windows") }
        let fields = ["render_mode", "workload", "aurora_layers", "drawable_width", "drawable_height"]
        var cohort = context
        for key in fields {
            let values = Set(windows.map { String(describing: $0[key] ?? "unknown") })
            guard values.count == 1 else { throw CompanionError.message("Mixed \(key) values. Retain separate scenario reports.") }
            cohort[key] = String(describing: first[key] ?? "unknown")
        }
        cohort["thermal_states"] = Set(windows.map { String(describing: $0["thermal_state"] ?? "unknown") }).sorted().joined(separator: ",")
        cohort["configuration"] = build["build.configuration"] ?? "unknown"
        let frames = windows.compactMap { number($0["frames"]) }.reduce(0, +)
        let intervals = windows.reduce(0.0) { total, window in
            total + (number(window["frames"]) ?? 0) * 1000 / (number(window["render_callback_fps"]) ?? 1)
        }
        var metrics = ["sdk_callback_hz": frames * 1000 / intervals,
            "sdk_slow_frame_fraction": windows.compactMap { number($0["frames_over_25_ms"]) }.reduce(0, +) / frames,
            "sdk_worst_window_frame_interval_p95_ms": windows.compactMap { number($0["frame_interval_p95_ms"]) }.max() ?? 0]
        var problems = issues
        let gpu = windows.compactMap { number($0["gpu_command_p95_ms"]) }
        if gpu.count == windows.count { metrics["sdk_worst_window_gpu_command_p95_ms"] = gpu.max() }
        else { problems.append("Some SDK windows have no GPU measurement.") }
        if windows.contains(where: { $0["sample_limit_reached"] as? Bool == true }) { problems.append("SDK sample limit reached.") }
        let layers = native.filter { measurement in
            guard measurement["measurement.scope"] as? String == "state_layer",
                  measurement["state.domain"] as? String == "dev.example.NeonStack.rendering",
                  measurement["state.label"] as? String == cohort["render_mode"],
                  let text = measurement["state.metadata"] as? String,
                  let data = text.data(using: .utf8),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return fields.allSatisfy { String(describing: metadata[$0] ?? "unknown") == cohort[$0] }
        }
        if nativeExpected {
            if layers.count == 1, let layer = layers.first, (number(layer["presented_frames"]) ?? 0) > 0 {
                for (input, output) in [("presented_fps", "native_presented_fps"), ("frame_on_glass_mean_ms", "native_frame_on_glass_mean_ms"),
                                        ("gpu_wall_mean_ms", "native_gpu_wall_mean_ms")] {
                    if let value = number(layer[input]), value > 0 { metrics[output] = value }
                }
                let measured = windows.compactMap { number($0["window_seconds"]) }.reduce(0, +)
                if let wanted = try? GameTest.measuredInterval(windows),
                   let startText = layer["measurement.started_at"] as? String,
                   let endText = layer["measurement.ended_at"] as? String,
                   let start = NativeMeasurements.date(startText), let end = NativeMeasurements.date(endText), end > start {
                    let overlap = max(0, min(end, wanted.upperBound).timeIntervalSince(max(start, wanted.lowerBound)))
                    metrics["native_sdk_interval_coverage"] = min(1, overlap / measured)
                    if start.timeIntervalSince(wanted.lowerBound) > 1 || wanted.upperBound.timeIntervalSince(end) > 1
                        || (number(layer["window_seconds"]) ?? 0) < measured - 2 {
                        problems.append("Native layer coverage loses more than one second at an SDK interval boundary.")
                    }
                } else { problems.append("Native or SDK measurement dates are unavailable.") }
            } else { problems.append("Native comparison requires exactly one state layer with matching rendering context.") }
        }
        guard metrics.values.allSatisfy({ $0.isFinite }) else { throw CompanionError.message("Nonfinite session measurements") }
        return SessionReport(sessionID: sessionID, build: build, cohort: cohort, metrics: metrics,
            windows: windows.count, nativeExpected: nativeExpected, nativeLayers: layers.count, issues: problems)
    }

    static func compare(_ current: SessionReport, baseline: SessionReport, threshold: Double) -> Comparison {
        var reasons: [String] = []
        if current.schemaVersion != 1 || baseline.schemaVersion != 1 { reasons.append("Unsupported report schema.") }
        if current.cohort != baseline.cohort { reasons.append("Device, OS, settings, seed, duration, resolution, or thermal cohort differs.") }
        if current.cohort["configuration"] != "Release" || baseline.cohort["configuration"] != "Release" {
            reasons.append("A regression gate requires Release builds.")
        }
        if ["host.model", "gpu.name", "host.memory_bytes", "host.processors", "os.version", "seed", "test.seconds", "test.protocol"].contains(where: { current.cohort[$0] == nil || current.cohort[$0] == "unknown" }) { reasons.append("Test or device identity is unavailable.") }
        if current.windows < 3 || baseline.windows < 3 { reasons.append("A regression gate requires at least three complete windows per run.") }
        if current.nativeExpected != baseline.nativeExpected { reasons.append("Native capture coverage differs.") }
        if !current.issues.isEmpty || !baseline.issues.isEmpty { reasons.append("A report has observation gaps. Inspect its issues.") }
        guard reasons.isEmpty else { return Comparison(status: "not_comparable", reasons: reasons, changes: []) }
        let keys = lowerIsBetter + higherIsBetter
        var changes: [Comparison.Change] = []
        for key in keys where current.nativeExpected || !key.hasPrefix("native_") {
            guard let before = baseline.metrics[key], let after = current.metrics[key],
                  before.isFinite, after.isFinite, before >= 0, after >= 0 else {
                reasons.append("Missing or invalid measurement \(key)."); continue
            }
            let difference = lowerIsBetter.contains(key) ? after - before : before - after
            let percent = before == 0 ? nil : difference / before * 100
            changes.append(.init(metric: key, baseline: before, current: after, regressionPercent: percent,
                regressed: before == 0 ? difference > 0 : (percent ?? 0) > threshold))
        }
        return Comparison(status: reasons.isEmpty ? (changes.contains { $0.regressed } ? "regressed" : "passed") : "incomplete",
            reasons: reasons, changes: changes)
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        if arguments.contains("--help") { print("Usage: logfire-apple analyze --report REPORT [--baseline REPORT] [--max-regression-percent 10]"); return 0 }
        var file: URL?; var baseline: URL?; var threshold = 10.0
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw CompanionError.message("Missing analysis option value") }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--report": file = URL(fileURLWithPath: value)
            case "--baseline": baseline = URL(fileURLWithPath: value)
            case "--max-regression-percent":
                guard let number = Double(value), number.isFinite, (0...1000).contains(number) else { throw CompanionError.message("Invalid regression threshold") }
                threshold = number
            default: throw CompanionError.message("Unknown analysis option \(arguments[index])")
            }
            index += 2
        }
        guard let file else { throw CompanionError.message("Supply --report REPORT") }
        let current = try JSONDecoder().decode(SessionReport.self, from: Data(contentsOf: file))
        if let baseline {
            let previous = try JSONDecoder().decode(SessionReport.self, from: Data(contentsOf: baseline))
            let comparison = compare(current, baseline: previous, threshold: threshold)
            let output = file.deletingLastPathComponent().appendingPathComponent("comparison-\(UUID().uuidString.lowercased()).json")
            try write(comparison, to: output)
            print("Comparison: \(comparison.status). Retained: \(output.path)")
            for reason in comparison.reasons { print(reason) }
            return comparison.exitCode
        }
        print("Session \(current.sessionID): \(current.windows) complete SDK windows, \(current.nativeLayers) native layers")
        for key in current.metrics.keys.sorted() { print("\(key): \(current.metrics[key]!)") }
        for issue in current.issues { print("Observation: \(issue)") }
        return 0
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

#endif

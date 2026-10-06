import Foundation
import QuartzCore
import LogfireSwift
#if canImport(StateReporting)
import StateReporting

@available(macOS 27.0, iOS 27.0, *)
@ReportableMetadata
struct RenderStateMetadata { let workload: String; let auroraLayers: Int }

@available(macOS 27.0, iOS 27.0, *)
@ReportableMetadata
struct SessionStateMetadata { let sessionID: String; let buildID: String }

@available(macOS 27.0, iOS 27.0, *)
enum NativeGameState {
    static let reporter = StateReporter.reporter(for: "dev.example.NeonStack.rendering",
        stableMetadata: RenderStateMetadata.self, volatileMetadata: SessionStateMetadata.self)
    static func report(mode: String, workload: String, auroraLayers: Int) {
        reporter.reportTransition(to: mode, stableMetadata: RenderStateMetadata(workload: workload, auroraLayers: auroraLayers),
            volatileMetadata: SessionStateMetadata(sessionID: GameTelemetry.client.sessionID,
                buildID: Logfire.buildMetadata(bundle: .main)["build.id"] ?? "unknown"))
    }
}
#endif

enum GameTelemetry {
    static let configuration: LogfireConfiguration? = {
        do { return try LogfireConfiguration.development() }
        catch { print("Logfire development configuration unavailable. Check the runtime credentials."); return nil }
    }()
    static let fieldReports: AnyObject? = {
        if #available(macOS 27.0, iOS 27.0, *) {
            return MetricKitReports(serviceName: "neon-stack", configuration: configuration,
                stateDomains: ["dev.example.NeonStack.rendering"], metadataKeys: ["workload", "auroraLayers"])
        }
        return nil
    }()
    static let client: Logfire = {
        let client = Logfire(serviceName: "neon-stack", configuration: configuration)
        client.publishDevelopmentSession(directory: ProcessInfo.processInfo.environment["NEON_OBSERVER_DIR"])
        return client
    }()
}

final class PerformanceRecorder {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.example.NeonStack.performance-writer")
    private let started = CACurrentMediaTime()
    private var windowStarted: Double = 0
    private var frames: [Double] = []
    private var cpu: [Double] = []
    private var gpu: [Double] = []
    private var latest: (Double, Double)?
    private var cohort: String?
    private let output = ProcessInfo.processInfo.environment["NEON_PERF_REPORT"]

    func record(frameMilliseconds: Double, cpuMilliseconds: Double, gpuMilliseconds: Double?,
                mode: String, lines: Int, score: Int, width: Int, height: Int, workload: String = "onscreen", auroraLayers: Int = 0) {
        let now = CACurrentMediaTime()
        guard now - started >= 2 else { return }
        lock.lock()
        let currentCohort = "\(mode)/\(workload)/\(width)/\(height)/\(auroraLayers)"
        if cohort != currentCohort {
            cohort = currentCohort
            frames.removeAll(keepingCapacity: true); cpu.removeAll(keepingCapacity: true); gpu.removeAll(keepingCapacity: true)
            windowStarted = now
#if canImport(StateReporting)
            if #available(macOS 27.0, iOS 27.0, *) { NativeGameState.report(mode: mode, workload: workload, auroraLayers: auroraLayers) }
#endif
        }
        if windowStarted == 0 { windowStarted = now }
        frames.append(frameMilliseconds); cpu.append(cpuMilliseconds)
        if let value = gpuMilliseconds, value > 0 { gpu.append(value) }
        guard now - windowStarted >= 5 else { lock.unlock(); return }
        let elapsed = now - windowStarted
        let fps = 1000 / (frames.reduce(0, +) / Double(frames.count))
        let gpuMean = gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count)
        latest = (fps, gpuMean)
        var data: [String: Any] = [
            "recorded_at": ISO8601DateFormatter().string(from: Date()),
            "elapsed_seconds": now - started, "window_seconds": elapsed, "frames": frames.count,
            "render_mode": mode, "render_callback_fps": fps,
            "frame_interval_p50_ms": percentile(frames, 0.5), "frame_interval_p95_ms": percentile(frames, 0.95),
            "cpu_frame_p95_ms": percentile(cpu, 0.95), "gpu_samples": gpu.count,
            "frames_over_25_ms": frames.filter { $0 > 25 }.count,
            "lines": lines, "score": score, "drawable_width": width, "drawable_height": height,
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
            "workload": workload, "aurora_layers": auroraLayers,
        ]
        if !gpu.isEmpty { data["gpu_command_p95_ms"] = percentile(gpu, 0.95) }
        frames.removeAll(keepingCapacity: true); cpu.removeAll(keepingCapacity: true); gpu.removeAll(keepingCapacity: true)
        windowStarted = now
        lock.unlock()
        let snapshot = data
        let ended = Date()
        writer.async {
            var attributes: [String: LogfireAttribute] = [:]
            for (key, value) in snapshot {
                if let value = value as? String { attributes[key] = .string(value) }
                else if let value = value as? Int { attributes[key] = .int(value) }
                else if let value = value as? Double { attributes[key] = .double(value) }
            }
            attributes["frame_encode_wall_p95_ms"] = attributes["cpu_frame_p95_ms"]
            GameTelemetry.client.window("game.performance.window", started: ended.addingTimeInterval(-elapsed),
                                        ended: ended, attributes: attributes)
            guard let output = self.output else { return }
            do {
                let encoded = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) + Data([10])
                let url = URL(fileURLWithPath: output)
                if !FileManager.default.fileExists(atPath: output) {
                    _ = FileManager.default.createFile(atPath: output, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd(); try file.write(contentsOf: encoded)
            } catch { print("Performance report write failed: \(error.localizedDescription)") }
        }
    }
    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * quantile)) - 1)]
    }
    func display() -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        let result = latest; latest = nil
        return result
    }
    func finish() { writer.sync {}; GameTelemetry.client.flush() }
}

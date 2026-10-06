import Foundation
import LogfireSwift
import Metal

enum GameTelemetry {
    static let scenario = DevelopmentScenario(client: client)
    static let client: Logfire = {
        do {
            return try Logfire.development(serviceName: "neon-stack", apple: .init(responsiveness: true,
                stateDomains: ["dev.example.NeonStack.rendering"],
                metadataKeys: ["workload", "aurora_layers", "particles"]))
        } catch {
            print("Logfire development configuration unavailable. Check the runtime credentials.")
            return Logfire(serviceName: "neon-stack", configuration: nil)
        }
    }()
}

final class PerformanceRecorder {
    private let lock = NSLock()
    private var latest: (Double, Double)?
    private let output = ProcessInfo.processInfo.environment["NEON_PERF_REPORT"]
    private var recorder: FrameRecorder!
    private var stageSamples: [String: [(uptime: Double, milliseconds: Double)]] = [:]

    init() {
        recorder = FrameRecorder(client: GameTelemetry.client,
        stateDomain: "dev.example.NeonStack.rendering") { [weak self] window in
            guard let self else { return }
            lock.lock(); latest = (window.callbackFPS, window.gpuMeanMilliseconds ?? 0); lock.unlock()
            do { try GameTelemetry.scenario?.record(window) }
            catch { print("Scenario renderer report failed: \(error)") }
            guard let output else { return }
            do {
                let url = URL(fileURLWithPath: output)
                if !FileManager.default.fileExists(atPath: output) {
                    _ = FileManager.default.createFile(atPath: output, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd(); try file.write(contentsOf: window.encodedReport())
            } catch { print("Performance report write failed") }
        }
    }

    func record(commandBuffer: MTLCommandBuffer, frameMilliseconds: Double, cpuMilliseconds: Double,
                mode: String, lines: Int, score: Int, width: Int, height: Int, workload: String = "onscreen", auroraLayers: Int = 0) {
        recorder.record(commandBuffer: commandBuffer, frameMilliseconds: frameMilliseconds, preparationMilliseconds: cpuMilliseconds,
            context: RenderContext(mode: mode, width: width, height: height, workload: workload,
                metadata: ["aurora_layers": .int(auroraLayers)]),
            attributes: ["lines": .int(lines), "score": .int(score)])
    }

    /// Log Roll submits three command buffers per frame. Each window reports their summed GPU time and,
    /// for each stage, the p95 over the last five seconds, which matches the recorder's window length.
    func record(gpuStages: [String: Double], frameMilliseconds: Double, cpuMilliseconds: Double,
                score: Int, width: Int, height: Int, workload: String = "onscreen", particles: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        var attributes: [String: LogfireAttribute] = ["score": .int(score)]
        lock.lock()
        for (stage, value) in gpuStages where value > 0 { stageSamples[stage, default: []].append((now, value)) }
        for stage in stageSamples.keys {
            stageSamples[stage]?.removeAll { now - $0.uptime > 5 }
            let sorted = (stageSamples[stage] ?? []).map(\.milliseconds).sorted()
            if !sorted.isEmpty {
                attributes["gpu_\(stage)_p95_ms"] = .double(sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)])
            }
        }
        lock.unlock()
        let total = gpuStages.values.reduce(0, +)
        recorder.record(frameMilliseconds: frameMilliseconds, preparationMilliseconds: cpuMilliseconds,
            gpuMilliseconds: total > 0 ? total : nil,
            context: RenderContext(mode: "log-roll", width: width, height: height, workload: workload,
                metadata: ["game": .string("log-roll"), "particles": .int(particles)], gpuTimeScope: .commandBufferSum),
            attributes: attributes)
    }

    func display() -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        let result = latest; latest = nil
        return result
    }
    func finish() { recorder.finish() }
}

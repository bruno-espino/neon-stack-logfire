import Foundation
import LogfireSwift
import Metal

enum GameTelemetry {
    static let client: Logfire = {
        do {
            return try Logfire.development(serviceName: "neon-stack", apple: .init(
                stateDomains: ["dev.example.NeonStack.rendering"],
                metadataKeys: ["workload", "aurora_layers"]))
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

    init() {
        recorder = FrameRecorder(client: GameTelemetry.client,
        stateDomain: "dev.example.NeonStack.rendering") { [weak self] window in
            guard let self else { return }
            lock.lock(); latest = (window.callbackFPS, window.gpuMeanMilliseconds ?? 0); lock.unlock()
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

    func display() -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        let result = latest; latest = nil
        return result
    }
    func finish() { recorder.finish() }
}

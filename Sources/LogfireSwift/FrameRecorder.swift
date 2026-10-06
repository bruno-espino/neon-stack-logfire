import Foundation
import Metal

public struct RenderContext: Equatable {
    public let mode: String
    public let width: Int
    public let height: Int
    public let workload: String
    public let metadata: [String: LogfireAttribute]

    public init(mode: String, width: Int, height: Int, workload: String = "onscreen",
                metadata: [String: LogfireAttribute] = [:]) {
        self.mode = mode; self.width = width; self.height = height
        self.workload = workload; self.metadata = metadata
    }

    var attributes: [String: LogfireAttribute] {
        metadata.merging(["render_mode": .string(mode), "drawable_width": .int(width),
            "drawable_height": .int(height), "workload": .string(workload)]) { _, context in context }
    }
}

public struct FrameWindow {
    public let started: Date
    public let ended: Date
    public let callbackFPS: Double
    public let gpuMeanMilliseconds: Double?
    public let attributes: [String: LogfireAttribute]

    public func encodedReport() throws -> Data {
        let values: [String: Any] = attributes.compactMapValues { value in
            switch value {
            case .string(let value): return value
            case .int(let value): return value
            case .double(let value): return value
            case .bool(let value): return value
            default: return nil
            }
        }
        return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) + Data([10])
    }
}

/// Record completed frames. Callback cadence does not measure display presentation.
public final class FrameRecorder {
    private let client: Logfire
    private let domain: String
    private let spanName: String
    private let onWindow: ((FrameWindow) -> Void)?
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.logfire.swift.frames")
    private let began: TimeInterval
    private var windowBegan: TimeInterval?
    private var windowDate: Date?
    private var context: RenderContext?
    private var frames: [Double] = []
    private var preparation: [Double] = []
    private var gpu: [Double] = []

    public convenience init(client: Logfire, stateDomain: String, spanName: String = "game.performance.window",
                            onWindow: ((FrameWindow) -> Void)? = nil) {
        self.init(client: client, stateDomain: stateDomain, spanName: spanName, began: ProcessInfo.processInfo.systemUptime,
            onWindow: onWindow)
    }

    init(client: Logfire, stateDomain: String, spanName: String, began: TimeInterval,
         onWindow: ((FrameWindow) -> Void)? = nil) {
        self.client = client; domain = stateDomain; self.spanName = spanName
        self.began = began; self.onWindow = onWindow
    }

    /// Invoke after the Metal command buffer completes.
    public func record(commandBuffer: MTLCommandBuffer, frameMilliseconds: Double, preparationMilliseconds: Double,
                       context: RenderContext, attributes: [String: LogfireAttribute] = [:]) {
        let duration = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        record(frameMilliseconds: frameMilliseconds, preparationMilliseconds: preparationMilliseconds,
            gpuMilliseconds: commandBuffer.gpuStartTime > 0 && duration > 0 ? duration : nil, context: context, attributes: attributes)
    }

    public func record(frameMilliseconds: Double, preparationMilliseconds: Double, gpuMilliseconds: Double?,
                       context: RenderContext, attributes: [String: LogfireAttribute] = [:]) {
        record(frameMilliseconds: frameMilliseconds, preparationMilliseconds: preparationMilliseconds,
            gpuMilliseconds: gpuMilliseconds, context: context, attributes: attributes,
            uptime: ProcessInfo.processInfo.systemUptime, wallTime: Date())
    }

    func record(frameMilliseconds: Double, preparationMilliseconds: Double, gpuMilliseconds: Double?,
                context next: RenderContext, attributes: [String: LogfireAttribute], uptime: TimeInterval, wallTime: Date) {
        guard uptime - began >= 2, frameMilliseconds.isFinite, frameMilliseconds > 0,
              preparationMilliseconds.isFinite, preparationMilliseconds >= 0 else { return }
        lock.lock()
        if context != next {
            context = next
            frames.removeAll(keepingCapacity: true); preparation.removeAll(keepingCapacity: true); gpu.removeAll(keepingCapacity: true)
            windowBegan = uptime; windowDate = wallTime
            client.state(domain: domain, label: next.mode, metadata: next.attributes)
        }
        guard let windowBegan, let windowDate else { lock.unlock(); return }
        // Bound memory when a caller submits frames faster than its display cadence.
        if frames.count < 10000 {
            frames.append(frameMilliseconds); preparation.append(preparationMilliseconds)
            if let value = gpuMilliseconds, value.isFinite, value > 0 { gpu.append(value) }
        }
        let elapsed = uptime - windowBegan
        guard elapsed >= 5 else { lock.unlock(); return }
        let fps = 1000 / (frames.reduce(0, +) / Double(frames.count))
        var values = attributes.merging(next.attributes) { _, context in context }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        values.merge([
            "recorded_at": .string(formatter.string(from: windowDate.addingTimeInterval(elapsed))),
            "elapsed_seconds": .double(uptime - began), "window_seconds": .double(elapsed), "frames": .int(frames.count),
            "render_callback_fps": .double(fps), "frame_interval_p50_ms": .double(percentile(frames, 0.5)),
            "frame_interval_p95_ms": .double(percentile(frames, 0.95)),
            "frame_encode_wall_p95_ms": .double(percentile(preparation, 0.95)),
            "cpu_frame_p95_ms": .double(percentile(preparation, 0.95)), "gpu_samples": .int(gpu.count),
            "frames_over_25_ms": .int(frames.filter { $0 > 25 }.count),
            "sample_limit_reached": .bool(frames.count == 10000),
            "thermal_state": .int(ProcessInfo.processInfo.thermalState.rawValue),
        ]) { _, measured in measured }
        if !gpu.isEmpty { values["gpu_command_p95_ms"] = .double(percentile(gpu, 0.95)) }
        let window = FrameWindow(started: windowDate, ended: windowDate.addingTimeInterval(elapsed), callbackFPS: fps,
            gpuMeanMilliseconds: gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count), attributes: values)
        frames.removeAll(keepingCapacity: true); preparation.removeAll(keepingCapacity: true); gpu.removeAll(keepingCapacity: true)
        self.windowBegan = uptime; self.windowDate = window.ended
        writer.async { [self] in
            client.window(spanName, started: window.started, ended: window.ended, attributes: window.attributes)
            onWindow?(window)
        }
        lock.unlock()
    }

    /// Call after the renderer stops submitting frames, outside its completion callback.
    public func finish() { writer.sync {}; client.flush() }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * quantile)) - 1)]
    }
}

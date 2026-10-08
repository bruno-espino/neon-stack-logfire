import Foundation
import Metal

public enum RenderGPUTimeScope: String, Sendable { case commandBuffer = "command_buffer", commandBufferSum = "sum_of_command_buffers" }

public struct RenderContext: Equatable, Sendable {
    public let mode: String
    public let width: Int
    public let height: Int
    public let workload: String
    public let gpuTimeScope: RenderGPUTimeScope
    public let metadata: [String: LogfireAttribute]

    public init(mode: String, width: Int, height: Int, workload: String = "onscreen",
                metadata: [String: LogfireAttribute] = [:], gpuTimeScope: RenderGPUTimeScope = .commandBuffer) {
        self.mode = mode; self.width = width; self.height = height
        self.workload = workload; self.metadata = metadata; self.gpuTimeScope = gpuTimeScope
    }

    var attributes: [String: LogfireAttribute] {
        metadata.merging(["render_mode": .string(mode), "drawable_width": .int(width),
            "drawable_height": .int(height), "workload": .string(workload), "gpu_time.scope": .string(gpuTimeScope.rawValue)]) { _, context in context }
    }
}

public struct FrameWindow: Sendable {
    public let started: Date
    public let ended: Date
    public let callbackFPS: Double
    public let gpuMeanMilliseconds: Double?
    public let attributes: [String: LogfireAttribute]
    public var presentedFPS: Double? {
        if case .double(let value) = attributes["display_presented_fps"] { return value }
        return nil
    }

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

/// Record completed renderer frames. Preparation wall time excludes other main-thread and SwiftUI work.
/// Callback cadence does not measure display presentation.
/// The lock protects sample state. The writer serializes reports and invokes Sendable callbacks.
public final class FrameRecorder: @unchecked Sendable {
    private let client: Logfire
    private let domain: String
    private let spanName: String
    private let onWindow: (@Sendable (FrameWindow) -> Void)?
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.logfire.swift.frames")
    // Every writer uses this immutable key. A callback must not synchronously wait on another writer.
    private static let writerKey = DispatchSpecificKey<Bool>()
    private let began: TimeInterval
    private var windowBegan: TimeInterval?
    private var windowDate: Date?
    private var context: RenderContext?
    private var frames: [Double] = []
    private var preparation: [Double] = []
    private var gpu: [Double] = []
    private var lastAttributes: [String: LogfireAttribute] = [:]
    private var presentedTimes: [TimeInterval] = []
    private var previousPresentedTime: TimeInterval?
    private var lateness: [Double] = []
    private var unavailablePresentations = 0
    private var finished = false

    public convenience init(client: Logfire, stateDomain: String, spanName: String = "game.performance.window",
                            onWindow: (@Sendable (FrameWindow) -> Void)? = nil) {
        self.init(client: client, stateDomain: stateDomain, spanName: spanName, began: ProcessInfo.processInfo.systemUptime,
            onWindow: onWindow)
    }

    init(client: Logfire, stateDomain: String, spanName: String, began: TimeInterval,
         onWindow: (@Sendable (FrameWindow) -> Void)? = nil) {
        self.client = client; domain = stateDomain; self.spanName = spanName
        self.began = began; self.onWindow = onWindow
        writer.setSpecific(key: Self.writerKey, value: true)
        client.register(self)
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
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if context != next {
            publish(uptime: uptime, partial: true)
            context = next
            previousPresentedTime = nil
            windowBegan = uptime; windowDate = wallTime
            client.state(domain: domain, label: next.mode, metadata: next.attributes)
        }
        lastAttributes = attributes
        // Bound memory when a caller submits frames faster than its display cadence.
        if frames.count < 10000 {
            frames.append(frameMilliseconds); preparation.append(preparationMilliseconds)
            if let value = gpuMilliseconds, value.isFinite, value > 0 { gpu.append(value) }
        }
        guard let windowBegan, uptime - windowBegan >= 5 else { return }
        publish(uptime: uptime, partial: false)
    }

    /// Register before presenting. Target time uses the same host clock as Metal's presentedTime.
    /// The recorder also requires completed renderer observations through record.
    public func observe(_ drawable: MTLDrawable, context: RenderContext, targetPresentationTime: TimeInterval? = nil) {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let enabled = !finished && uptime - began >= 2
        lock.unlock()
        guard enabled else { return }
        drawable.addPresentedHandler { [weak self] drawable in
            self?.recordPresentation(time: drawable.presentedTime, target: targetPresentationTime, context: context)
        }
    }

    func recordPresentation(time: TimeInterval, target: TimeInterval? = nil, context: RenderContext) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, self.context == context else { return }
        guard time.isFinite, time > 0 else { unavailablePresentations += 1; return }
        if presentedTimes.count < 10000 { presentedTimes.append(time) }
        if let target, target.isFinite, target > 0, lateness.count < 10000 {
            lateness.append(max(0, (time - target) * 1000))
        }
    }

    // The lock protects publication order and the samples transferred to the writer.
    private func publish(uptime: TimeInterval, partial: Bool) {
        guard let next = context, let windowBegan, let windowDate,
              !frames.isEmpty || !presentedTimes.isEmpty || unavailablePresentations > 0 else { return }
        let elapsed = max(0, uptime - windowBegan)
        let fps = frames.isEmpty ? nil : 1000 / (frames.reduce(0, +) / Double(frames.count))
        var values = lastAttributes.merging(next.attributes) { _, context in context }
        let ordered = presentedTimes.sorted()
        var previous = previousPresentedTime
        var presentationIntervals: [Double] = []
        for time in ordered {
            if let previous, time > previous { presentationIntervals.append((time - previous) * 1000) }
            previous = max(previous ?? time, time)
        }
        previousPresentedTime = previous
        let displayIntervals = presentationIntervals
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        values.merge([
            "recorded_at": .string(formatter.string(from: windowDate.addingTimeInterval(elapsed))),
            "elapsed_seconds": .double(uptime - began), "window_seconds": .double(elapsed), "frames": .int(frames.count),
            "window.partial": .bool(partial),
            "gpu_samples": .int(gpu.count),
            "frames_over_25_ms": .int(frames.filter { $0 > 25 }.count),
            "sample_limit_reached": .bool(frames.count == 10000 || presentedTimes.count == 10000),
            "thermal_state": .int(ProcessInfo.processInfo.thermalState.rawValue),
            "measurement.source": .string("sdk.frame_recorder"), "measurement.scope": .string("render_callbacks"),
            "session_id": .string(client.sessionID), "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "cpu_frame.scope": .string("frame_preparation_wall_time"), "main_thread.measured": .bool(false),
        ]) { _, measured in measured }
        if let fps {
            values["render_callback_fps"] = .double(fps)
            values["frame_interval_p50_ms"] = .double(percentile(frames, 0.5))
            values["frame_interval_p95_ms"] = .double(percentile(frames, 0.95))
            values["frame_encode_wall_p95_ms"] = .double(percentile(preparation, 0.95))
            values["cpu_frame_p95_ms"] = .double(percentile(preparation, 0.95))
        }
        values["display_presented_frames"] = .int(ordered.count)
        values["display_timestamp_unavailable"] = .int(unavailablePresentations)
        values["display_presentation_intervals"] = .int(presentationIntervals.count)
        let presentedFPS = presentationIntervals.isEmpty ? nil : 1000 / (presentationIntervals.reduce(0, +) / Double(presentationIntervals.count))
        if let presentedFPS {
            values["display_presented_fps"] = .double(presentedFPS)
            values["display_present_interval_p95_ms"] = .double(percentile(presentationIntervals, 0.95))
            values["display_time.source"] = .string("metal.drawable.presented_time")
        }
        if !lateness.isEmpty { values["display_present_lateness_p95_ms"] = .double(percentile(lateness, 0.95)) }
        if !gpu.isEmpty { values["gpu_command_p95_ms"] = .double(percentile(gpu, 0.95)) }
        let window = FrameWindow(started: windowDate, ended: windowDate.addingTimeInterval(elapsed), callbackFPS: fps ?? 0,
            gpuMeanMilliseconds: gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count), attributes: values)
        let frameSamples = frames, preparationSamples = preparation, gpuSamples = gpu, lateSamples = lateness
        frames.removeAll(keepingCapacity: true); preparation.removeAll(keepingCapacity: true); gpu.removeAll(keepingCapacity: true)
        presentedTimes.removeAll(keepingCapacity: true); lateness.removeAll(keepingCapacity: true)
        unavailablePresentations = 0
        self.windowBegan = uptime; self.windowDate = window.ended
        writer.async { [self] in
            client.window(spanName, started: window.started, ended: window.ended, attributes: window.attributes) {
                let labels: [String: LogfireAttribute] = ["render_mode": .string(next.mode), "workload": .string(next.workload), "gpu_time.scope": .string(next.gpuTimeScope.rawValue)]
                for value in frameSamples { client.metrics?.record(.frameInterval, value: value, attributes: labels) }
                for value in preparationSamples { client.metrics?.record(.preparation, value: value, attributes: labels) }
                for value in gpuSamples { client.metrics?.record(.gpuCommands, value: value, attributes: labels) }
                if let fps {
                    client.metrics?.record(.frames, value: Double(frameSamples.count), attributes: labels)
                    client.metrics?.record(.slowFrames, value: Double(frameSamples.filter { $0 > 25 }.count), attributes: labels)
                    client.metrics?.record(.callbackFPS, value: fps, attributes: labels)
                }
                let displayLabels: [String: LogfireAttribute] = ["render_mode": .string(next.mode), "workload": .string(next.workload)]
                for value in displayIntervals { client.metrics?.record(.presentedInterval, value: value, attributes: displayLabels) }
                for value in lateSamples { client.metrics?.record(.presentationLateness, value: value, attributes: displayLabels) }
                if !ordered.isEmpty { client.metrics?.record(.presentedFrames, value: Double(ordered.count), attributes: displayLabels) }
                if let presentedFPS { client.metrics?.record(.presentedFPS, value: presentedFPS, attributes: displayLabels) }
            }
            onWindow?(window)
        }
    }

    /// Call after the renderer stops submitting frames, outside its completion callback.
    public func finish() { finish(uptime: ProcessInfo.processInfo.systemUptime) }

    func finish(uptime: TimeInterval) {
        lock.lock()
        if !finished { publish(uptime: uptime, partial: true); finished = true }
        lock.unlock()
        drainWriter(); client.flush()
    }

    func flushPending() {
        lock.lock()
        if !finished { publish(uptime: ProcessInfo.processInfo.systemUptime, partial: true) }
        lock.unlock()
        drainWriter()
    }

    private func drainWriter() {
        if DispatchQueue.getSpecific(key: Self.writerKey) == nil { writer.sync {} }
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * quantile)) - 1)]
    }
}

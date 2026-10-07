import AppKit
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    var pipeline: MTLRenderPipelineState?
    var descriptor: MTLRenderPipelineDescriptor?
    var phase = 0
    let began = ProcessInfo.processInfo.systemUptime
    let output =
        ProcessInfo.processInfo.environment["LOGFIRE_SCENARIO_STATUS"].map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("shader-probe-operations.json")
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("shader-probe-\(UUID().uuidString).json")
    var operations: [[String: Any]] = []
    let seed = UInt32.random(in: 1...1_000_000)
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        if phase == 0 && elapsed > 2 {
            compile(view, kind: "unique", seed: seed)
            phase = 1
        }
        if phase == 1 && elapsed > 5 {
            compile(view, kind: "repeat", seed: seed)
            phase = 2
        }
        if phase == 2 && elapsed > 8 {
            compile(view, kind: "unique", seed: seed + 1)
            phase = 3
        }
        if elapsed > 11 {
            do {
                try ScenarioProtocol.publish(
                    phase: operations.count == 3 ? "passed" : "failed",
                    details: ["unique_pipeline_calls": "2", "repeated_pipeline_calls": "1"])
            } catch {
                print("Scenario completion failed: \(error)")
                exit(1)
            }
            NSApplication.shared.terminate(nil)
            return
        }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
            let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        command.label = "ShaderProbe.Frame"
        encoder.label = "ShaderProbe.Triangle"
        if let pipeline {
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
    func compile(_ view: MTKView, kind: String, seed: UInt32) {
        let started = Date().timeIntervalSince1970
        let began = ProcessInfo.processInfo.systemUptime
        do {
            if kind == "unique" {
                let source = """
                    #include <metal_stdlib>
                    using namespace metal;
                    vertex float4 probeVertex_\(seed)(uint id [[vertex_id]]) {
                        float2 p[3] = {float2(-0.7,-0.7),float2(0.7,-0.7),float2(0,0.7)};
                        return float4(p[id],0,1);
                    }
                    fragment float4 probeFragment_\(seed)(float4 p [[position]]) {
                        float x = p.x * 0.00001 + \(Double(seed) / 1000000.0);
                        for (int i = 0; i < 32; ++i) { x = sin(x + p.y * 0.00001); }
                        return float4(abs(x),0.3,0.6,1);
                    }
                    """
                let library = try device.makeLibrary(source: source, options: nil)
                let desc = MTLRenderPipelineDescriptor()
                desc.label = "ShaderProbe.\(kind).\(seed)"
                desc.vertexFunction = library.makeFunction(name: "probeVertex_\(seed)")
                desc.fragmentFunction = library.makeFunction(name: "probeFragment_\(seed)")
                desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor = desc
            }
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor!)
            operations.append([
                "kind": kind, "started_at": started, "ended_at": Date().timeIntervalSince1970,
                "host_wall_ms": (ProcessInfo.processInfo.systemUptime - began) * 1000,
            ])
            try JSONSerialization.data(withJSONObject: operations, options: [.prettyPrinted, .sortedKeys]).write(
                to: output, options: .atomic)
        } catch {
            print("Probe failed: \(error)")
            exit(1)
        }
    }
}

// This example implements the runner handshake without importing the Swift SDK.
enum ScenarioProtocol {
    static func publish(phase: String, details: [String: String] = [:]) throws {
        let env = ProcessInfo.processInfo.environment
        guard let status = env["LOGFIRE_SCENARIO_STATUS"], let id = env["LOGFIRE_SESSION_ID"],
            let scenario = env["LOGFIRE_SCENARIO_ID"], let sessions = env["LOGFIRE_SESSION_DIR"]
        else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        if phase == "ready" {
            var marker: [String: Any] = [:]
            if let file = Bundle.main.url(forResource: "LogfireBuild", withExtension: "json") {
                marker = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
            }
            marker.merge([
                "session_id": id, "pid": pid, "executable": Bundle.main.executablePath ?? CommandLine.arguments[0],
                "started_at": Date().timeIntervalSince1970, "service.name": "metal-shader-probe",
            ]) { _, current in current }
            try JSONSerialization.data(withJSONObject: marker).write(
                to: URL(fileURLWithPath: sessions).appendingPathComponent("\(pid).json"), options: .atomic)
        }
        let signal: [String: Any] = [
            "schema_version": 1, "scenario_id": scenario, "session_id": id,
            "pid": pid, "ready": true, "phase": phase, "recorded_at": Date().timeIntervalSince1970, "details": details,
        ]
        try JSONSerialization.data(withJSONObject: signal).write(to: URL(fileURLWithPath: status), options: .atomic)
    }
}
try ScenarioProtocol.publish(phase: "ready")

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let renderer = Renderer()
let view = MTKView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), device: renderer.device)
view.delegate = renderer
view.preferredFramesPerSecond = 60
view.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)
let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Metal shader evidence probe"
window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()

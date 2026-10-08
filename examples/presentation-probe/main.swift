import AppKit
import LogfireSwift
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    let client: Logfire
    let recorder: FrameRecorder
    let queue: MTLCommandQueue
    let context: RenderContext
    let presentEvery: Int
    let offscreen: MTLTexture
    let scenario: DevelopmentScenario?
    var callbacks = 0
    var previous = CACurrentMediaTime()

    init(device: MTLDevice, client: Logfire, presentEvery: Int) {
        self.client = client
        self.presentEvery = presentEvery
        context = RenderContext(mode: presentEvery == 1 ? "presentation-normal" : "presentation-half-rate", width: 320, height: 240,
            metadata: ["probe.present_every": .int(presentEvery)])
        queue = device.makeCommandQueue()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320, height: 240, mipmapped: false)
        descriptor.usage = .renderTarget
        offscreen = device.makeTexture(descriptor: descriptor)!
        let scenario = DevelopmentScenario(client: client)
        self.scenario = scenario
        recorder = FrameRecorder(client: client, stateDomain: "dev.example.presentation") { window in
            if let data = try? window.encodedReport(), let text = String(data: data, encoding: .utf8) { print(text, terminator: "") }
            do { try scenario?.record(window) }
            catch { print("Presentation probe could not retain scenario evidence.") }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(), interval = (now - previous) * 1000
        previous = now
        callbacks += 1
        let shouldPresent = callbacks % presentEvery == 0
        let drawable = shouldPresent ? view.currentDrawable : nil
        if shouldPresent && drawable == nil { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable?.texture ?? offscreen
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: Double(callbacks % 60) / 60, blue: 0.7, alpha: 1)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        let preparation = (CACurrentMediaTime() - now) * 1000
        let visible = view.window?.occlusionState.contains(.visible) ?? false
        if let drawable { recorder.observe(drawable, context: context) }
        command.addCompletedHandler { [recorder, context] command in
            recorder.record(commandBuffer: command, frameMilliseconds: interval, preparationMilliseconds: preparation, context: context,
                attributes: ["probe.window_visible": .bool(visible)])
        }
        if let drawable { command.present(drawable) }
        command.commit()
    }

    func finish() {
        // A queue fence drains submitted GPU work before the final report.
        let fence = queue.makeCommandBuffer()!
        fence.commit(); fence.waitUntilCompleted()
        recorder.finish()
        do { try scenario?.finish(passed: true, details: ["probe.present_every": String(presentEvery), "purpose": "controlled-presentation-policy"]) }
        catch { print("Presentation scenario completion failed."); exit(2) }
        let status = client.delivery
        print("delivery spans=\(status.exportedSpans) failed=\(status.failedSpans) metrics=\(client.metrics?.delivery.exportedMetrics ?? 0)")
    }
}

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is unavailable") }
let client = try Logfire.development(serviceName: "metal-presentation-probe", apple: .init(metricKit: false))
print("session=\(client.sessionID)")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), device: device)
view.clearColor = MTLClearColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1)
view.preferredFramesPerSecond = 60
let presentEvery = ProcessInfo.processInfo.environment["PROBE_PRESENT_EVERY"] ?? "1"
guard ["1", "2"].contains(presentEvery) else { fatalError("Use PROBE_PRESENT_EVERY=1 or 2") }
let renderer = Renderer(device: device, client: client, presentEvery: Int(presentEvery)!)
view.delegate = renderer
let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Logfire presentation verification: every \(presentEvery) callback(s)"
window.contentView = view
window.level = .floating
window.center(); window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
    view.isPaused = true
    // Allow the last drawable's presentation handler to run after GPU completion.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        DispatchQueue.global(qos: .utility).async {
            renderer.finish()
            DispatchQueue.main.async { app.terminate(nil) }
        }
    }
}
app.run()

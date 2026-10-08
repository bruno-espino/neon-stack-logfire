import AppKit
import LogfireSwift
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    let client: Logfire
    let recorder: FrameRecorder
    let queue: MTLCommandQueue
    let context = RenderContext(mode: "presentation-probe", width: 320, height: 240)
    var previous = CACurrentMediaTime()

    init(device: MTLDevice, client: Logfire) {
        self.client = client
        queue = device.makeCommandQueue()!
        recorder = FrameRecorder(client: client, stateDomain: "dev.example.presentation") { window in
            if let data = try? window.encodedReport(), let text = String(data: data, encoding: .utf8) { print(text, terminator: "") }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(), interval = (now - previous) * 1000
        previous = now
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        let preparation = (CACurrentMediaTime() - now) * 1000
        recorder.observe(drawable, context: context)
        command.addCompletedHandler { [recorder, context] command in
            recorder.record(commandBuffer: command, frameMilliseconds: interval, preparationMilliseconds: preparation, context: context)
        }
        command.present(drawable); command.commit()
    }

    func finish() {
        // A queue fence drains submitted GPU work before the final report.
        let fence = queue.makeCommandBuffer()!
        fence.commit(); fence.waitUntilCompleted()
        recorder.finish()
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
let renderer = Renderer(device: device, client: client)
view.delegate = renderer
let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Logfire presentation verification"
window.contentView = view
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

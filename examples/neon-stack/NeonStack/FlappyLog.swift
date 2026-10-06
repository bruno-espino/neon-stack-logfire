import MetalKit
import SwiftUI
import simd
import os

enum FireDetail: Int, CaseIterable, Identifiable {
    case low = 65_536, medium = 262_144, high = 1_048_576, extreme = 4_194_304
    var id: Int { rawValue }
    var title: String { ["Low", "Medium", "High", "Extreme"][Self.allCases.firstIndex(of: self)!] }
    static func from(environment value: String?) -> FireDetail {
        value.flatMap(Int.init).flatMap(FireDetail.init(rawValue:)) ?? .medium
    }
}

final class FlappyState: ObservableObject {
    @Published var engine: FlappyEngine
    @Published var paused = false
    @Published var detail: FireDetail
    @Published var best = 0
    @Published var stats = FlappyStats()
    @Published var soundEnabled = true
    let benchmark = ProcessInfo.processInfo.environment["NEON_BENCHMARK"] == "1"
    private var seed: UInt64
    private lazy var audio = GameAudio()
    private let signposter = OSSignposter(subsystem: "dev.example.NeonStack", category: .pointsOfInterest)

    init() {
        let environment = ProcessInfo.processInfo.environment
        seed = environment["NEON_SEED"].flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64.max)
        engine = FlappyEngine(seed: seed)
        detail = FireDetail.from(environment: environment["FLAPPY_PARTICLES"])
    }
    func flap() {
        guard !benchmark, !paused else { return }
        if engine.gameOver { restart(); return }
        engine.flap(); signposter.emitEvent("Flap"); play(.rotate)
    }
    func togglePause() { if engine.started && !engine.gameOver && !benchmark { paused.toggle() } }
    func restart() {
        seed = benchmark ? seed &+ 1 : UInt64.random(in: 1...UInt64.max)
        engine = FlappyEngine(seed: seed); paused = false
    }
    func toggleSound() { soundEnabled.toggle(); if !soundEnabled { audio.stop() } }
    func update(_ seconds: Double) {
        guard !paused else { return }
        let state = signposter.beginInterval("FlappyUpdate")
        let wasOver = engine.gameOver
        let passed = engine.advance(seconds, autoplay: benchmark)
        signposter.endInterval("FlappyUpdate", state)
        if passed > 0 { play(engine.score % 10 == 0 ? .four : .hold) }
        if engine.gameOver && !wasOver {
            best = max(best, engine.score)
            signposter.emitEvent("Crash"); play(.gameOver)
            GameTelemetry.client.event("game.crash", attributes: [
                "game": .string("flappy-log"), "score": .int(engine.score), "flaps": .int(engine.flaps),
                "flight_seconds": .double(engine.time), "particles": .int(detail.rawValue),
            ])
            if benchmark { restart() }
        }
    }
    private func play(_ cue: SoundCue) { if soundEnabled && !benchmark { audio.play(cue) } }
}

struct FlappyStats: Equatable {
    var fps = 0.0, simulation = 0.0, scene = 0.0, glow = 0.0
    var gpu: Double { simulation + scene + glow }
}

struct FlappyScreen: View {
    @ObservedObject var game: FlappyState
    let flame = Color(red: 1.0, green: 0.55, blue: 0.18)
    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("FLAPPY LOG").font(.system(size: 30, weight: .black, design: .monospaced)).tracking(3)
                    Text("FLY THROUGH THE FIRE").font(.system(size: 10, design: .monospaced)).tracking(3).foregroundStyle(flame)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Picker("Fire detail", selection: $game.detail) {
                        ForEach(FireDetail.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 320).disabled(game.benchmark)
                    Text("\(game.detail.rawValue.formatted()) FIRE PARTICLES")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(flame)
                }
            }
            ZStack {
                FlappySurface(game: game).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack {
                    Text("\(game.engine.score)").font(.system(size: 54, weight: .black, design: .monospaced))
                        .shadow(color: flame.opacity(0.8), radius: 12).padding(.top, 16)
                    Spacer()
                }.allowsHitTesting(false)
                if !game.engine.started && !game.benchmark {
                    message("PRESS SPACE OR CLICK TO FLAP", detail: "Fly the log through the gaps in the fire")
                } else if game.paused {
                    message("PAUSED", detail: "Press P to keep flying")
                } else if game.engine.gameOver && !game.benchmark {
                    VStack(spacing: 14) {
                        Text("THE LOG CAUGHT FIRE").font(.system(size: 20, weight: .black, design: .monospaced))
                        Text("Score \(game.engine.score) · Best \(game.best)").foregroundStyle(flame)
                        Button("Fly again") { game.restart() }.buttonStyle(.borderedProminent).tint(flame).foregroundStyle(.black)
                    }.padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }.aspectRatio(16 / 10, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(flame.opacity(0.3), lineWidth: 1))
                .shadow(color: flame.opacity(0.25), radius: 25)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(game.benchmark ? "FIXED-SEED REPLAY" : "SPACE / CLICK  FLAP   P  PAUSE   R  RESTART")
                Spacer()
                Button { game.toggleSound() } label: {
                    Image(systemName: game.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }.buttonStyle(.plain).disabled(game.benchmark)
                    .accessibilityLabel(game.soundEnabled ? "Mute sound" : "Enable sound")
                let stats = game.stats
                Text(String(format: "%.0f FPS · GPU %.2f ms (fire %.2f · scene %.2f · glow %.2f)",
                            stats.fps, stats.gpu, stats.simulation, stats.scene, stats.glow))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
        }.padding(28).foregroundStyle(.white)
            .background(LinearGradient(colors: [Color(red: 0.1, green: 0.04, blue: 0.03), .black],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 18, weight: .black, design: .monospaced))
            Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
        }.padding(22).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14)).allowsHitTesting(false)
    }
}

#if os(macOS)
final class FlappyInputView: MTKView {
    var game: FlappyState?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); game?.flap() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 126: game?.flap()
        case 35: game?.togglePause()
        case 15: game?.restart()
        default: super.keyDown(with: event)
        }
    }
}
#else
final class FlappyInputView: MTKView {
    var game: FlappyState?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { game?.flap() }
}
#endif

struct FlappySurface: SurfaceRepresentable {
    let game: FlappyState
    func makeCoordinator() -> FlappyViewRenderer { FlappyViewRenderer(game: game) }
    private func makeView(context: Context) -> MTKView {
        let view = FlappyInputView(frame: .zero, device: context.coordinator.renderer?.device)
        view.game = game; view.delegate = context.coordinator; view.preferredFramesPerSecond = 120
        #if os(macOS)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        #endif
        return view
    }
    #if os(macOS)
    func makeNSView(context: Context) -> MTKView { makeView(context: context) }
    func updateNSView(_ view: MTKView, context: Context) {}
    #else
    func makeUIView(context: Context) -> MTKView { makeView(context: context) }
    func updateUIView(_ view: MTKView, context: Context) {}
    #endif
}

final class FlappyViewRenderer: NSObject, MTKViewDelegate {
    let renderer = FlappyRenderer()
    private let game: FlappyState
    private let performance = PerformanceRecorder()
    private var lastTime = CACurrentMediaTime()
    private var lastStats = CACurrentMediaTime()
    private let smoothed = OSAllocatedUnfairLock(initialState: FlappyStats())
    init(game: FlappyState) { self.game = game }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(); let delta = now - lastTime; lastTime = now
        game.update(delta)
        guard let renderer, let drawable = view.currentDrawable else { return }
        let size = view.drawableSize
        let detail = game.detail.rawValue, score = game.engine.score
        renderer.render(engine: game.engine, particles: detail, seconds: game.paused ? 0 : delta,
                        target: drawable.texture, present: drawable) { [weak self] cpu, stages in
            guard let self else { return }
            self.performance.record(gpuStages: stages, frameMilliseconds: delta * 1000, cpuMilliseconds: cpu,
                                    score: score, width: Int(size.width), height: Int(size.height), particles: detail)
            self.smoothed.withLock { stats in
                let blend = 0.1
                stats.fps += ((delta > 0 ? 1 / delta : 0) - stats.fps) * blend
                stats.simulation += ((stages["fire"] ?? 0) - stats.simulation) * blend
                stats.scene += ((stages["scene"] ?? 0) - stats.scene) * blend
                stats.glow += ((stages["glow"] ?? 0) - stats.glow) * blend
            }
        }
        if now - lastStats > 0.25 { lastStats = now; game.stats = smoothed.withLock { $0 } }
    }
}

struct FlappyUniforms {
    var viewProjection: simd_float4x4
    var camera: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var log: SIMD4<Float>
    var particle: SIMD4<Float>
}

/// Renders one Flappy Log frame into any BGRA texture. Each frame uses three command buffers
/// (fire simulation, 3D scene, glow and final image) so each stage reports its own GPU time.
final class FlappyRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let simulation: MTLComputePipelineState
    private let sky, ground, log, fire, bright, copy, blur, composite: MTLRenderPipelineState
    private let skyDepth, solidDepth, fireDepth: MTLDepthStencilState
    private var particles: MTLBuffer?
    private var particleCount = 0
    private var targets: (size: SIMD2<Int>, scene: MTLTexture, depth: MTLTexture, half: [MTLTexture], quarter: [MTLTexture])?
    private var started = CACurrentMediaTime()
    private var cameraX: Float = 0
    private let signposter = OSSignposter(subsystem: "dev.example.NeonStack", category: .pointsOfInterest)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device; self.queue = queue
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat = .rgba16Float,
                      depth: Bool = false, additive: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            if depth { descriptor.depthAttachmentPixelFormat = .depth32Float }
            if additive, let blend = descriptor.colorAttachments[0] {
                blend.isBlendingEnabled = true
                blend.sourceRGBBlendFactor = .one; blend.destinationRGBBlendFactor = .one
                blend.sourceAlphaBlendFactor = .one; blend.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        func depthState(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare; descriptor.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: descriptor)
        }
        do {
            guard let kernel = library.makeFunction(name: "flappyParticles") else { return nil }
            simulation = try device.makeComputePipelineState(function: kernel)
            sky = try pipeline("flappyFullscreen", "flappySky", depth: true)
            ground = try pipeline("flappyGroundVertex", "flappyGround", depth: true)
            log = try pipeline("flappyLogVertex", "flappyLog", depth: true)
            fire = try pipeline("flappyParticleVertex", "flappyParticleFragment", depth: true, additive: true)
            bright = try pipeline("flappyFullscreen", "flappyBrightPass")
            copy = try pipeline("flappyFullscreen", "flappyCopy")
            blur = try pipeline("flappyFullscreen", "flappyBlur")
            composite = try pipeline("flappyFullscreen", "flappyComposite", format: .bgra8Unorm)
        } catch { print("Flappy Log Metal pipeline error: \(error.localizedDescription)"); return nil }
        guard let skyDepth = depthState(.always, write: false), let solidDepth = depthState(.less, write: true),
              let fireDepth = depthState(.less, write: false) else { return nil }
        self.skyDepth = skyDepth; self.solidDepth = solidDepth; self.fireDepth = fireDepth
    }

    /// Encodes and commits one frame. `completed` receives CPU encode time and per-stage GPU milliseconds.
    func render(engine: FlappyEngine, particles count: Int, seconds: Double, target: MTLTexture,
                present drawable: MTLDrawable? = nil, completed: @escaping (Double, [String: Double]) -> Void) {
        let begin = CACurrentMediaTime()
        let state = signposter.beginInterval("EncodeFrame")
        defer { signposter.endInterval("EncodeFrame", state) }
        guard let particles = particleBuffer(count), let targets = textures(width: target.width, height: target.height),
              let simulationBuffer = queue.makeCommandBuffer(), let sceneBuffer = queue.makeCommandBuffer(),
              let glowBuffer = queue.makeCommandBuffer() else { return }
        simulationBuffer.label = "FlappyLog.Fire"; sceneBuffer.label = "FlappyLog.Scene"; glowBuffer.label = "FlappyLog.Glow"

        var uniforms = makeUniforms(engine: engine, count: count, seconds: seconds,
                                    aspect: Float(target.width) / Float(target.height))
        var columns = Array(repeating: SIMD4<Float>(0, 0, 0, 0), count: 8)
        for column in engine.columns {
            columns[column.index % 8] = SIMD4(Float(column.x), Float(column.gapCenter), Float(column.gapHalf), 1)
        }
        let uniformSize = MemoryLayout<FlappyUniforms>.stride, columnSize = MemoryLayout<SIMD4<Float>>.stride * 8

        if let compute = simulationBuffer.makeComputeCommandEncoder() {
            compute.label = "FireParticles"
            compute.setComputePipelineState(simulation)
            compute.setBuffer(particles, offset: 0, index: 0)
            compute.setBytes(&uniforms, length: uniformSize, index: 1)
            compute.setBytes(&columns, length: columnSize, index: 2)
            compute.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: simulation.threadExecutionWidth * 4, height: 1, depth: 1))
            compute.endEncoding()
        }

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = targets.scene
        scenePass.colorAttachments[0].loadAction = .clear; scenePass.colorAttachments[0].storeAction = .store
        scenePass.depthAttachment.texture = targets.depth
        scenePass.depthAttachment.loadAction = .clear; scenePass.depthAttachment.clearDepth = 1
        scenePass.depthAttachment.storeAction = .dontCare
        if let encoder = sceneBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.label = "SkyGroundLogFire"
            encoder.setVertexBytes(&uniforms, length: uniformSize, index: 0)
            encoder.setFragmentBytes(&uniforms, length: uniformSize, index: 0)
            encoder.setFragmentBytes(&columns, length: columnSize, index: 1)
            encoder.setDepthStencilState(skyDepth); encoder.setRenderPipelineState(sky)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.setDepthStencilState(solidDepth); encoder.setRenderPipelineState(ground)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.setRenderPipelineState(log)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 32 * 12)
            encoder.setDepthStencilState(fireDepth); encoder.setRenderPipelineState(fire)
            encoder.setVertexBuffer(particles, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: uniformSize, index: 1)
            encoder.setVertexBytes(&columns, length: columnSize, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            encoder.endEncoding()
        }

        func pass(_ pipeline: MTLRenderPipelineState, into output: MTLTexture, from inputs: [MTLTexture],
                  direction: SIMD2<Float>? = nil, label: String) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = output
            descriptor.colorAttachments[0].loadAction = .dontCare; descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = glowBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.label = label
            encoder.setRenderPipelineState(pipeline)
            for (index, input) in inputs.enumerated() { encoder.setFragmentTexture(input, index: index) }
            if var direction { encoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.size, index: 0) }
            else { encoder.setFragmentBytes(&uniforms, length: uniformSize, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        let half = targets.half, quarter = targets.quarter
        let halfStep = SIMD2<Float>(1 / Float(half[0].width), 1 / Float(half[0].height))
        let quarterStep = SIMD2<Float>(1 / Float(quarter[0].width), 1 / Float(quarter[0].height))
        pass(bright, into: half[0], from: [targets.scene], label: "BrightPass")
        pass(blur, into: half[1], from: [half[0]], direction: SIMD2(halfStep.x, 0), label: "GlowBlurX")
        pass(blur, into: half[0], from: [half[1]], direction: SIMD2(0, halfStep.y), label: "GlowBlurY")
        pass(copy, into: quarter[0], from: [half[0]], label: "WideGlowDownsample")
        pass(blur, into: quarter[1], from: [quarter[0]], direction: SIMD2(quarterStep.x, 0), label: "WideGlowBlurX")
        pass(blur, into: quarter[0], from: [quarter[1]], direction: SIMD2(0, quarterStep.y), label: "WideGlowBlurY")
        pass(composite, into: target, from: [targets.scene, half[0], quarter[0]], label: "ToneMapAndHeatHaze")

        let cpu = (CACurrentMediaTime() - begin) * 1000
        glowBuffer.addCompletedHandler { [simulationBuffer, sceneBuffer] glow in
            func milliseconds(_ buffer: MTLCommandBuffer) -> Double? {
                buffer.gpuStartTime > 0 && buffer.gpuEndTime >= buffer.gpuStartTime ? (buffer.gpuEndTime - buffer.gpuStartTime) * 1000 : nil
            }
            var stages: [String: Double] = [:]
            stages["fire"] = milliseconds(simulationBuffer)
            stages["scene"] = milliseconds(sceneBuffer)
            stages["glow"] = milliseconds(glow)
            completed(cpu, stages)
        }
        if let drawable { glowBuffer.present(drawable) }
        simulationBuffer.commit(); sceneBuffer.commit(); glowBuffer.commit()
    }

    private func makeUniforms(engine: FlappyEngine, count: Int, seconds: Double, aspect: Float) -> FlappyUniforms {
        cameraX += (Float(engine.x) - cameraX) * min(1, Float(seconds) * 8)
        let eye = SIMD3<Float>(cameraX - 2.5, 6, 11.5), focus = SIMD3<Float>(cameraX + 3, 5, 0)
        let forward = simd_normalize(focus - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let view = simd_float4x4(columns: (SIMD4(right.x, up.x, -forward.x, 0), SIMD4(right.y, up.y, -forward.y, 0),
                                           SIMD4(right.z, up.z, -forward.z, 0),
                                           SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)))
        let near: Float = 0.1, far: Float = 200, scaleY = 1 / tan(Float.pi * 50 / 360)
        let projection = simd_float4x4(columns: (SIMD4(scaleY / aspect, 0, 0, 0), SIMD4(0, scaleY, 0, 0),
                                                 SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, far * near / (near - far), 0)))
        // Keep total fire brightness similar at every detail level: more particles are smaller and dimmer.
        let ratio = Float(FireDetail.medium.rawValue) / Float(count)
        let size = pow(ratio, 1 / 6)
        return FlappyUniforms(viewProjection: projection * view,
                              camera: SIMD4(eye, Float(CACurrentMediaTime() - started)),
                              right: SIMD4(right, Float(min(seconds, 1.0 / 20))), up: SIMD4(up, Float(count)),
                              log: SIMD4(Float(engine.x), Float(engine.y), Float(engine.tilt), engine.gameOver ? 1 : 0),
                              particle: SIMD4(0.03 * ratio / (size * size), size, 0, 0))
    }

    private func particleBuffer(_ count: Int) -> MTLBuffer? {
        if let particles, particleCount == count { return particles }
        guard let buffer = device.makeBuffer(length: count * 32, options: .storageModePrivate),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return nil }
        buffer.label = "FireParticles"
        blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0); blit.endEncoding(); command.commit()
        particles = buffer; particleCount = count
        return buffer
    }

    private func textures(width: Int, height: Int) -> (size: SIMD2<Int>, scene: MTLTexture, depth: MTLTexture,
                                                       half: [MTLTexture], quarter: [MTLTexture])? {
        if let targets, targets.size == SIMD2(width, height) { return targets }
        func texture(_ width: Int, _ height: Int, _ format: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width),
                                                                      height: max(1, height), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        guard let scene = texture(width, height), let depth = texture(width, height, .depth32Float),
              let halfA = texture(width / 2, height / 2), let halfB = texture(width / 2, height / 2),
              let quarterA = texture(width / 4, height / 4), let quarterB = texture(width / 4, height / 4) else { return nil }
        targets = (SIMD2(width, height), scene, depth, [halfA, halfB], [quarterA, quarterB])
        return targets
    }
}

/// Headless Flappy Log replay for CI-style GPU comparisons. It renders the autopilot into a 1280 by 720 texture.
enum FlappyOffscreenReplay {
    static func run() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let renderer = FlappyRenderer() else { throw ReplayError.unavailable }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1280, height: 720, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { throw ReplayError.unavailable }
        var seed = environment["NEON_SEED"].flatMap(UInt64.init) ?? 777
        var engine = FlappyEngine(seed: seed)
        let detail = FireDetail.from(environment: environment["FLAPPY_PARTICLES"]).rawValue
        let duration = environment["NEON_BENCHMARK_SECONDS"].flatMap(Double.init) ?? 20
        let recorder = PerformanceRecorder()
        let started = CACurrentMediaTime()
        var previous = started, frames = 0, crashes = 0
        while CACurrentMediaTime() - started < duration {
            autoreleasepool {
                let now = CACurrentMediaTime(), delta = now - previous
                previous = now
                engine.advance(delta, autoplay: true)
                if engine.gameOver { crashes += 1; seed &+= 1; engine = FlappyEngine(seed: seed) }
                let done = DispatchSemaphore(value: 0)
                let score = engine.score
                renderer.render(engine: engine, particles: detail, seconds: delta, target: texture) { cpu, stages in
                    recorder.record(gpuStages: stages, frameMilliseconds: delta * 1000, cpuMilliseconds: cpu,
                                    score: score, width: 1280, height: 720, workload: "offscreen", particles: detail)
                    done.signal()
                }
                done.wait()
                frames += 1
                Thread.sleep(forTimeInterval: max(0, 1.0 / 60.0 - (CACurrentMediaTime() - now)))
            }
        }
        recorder.finish()
        if let output = environment["NEON_PERF_REPORT"] {
            try OffscreenReplay.savePreview(texture, at: URL(fileURLWithPath: output).deletingLastPathComponent()
                .appendingPathComponent("flappy-log.png"))
        }
        print("Flappy Log offscreen replay completed. Frames: \(frames), score: \(engine.score), crashes: \(crashes)")
    }
}

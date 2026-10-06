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

/// What the screen shows around the 3D view. The screen refreshes only when this changes.
struct RollHUD: Equatable {
    var score: Int, started: Bool, gameOver: Bool, water: Bool
    init(_ engine: LogRollEngine) {
        score = engine.score; started = engine.started; gameOver = engine.gameOver; water = engine.water
    }
}

/// Feeds the corner map, which redraws more often than the rest of the screen.
final class MazeFeed: ObservableObject {
    @Published var engine: LogRollEngine
    init(_ engine: LogRollEngine) { self.engine = engine }
}

final class LogRollState: ObservableObject {
    /// The rules change 120 times a second, but the 3D view reads them directly. Publishing every change
    /// would make SwiftUI lay out the whole screen every frame, so the screen refreshes only when the HUD
    /// changes and the corner map at most 30 times a second.
    var engine: LogRollEngine { didSet { refresh() } }
    let map: MazeFeed
    private var shown: RollHUD
    private var mapShown = 0.0
    @Published var paused = false
    @Published var detail: FireDetail
    @Published var best = 0
    @Published var stats = RollStats()
    @Published var soundEnabled = true
    let benchmark = ProcessInfo.processInfo.environment["NEON_BENCHMARK"] == "1"
    private var seed: UInt64
    private lazy var audio = GameAudio()
    private var scenario: LogRollScenario? = ProcessInfo.processInfo.environment["LOGFIRE_SCENARIO_ID"] == LogRollScenario.id ? LogRollScenario() : nil
    private var scenarioReported = false
    private let signposter = OSSignposter(subsystem: "dev.example.NeonStack", category: .pointsOfInterest)

    init() {
        let environment = ProcessInfo.processInfo.environment
        seed = environment["NEON_SEED"].flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64.max)
        engine = LogRollEngine(seed: seed)
        map = MazeFeed(engine); shown = RollHUD(engine)
        detail = FireDetail.from(environment: environment["LOG_ROLL_PARTICLES"])
    }
    private func refresh() {
        let hud = RollHUD(engine), now = CACurrentMediaTime()
        let changed = hud != shown
        if changed { shown = hud; objectWillChange.send() }
        if changed || now - mapShown >= 1.0 / 30 { mapShown = now; map.engine = engine }
    }
    func press(_ direction: Direction) {
        guard !benchmark, !paused else { return }
        if engine.gameOver { restart(); return }
        engine.press(direction)
    }
    func release(_ direction: Direction) { engine.release(direction) }
    func turn(_ direction: Int) {
        guard !benchmark, !paused, !engine.gameOver else { return }
        engine.turn(direction)
    }
    func togglePause() { if engine.started && !engine.gameOver && !benchmark { paused.toggle() } }
    func restart() {
        seed = benchmark ? seed &+ 1 : UInt64.random(in: 1...UInt64.max)
        engine = LogRollEngine(seed: seed); paused = false
    }
    func toggleSound() { soundEnabled.toggle(); if !soundEnabled { audio.stop() } }
    func update(_ seconds: Double) {
        guard !paused else { return }
        let state = signposter.beginInterval("LogRollUpdate")
        let wasOver = engine.gameOver
        let moves = engine.moves, turns = engine.turns
        let cleared: Int
        if scenario != nil { cleared = scenario!.advance(seconds, engine: &engine) }
        else { cleared = engine.advance(seconds, autoplay: benchmark) }
        signposter.endInterval("LogRollUpdate", state)
        if engine.moves > moves { signposter.emitEvent("Roll") }
        if engine.turns > turns { signposter.emitEvent("TurnMaze") }
        if cleared > 0 {
            signposter.emitEvent("MazeCleared"); play(.four)
            GameTelemetry.client.event("game.maze.cleared", attributes: ["game": .string("log-roll"),
                "score": .int(engine.score), "moves": .int(engine.moves), "turns": .int(engine.turns),
                "simulation_seconds": .double(engine.seconds), "maze_size": .int(engine.maze.size)])
        }
        if engine.gameOver && !wasOver {
            best = max(best, engine.score)
            signposter.emitEvent("Crash"); play(.gameOver)
            GameTelemetry.client.event("game.crash", attributes: [
                "game": .string("log-roll"), "score": .int(engine.score), "moves": .int(engine.moves),
                "maze_size": .int(engine.maze.size), "seconds": .double(engine.seconds), "particles": .int(detail.rawValue),
                "turns": .int(engine.turns), "water": .bool(engine.water), "heat": .double(engine.heat),
            ])
            if benchmark && scenario == nil { restart() }
        }
        if !scenarioReported, let scenario, let passed = scenario.outcome, GameTelemetry.scenario?.isReady == true {
            scenarioReported = true
            let details = ["mazes_cleared": String(engine.score),
                    "game_over": String(engine.gameOver), "moves": String(engine.moves), "turns": String(engine.turns),
                    "simulation_seconds": String(engine.seconds), "failure": scenario.failure]
            DispatchQueue.global(qos: .utility).async {
                do { try GameTelemetry.scenario?.finish(passed: passed, details: details) }
                catch { print("Scenario completion report failed: \(error)") }
            }
        }
    }
    private func play(_ cue: SoundCue) { if soundEnabled && !benchmark { audio.play(cue) } }
}

struct RollStats: Equatable {
    var fps = 0.0, simulation = 0.0, scene = 0.0, glow = 0.0
    var gpu: Double { simulation + scene + glow }
}

struct LogRollScreen: View {
    @ObservedObject var game: LogRollState
    let flame = Color(red: 1.0, green: 0.55, blue: 0.18)
    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOG ROLL").font(.system(size: 30, weight: .black, design: .monospaced)).tracking(3)
                    Text(game.engine.water ? "THE LOG IS ON FIRE · AVOID THE WATER" : "ESCAPE THE BURNING MAZE").font(.system(size: 10, design: .monospaced)).tracking(3).foregroundStyle(flame)
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
                LogRollSurface(game: game).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack {
                    Text("MAZE \(game.engine.score + 1)").font(.system(size: 28, weight: .black, design: .monospaced))
                        .shadow(color: flame.opacity(0.8), radius: 12).padding(.top, 14)
                    HeatMeter(engine: game.engine, flame: flame)
                    Spacer()
                    HStack {
                        MazeMap(feed: game.map, flame: flame)
                        Spacer()
                    }.padding(14)
                }.allowsHitTesting(false)
                if !game.engine.started && !game.benchmark {
                    message("ARROWS ROLL THE LOG · Q AND E TURN THE MAZE",
                            detail: """
                            Reach the blue pool to escape. Each pool takes you to a bigger maze.
                            Bronze gates open only when their arrow points up the screen. Turn the maze to open them.
                            Grates in the floor glow red, then burst into flame. Wait beside them until they go out.
                            Every maze heats the log a little more...
                            """)
                } else if game.paused {
                    message("PAUSED", detail: "Press P to keep rolling")
                } else if game.engine.gameOver && !game.benchmark {
                    VStack(spacing: 14) {
                        Text(game.engine.water ? "THE WATER PUT YOUR FIRE OUT" : "THE LOG CAUGHT FIRE").font(.system(size: 20, weight: .black, design: .monospaced))
                        Text("Mazes escaped \(game.engine.score) · Best \(game.best)").foregroundStyle(flame)
                        Button("Try again") { game.restart() }.buttonStyle(.borderedProminent).tint(flame).foregroundStyle(.black)
                    }.padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }.aspectRatio(16 / 10, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(flame.opacity(0.3), lineWidth: 1))
                .shadow(color: flame.opacity(0.25), radius: 25)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(game.benchmark ? "FIXED-SEED REPLAY" : "← ↑ → ↓  ROLL   Q E  TURN MAZE   P  PAUSE   R  RESTART")
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
                .multilineTextAlignment(.center)
        }.padding(22).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14)).allowsHitTesting(false)
    }
}

/// How hot the log is. It fills up one notch per maze until the log is ablaze.
struct HeatMeter: View {
    let engine: LogRollEngine
    let flame: Color
    var body: some View {
        let names = ["FRESH LOG", "WARM LOG", "SMOKING LOG", "SMOULDERING LOG", "LOGFIRE"]
        let notches = min(engine.score, LogRollEngine.ablazeAt)
        HStack(spacing: 6) {
            ForEach(0..<LogRollEngine.ablazeAt, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2).fill(index < notches ? flame : .white.opacity(0.15)).frame(width: 18, height: 6)
            }
            Text(engine.water ? "LOGFIRE · REACH THE FIRE PIT" : names[notches])
                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(flame)
        }.padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.45), in: Capsule())
    }
}

/// The whole maze from above: walls, gates, fire grates, the exit, and the log.
/// It turns with the camera, so up on the map is always up on the screen.
struct MazeMap: View {
    @ObservedObject var feed: MazeFeed
    let flame: Color
    var body: some View {
        let engine = feed.engine, maze = engine.maze, cell = CGFloat(min(7, 150 / maze.size))
        Canvas { context, _ in
            for z in 0..<maze.size {
                for x in 0..<maze.size {
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(z) * cell, width: cell, height: cell)
                    if maze.isWall(x, z) { context.fill(Path(rect), with: .color(.white.opacity(0.22))) }
                }
            }
            for gate in maze.gates {
                let rect = CGRect(x: CGFloat(gate.x) * cell, y: CGFloat(gate.z) * cell, width: cell, height: cell)
                let open = !maze.blocked(gate.x, gate.z, facing: engine.facing)
                context.fill(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(open ? .cyan.opacity(0.35) : .orange))
            }
            let hot: Color = engine.water ? .cyan : flame, warm: Color = engine.water ? .blue : .red
            for jet in maze.jets {
                let rect = CGRect(x: CGFloat(jet.x) * cell + 1, y: CGFloat(jet.z) * cell + 1, width: cell - 2, height: cell - 2)
                let color: Color = jet.burning(engine.clock) ? hot : jet.warming(engine.clock) ? warm : warm.opacity(0.35)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
            let exit = CGRect(x: CGFloat(maze.exit.x) * cell, y: CGFloat(maze.exit.z) * cell, width: cell, height: cell)
            context.fill(Path(ellipseIn: exit), with: .color(engine.water ? flame : .cyan))
            let log = engine.position
            context.fill(Path(ellipseIn: CGRect(x: log.x * cell + 0.5, y: log.z * cell + 0.5, width: cell - 1, height: cell - 1)),
                         with: .color(.white))
        }.frame(width: CGFloat(maze.size) * cell, height: CGFloat(maze.size) * cell)
            .rotationEffect(.degrees(-90 * engine.turnAngle))
            .padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

#if os(macOS)
final class LogRollInputView: MTKView {
    var game: LogRollState?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    private func direction(_ event: NSEvent) -> Direction? {
        switch event.keyCode {
        case 126, 13: .up
        case 124, 2: .right
        case 125, 1: .down
        case 123, 0: .left
        default: nil
        }
    }
    override func keyDown(with event: NSEvent) {
        if let direction = direction(event) {
            if !event.isARepeat { game?.press(direction) }
            return
        }
        switch event.keyCode {
        case 12: game?.turn(-1)
        case 14: game?.turn(1)
        case 49 where game?.engine.gameOver == true: game?.restart()
        case 35: game?.togglePause()
        case 15: game?.restart()
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) {
        if let direction = direction(event) { game?.release(direction) } else { super.keyUp(with: event) }
    }
}
#else
final class LogRollInputView: MTKView {
    var game: LogRollState?
    private var touching: Direction?
    /// Touching above, below, left, or right of the middle of the screen rolls that way while held.
    /// A two-finger tap turns the maze.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? 0) >= 2 {
            if let touching { game?.release(touching) }
            touching = nil
            game?.turn(1)
            return
        }
        guard let point = touches.first?.location(in: self), bounds.width > 0 else { return }
        let dx = point.x / bounds.width - 0.5, dy = point.y / bounds.height - 0.5
        let direction: Direction = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
        touching = direction
        game?.press(direction)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touching { game?.release(touching) }
        touching = nil
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
}
#endif

struct LogRollSurface: SurfaceRepresentable {
    let game: LogRollState
    func makeCoordinator() -> LogRollViewRenderer { LogRollViewRenderer(game: game) }
    private func makeView(context: Context) -> MTKView {
        let view = LogRollInputView(frame: .zero, device: context.coordinator.renderer?.device)
        view.game = game; view.delegate = context.coordinator; view.preferredFramesPerSecond = 120
        #if os(macOS)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        #else
        view.isMultipleTouchEnabled = true
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

final class LogRollViewRenderer: NSObject, MTKViewDelegate {
    let renderer = LogRollRenderer()
    private let game: LogRollState
    private let performance = PerformanceRecorder()
    private var lastTime = CACurrentMediaTime()
    private var lastStats = CACurrentMediaTime()
    private let smoothed = OSAllocatedUnfairLock(initialState: RollStats())
    init(game: LogRollState) { self.game = game }
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

struct MazeUniforms {
    var viewProjection: simd_float4x4
    var eye: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var step: SIMD4<Float>
    var log: SIMD4<Float>
    var fire: SIMD4<Float>
    var maze: SIMD4<Float>
    var state: SIMD4<Float>
    var world: SIMD4<Float>
}

/// Renders one Log Roll frame into any BGRA texture. Each frame uses three command buffers
/// (fire simulation, 3D scene, glow and final image) so each stage reports its own GPU time.
final class LogRollRenderer {
    static let maxJets = 64
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let simulation: MTLComputePipelineState
    private let sky, floor, wall, log, fire, bright, copy, blur, composite: MTLRenderPipelineState
    private let skyDepth, solidDepth, fireDepth: MTLDepthStencilState
    private var particles: MTLBuffer?
    private var particleCount = 0
    private var walls: (maze: Maze, buffer: MTLBuffer, count: Int)?
    private var targets: (size: SIMD2<Int>, scene: MTLTexture, depth: MTLTexture, half: [MTLTexture], quarter: [MTLTexture])?
    private var started = CACurrentMediaTime()
    private var focus: SIMD2<Float>?
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
            guard let kernel = library.makeFunction(name: "rollParticles") else { return nil }
            simulation = try device.makeComputePipelineState(function: kernel)
            sky = try pipeline("rollFullscreen", "rollSky", depth: true)
            floor = try pipeline("rollFloorVertex", "rollFloor", depth: true)
            wall = try pipeline("rollWallVertex", "rollWall", depth: true)
            log = try pipeline("rollLogVertex", "rollLog", depth: true)
            fire = try pipeline("rollParticleVertex", "rollParticleFragment", depth: true, additive: true)
            bright = try pipeline("rollFullscreen", "rollBrightPass")
            copy = try pipeline("rollFullscreen", "rollCopy")
            blur = try pipeline("rollFullscreen", "rollBlur")
            composite = try pipeline("rollFullscreen", "rollComposite", format: .bgra8Unorm)
        } catch { print("Log Roll Metal pipeline error: \(error.localizedDescription)"); return nil }
        guard let skyDepth = depthState(.always, write: false), let solidDepth = depthState(.less, write: true),
              let fireDepth = depthState(.less, write: false) else { return nil }
        self.skyDepth = skyDepth; self.solidDepth = solidDepth; self.fireDepth = fireDepth
    }

    /// Encodes and commits one frame. `completed` receives CPU encode time and per-stage GPU milliseconds.
    func render(engine: LogRollEngine, particles count: Int, seconds: Double, target: MTLTexture,
                present drawable: MTLDrawable? = nil, completed: @escaping (Double, [String: Double]) -> Void) {
        let begin = CACurrentMediaTime()
        let state = signposter.beginInterval("EncodeFrame")
        defer { signposter.endInterval("EncodeFrame", state) }
        guard let particles = particleBuffer(count), let targets = textures(width: target.width, height: target.height),
              let walls = wallBuffer(engine.maze),
              let simulationBuffer = queue.makeCommandBuffer(), let sceneBuffer = queue.makeCommandBuffer(),
              let glowBuffer = queue.makeCommandBuffer() else { return }
        simulationBuffer.label = "LogRoll.Fire"; sceneBuffer.label = "LogRoll.Scene"; glowBuffer.label = "LogRoll.Glow"

        var uniforms = makeUniforms(engine: engine, count: count, seconds: seconds,
                                    aspect: Float(target.width) / Float(target.height))
        var jets = Array(repeating: SIMD4<Float>(0, 0, 0, 0), count: Self.maxJets)
        for (index, jet) in engine.maze.jets.prefix(Self.maxJets).enumerated() {
            jets[index] = SIMD4(Float(jet.x), Float(jet.z), Float(jet.phase), 0)
        }
        let uniformSize = MemoryLayout<MazeUniforms>.stride, jetSize = MemoryLayout<SIMD4<Float>>.stride * Self.maxJets

        if let compute = simulationBuffer.makeComputeCommandEncoder() {
            compute.label = "FireParticles"
            compute.setComputePipelineState(simulation)
            compute.setBuffer(particles, offset: 0, index: 0)
            compute.setBytes(&uniforms, length: uniformSize, index: 1)
            compute.setBytes(&jets, length: jetSize, index: 2)
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
            encoder.label = "MazeFloorWallsLogFire"
            encoder.setVertexBytes(&uniforms, length: uniformSize, index: 0)
            encoder.setVertexBuffer(walls.buffer, offset: 0, index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformSize, index: 0)
            encoder.setFragmentBytes(&jets, length: jetSize, index: 2)
            encoder.setDepthStencilState(skyDepth); encoder.setRenderPipelineState(sky)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.setDepthStencilState(solidDepth); encoder.setRenderPipelineState(floor)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.setRenderPipelineState(wall)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: walls.count)
            encoder.setRenderPipelineState(log)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 32 * 12)
            encoder.setDepthStencilState(fireDepth); encoder.setRenderPipelineState(fire)
            encoder.setVertexBuffer(particles, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: uniformSize, index: 1)
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

    private func makeUniforms(engine: LogRollEngine, count: Int, seconds: Double, aspect: Float) -> MazeUniforms {
        // The camera hangs above and behind the log, glides after it, and swings around when the maze turns.
        let position = SIMD2(Float(engine.position.x), Float(engine.position.z))
        var focus = self.focus ?? position
        focus += (position - focus) * min(1, Float(seconds) * 5)
        self.focus = focus
        let turn = Float(engine.turnAngle) * .pi / 2
        let ahead = SIMD3<Float>(sin(turn), 0, -cos(turn))
        let target = SIMD3(focus.x, 0, focus.y) + ahead * 0.6
        let eye = target - ahead * 5.2 + SIMD3<Float>(0, 10, 0)
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        let view = simd_float4x4(columns: (
            SIMD4(right.x, up.x, -forward.x, 0), SIMD4(right.y, up.y, -forward.y, 0), SIMD4(right.z, up.z, -forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)))
        let fieldOfView: Float = 0.82, near: Float = 0.1, far: Float = 80
        let scaleY = 1 / tan(fieldOfView / 2), scaleX = scaleY / aspect
        let projection = simd_float4x4(columns: (
            SIMD4(scaleX, 0, 0, 0), SIMD4(0, scaleY, 0, 0), SIMD4(0, 0, far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0)))
        // Keep total fire brightness similar at every detail level: more particles are smaller and dimmer.
        let ratio = Float(FireDetail.medium.rawValue) / Float(count)
        let size = pow(ratio, 1 / 6)
        let maze = engine.maze
        return MazeUniforms(viewProjection: projection * view,
                            eye: SIMD4(eye, Float(CACurrentMediaTime() - started)),
                            right: SIMD4(right, 0), up: SIMD4(up, 0),
                            step: SIMD4(Float(min(seconds, 1.0 / 20)), Float(count), 0.006 * ratio / (size * size), size),
                            log: SIMD4(position.x, position.y, Float(engine.rolled), engine.lyingAlongX ? 1 : 0),
                            fire: SIMD4(Float(engine.clock), Float(LogRollEngine.cycleTicks), Float(LogRollEngine.burnTicks),
                                        Float(LogRollEngine.warnTicks)),
                            maze: SIMD4(Float(maze.size), Float(maze.exit.x), Float(maze.exit.z),
                                        Float(min(maze.jets.count, Self.maxJets))),
                            state: SIMD4(engine.gameOver ? 1 : 0, 0, 0, 0),
                            world: SIMD4(Float(engine.heat), engine.water ? 1 : 0, Float(engine.turnAngle), 0))
    }

    /// One instance per wall block, rebuilt when the maze changes. Heights vary a little so the walls look hand-built.
    /// Gates are blocks too, and the shader raises or sinks them as the maze turns.
    private func wallBuffer(_ maze: Maze) -> (maze: Maze, buffer: MTLBuffer, count: Int)? {
        if let walls, walls.maze == maze { return walls }
        var instances: [SIMD4<Float>] = []
        for z in 0..<maze.size {
            for x in 0..<maze.size where maze.isWall(x, z) {
                var random = SeededRandom(state: UInt64(z * maze.size + x + 1) &* 0x9E3779B97F4A7C15)
                let jitter = Float(random.next() >> 40) / Float(1 << 24)
                instances.append(SIMD4(Float(x), Float(z), 0.6 + 0.15 * jitter, jitter))
            }
        }
        for gate in maze.gates { instances.append(SIMD4(Float(gate.x), Float(gate.z), 0.55, -1 - Float(gate.facing.rawValue))) }
        guard !instances.isEmpty, let buffer = device.makeBuffer(bytes: instances, length: instances.count * 16) else { return nil }
        buffer.label = "MazeWalls"
        walls = (maze, buffer, instances.count)
        if focus.map({ simd_distance($0, SIMD2(Float(maze.start.x), Float(maze.start.z))) > 3 }) ?? false { focus = nil }
        return walls
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

/// Headless Log Roll replay for CI-style GPU comparisons. It renders the autopilot into a 1280 by 720 texture.
enum LogRollOffscreenReplay {
    static func run() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let renderer = LogRollRenderer() else { throw ReplayError.unavailable }
        let (width, height) = VideoCapture.size(environment: environment, default: (1280, 720))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { throw ReplayError.unavailable }
        var seed = environment["NEON_SEED"].flatMap(UInt64.init) ?? 777
        var engine = LogRollEngine(seed: seed)
        let detail = FireDetail.from(environment: environment["LOG_ROLL_PARTICLES"]).rawValue
        let duration = environment["NEON_BENCHMARK_SECONDS"].flatMap(Double.init) ?? 20
        let recorder = PerformanceRecorder()
        let capture = try VideoCapture.from(environment: environment, width: width, height: height)
        let started = CACurrentMediaTime()
        var previous = started, frames = 0, crashes = 0
        while (capture?.seconds ?? CACurrentMediaTime() - started) < duration {
            autoreleasepool {
                let now = capture.map { started + $0.seconds } ?? CACurrentMediaTime(), delta = now - previous
                previous = now
                engine.advance(delta, autoplay: true)
                if engine.gameOver { crashes += 1; seed &+= 1; engine = LogRollEngine(seed: seed) }
                let done = DispatchSemaphore(value: 0)
                let score = engine.score
                renderer.render(engine: engine, particles: detail, seconds: delta, target: texture) { cpu, stages in
                    recorder.record(gpuStages: stages, frameMilliseconds: delta * 1000, cpuMilliseconds: cpu,
                                    score: score, width: width, height: height, workload: "offscreen", particles: detail)
                    done.signal()
                }
                done.wait()
                capture?.append(texture)
                frames += 1
                if capture == nil { Thread.sleep(forTimeInterval: max(0, 1.0 / 60.0 - (CACurrentMediaTime() - now))) }
            }
        }
        capture?.finish()
        recorder.finish()
        if let output = environment["NEON_PERF_REPORT"] {
            try OffscreenReplay.savePreview(texture, at: URL(fileURLWithPath: output).deletingLastPathComponent()
                .appendingPathComponent("log-roll.png"))
        }
        print("Log Roll offscreen replay completed. Frames: \(frames), score: \(engine.score), crashes: \(crashes)")
    }
}

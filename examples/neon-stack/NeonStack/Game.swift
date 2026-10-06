import MetalKit
import SwiftUI
import os

final class GameState: ObservableObject {
    @Published var engine: GameEngine
    @Published var paused = false
    @Published var renderMode = "neon"
    @Published var auroraLayers = 24
    var glow: Bool { renderMode != "classic" }
    @Published var fps = 0.0
    @Published var gpuMilliseconds = 0.0
    @Published var soundEnabled = true
    @Published var clearAnimation: ClearAnimation?
    var reducedMotion = false
    private lazy var audio = GameAudio()
    let benchmark = ProcessInfo.processInfo.environment["NEON_BENCHMARK"] == "1"
    let signposter = OSSignposter(subsystem: "dev.example.NeonStack", category: .pointsOfInterest)
    init() {
        let seed = ProcessInfo.processInfo.environment["NEON_SEED"].flatMap(UInt64.init)
            ?? UInt64.random(in: 1...UInt64.max)
        engine = GameEngine(seed: seed)
        if let scenario = ProcessInfo.processInfo.environment["NEON_FEEDBACK_SCENARIO"],
           let demo = GameEngine.clearDemo(scenario, seed: seed) { engine = demo }
        renderMode = ProcessInfo.processInfo.environment["NEON_RENDER_MODE"] ?? "neon"
        auroraLayers = min(48, max(1, ProcessInfo.processInfo.environment["NEON_AURORA_LAYERS"].flatMap(Int.init) ?? 24))
        GameTelemetry.client.event("game.session.started", attributes: ["render_mode": .string(renderMode)])
    }
    func action(_ key: String) {
        guard !benchmark else { return }
        if key == "restart" { audio.stop(); engine = GameEngine(); clearAnimation = nil; paused = false; return }
        if key == "pause" { paused.toggle(); if paused { audio.stop() }; return }
        guard !paused && !engine.gameOver else { return }
        if ["drop", "hold", "rotate"].contains(key) {
            GameTelemetry.client.withSpan("game.\(key)", attributes: ["render_mode": .string(renderMode)]) {
                playAction(key)
            }
        } else { playAction(key) }
    }
    private func playAction(_ key: String) {
        let previousLocks = engine.piecesLocked
        switch key {
        case "left": engine.move(dx: -1, dy: 0)
        case "right": engine.move(dx: 1, dy: 0)
        case "down": if engine.move(dx: 0, dy: 1) { engine.score += 1 }
        case "rotate":
            let previous = engine.piece.cells
            engine.rotate()
            if engine.piece.cells != previous { play(.rotate) }
        case "hold":
            if engine.hold() { signposter.emitEvent("HoldPiece"); play(engine.gameOver ? .gameOver : .hold) }
        case "drop":
            let state = signposter.beginInterval("HardDrop")
            engine.hardDrop(); signposter.endInterval("HardDrop", state)
        default: break
        }
        feedback(after: previousLocks)
    }
    func tick() {
        guard !paused && !engine.gameOver else { return }
        let state = signposter.beginInterval("GameUpdate")
        let previous = engine.piecesLocked
        if benchmark { engine.autoplay() } else { engine.step() }
        feedback(after: previous)
        signposter.endInterval("GameUpdate", state)
    }
    func toggleSound() {
        soundEnabled.toggle()
        if !soundEnabled { audio.stop() }
    }
    private func play(_ cue: SoundCue) {
        if soundEnabled && !benchmark { audio.play(cue) }
    }
    private func feedback(after previousLocks: Int) {
        guard engine.piecesLocked != previousLocks else { return }
        if engine.lastClear > 0 {
            GameTelemetry.client.event("game.line_clear", attributes: [
                "cleared_lines": .int(engine.lastClear), "all_clear": .bool(engine.lastAllClear),
                "score": .int(engine.score), "render_mode": .string(renderMode),
            ])
            signposter.emitEvent("LineClear")
            if engine.lastAllClear { signposter.emitEvent("AllClear") }
            else if engine.lastClear == 4 { signposter.emitEvent("FourLineClear") }
            let effect = ClearAnimation(rows: engine.lastClearRows, allClear: engine.lastAllClear, started: CACurrentMediaTime())
            clearAnimation = effect
            play(engine.lastAllClear ? .allClear : (engine.lastClear == 4 ? .four : .line))
            DispatchQueue.main.asyncAfter(deadline: .now() + effect.duration) { [weak self] in
                if self?.clearAnimation?.started == effect.started { self?.clearAnimation = nil }
            }
        } else { play(engine.gameOver ? .gameOver : .lock) }
    }
}

@main struct NeonStackApp: App {
    @StateObject private var game = GameState()
    @StateObject private var logRoll = LogRollState()
    init() {
        if ProcessInfo.processInfo.environment["NEON_OFFSCREEN"] == "1" {
            do { try OffscreenReplay.run(); exit(0) }
            catch { print("Offscreen replay failed: \(error)"); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup {
            GameSwitcher(game: game, logRoll: logRoll)
                .onAppear {
                    #if os(macOS)
                    if game.benchmark,
                       let seconds = ProcessInfo.processInfo.environment["NEON_BENCHMARK_SECONDS"].flatMap(Double.init) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApplication.shared.terminate(nil) }
                    }
                    #endif
                }
                #if os(macOS)
                .frame(minWidth: 720, idealWidth: 850, minHeight: 780, idealHeight: 850)
                #endif
        }
    }
}

/// Chooses between Neon Stack and Log Roll. Benchmarks pick the game with NEON_GAME and hide the switcher.
struct GameSwitcher: View {
    @ObservedObject var game: GameState
    let logRoll: LogRollState
    @State private var selection = ProcessInfo.processInfo.environment["NEON_GAME"]
        ?? (ProcessInfo.processInfo.environment["NEON_BENCHMARK"] == "1" ? "neon-stack" : "log-roll")
    var body: some View {
        VStack(spacing: 0) {
            if !game.benchmark {
                Picker("Game", selection: $selection) {
                    Text("Log Roll").tag("log-roll")
                    Text("Neon Stack").tag("neon-stack")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260).padding(.top, 10)
            }
            if selection == "log-roll" { LogRollScreen(game: logRoll) } else { GameScreen(game: game) }
        }.background(Color.black)
    }
}

struct GameScreen: View {
    @ObservedObject var game: GameState
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let cyan = Color(red: 0.2, green: 0.94, blue: 0.96)
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > 600
            VStack(spacing: wide ? 22 : 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("NEON STACK").font(.system(size: wide ? 32 : 24, weight: .black, design: .monospaced)).tracking(3)
                        Text("FALL INTO THE FLOW").font(.system(size: 10, design: .monospaced)).tracking(3).foregroundStyle(cyan)
                    }
                    Spacer()
                    if wide { renderingControls() }
                }
                if !wide { renderingControls() }
                if game.renderMode == "aurora" {
                    Picker("Aurora detail", selection: $game.auroraLayers) {
                        Text("Low").tag(8); Text("Medium").tag(24); Text("High").tag(48)
                    }.pickerStyle(.segmented).frame(maxWidth: 300).disabled(game.benchmark)
                        .accessibilityLabel("Aurora detail")
                }
                if !wide {
                    HStack { stat("SCORE", game.engine.score); Spacer(); stat("LINES", game.engine.lines)
                        Spacer(); stat("LEVEL", game.engine.level) }
                    HStack(spacing: 12) {
                        preview("NEXT", kind: game.engine.nextKind)
                        preview(holdTitle, kind: game.engine.heldKind)
                    }.frame(height: 65)
                }
                HStack(alignment: .top, spacing: 24) {
                    if wide {
                        VStack(alignment: .leading, spacing: 12) {
                            stat("SCORE", game.engine.score); stat("LINES", game.engine.lines); stat("LEVEL", game.engine.level)
                            Rectangle().fill(cyan.opacity(0.2)).frame(height: 1)
                            preview("NEXT UP", kind: game.engine.nextKind).frame(height: 70)
                            preview(holdTitle, kind: game.engine.heldKind).frame(height: 70)
                            Spacer()
                            Text("← →  MOVE\n↑     ROTATE\n↓     SOFT DROP\nSPACE HARD DROP\nC     HOLD / SWAP\nP     PAUSE\nR     RESTART")
                                .font(.system(size: 10, design: .monospaced)).lineSpacing(4).foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(width: 155)
                    }
                    ZStack {
                        GameSurface(game: game).clipShape(RoundedRectangle(cornerRadius: 12))
                        if let effect = game.clearAnimation {
                            ClearBanner(effect: effect).id(effect.started).allowsHitTesting(false)
                        }
                        if game.paused || game.engine.gameOver {
                            VStack(spacing: 16) {
                                Text(game.engine.gameOver ? "STACK COMPLETE" : "TAKE A BREATH")
                                    .font(.system(size: 20, weight: .black, design: .monospaced))
                                Text("Score \(game.engine.score)").foregroundStyle(cyan)
                                Button(game.engine.gameOver ? "Play again" : "Resume") {
                                    game.action(game.engine.gameOver ? "restart" : "pause")
                                }.buttonStyle(.borderedProminent).tint(cyan).foregroundStyle(.black)
                            }.padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }.aspectRatio(0.5, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(cyan.opacity(0.3), lineWidth: 1))
                        .shadow(color: cyan.opacity(game.glow ? 0.25 : 0), radius: 25)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 8) {
                    control("←", "left"); control("↻", "rotate"); control("→", "right")
                    control("↓", "down"); control("DROP", "drop"); control("HOLD", "hold")
                    control(game.paused ? "▶" : "Ⅱ", "pause")
                }
                HStack {
                    Circle().fill(cyan).frame(width: 5, height: 5)
                    Text(game.benchmark ? "FIXED-SEED REPLAY" : "METAL · LIVE")
                    Spacer()
                    Button { game.toggleSound() } label: {
                        Image(systemName: game.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }.buttonStyle(.plain).disabled(game.benchmark)
                        .accessibilityLabel(game.soundEnabled ? "Mute sound" : "Enable sound")
                        .help(game.soundEnabled ? "Mute sound" : "Enable sound")
                    Text(String(format: "%.0f FPS / %.2f ms GPU", game.fps, game.gpuMilliseconds))
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            }.padding(wide ? 30 : 18).foregroundStyle(.white)
                .background(LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.12), .black],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .onAppear { game.reducedMotion = reducedMotion }
                .onChange(of: reducedMotion) { _, value in game.reducedMotion = value }
        }
    }
    var holdTitle: String {
        if game.engine.holdUsed { return "HOLD · DROP TO SWAP" }
        return game.engine.heldKind == nil ? "HOLD · C TO STORE" : "HOLD · C TO SWAP"
    }
    func preview(_ title: String, kind: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            PiecePreview(kind: kind).opacity(title.hasPrefix("HOLD") && game.engine.holdUsed ? 0.45 : 1)
        }.accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(kind.map { ["I", "O", "T", "S", "Z", "L", "J"][$0] + " piece" } ?? "Empty")")
    }
    func renderingControls() -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("Rendering mode", selection: $game.renderMode) {
                Text("Classic").tag("classic")
                Text("Neon").tag("neon")
                Text("Aurora").tag("aurora")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 270).disabled(game.benchmark)
            Text(game.renderMode == "aurora" ? "LIVING LIGHTS + GLOW" : (game.glow ? "GLOW + SCANLINES" : "FLAT COLORS"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(game.glow ? cyan : .white.opacity(0.65))
        }
    }
    func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(.white.opacity(0.45))
            Text(String(format: "%02d", value)).font(.system(size: 27, weight: .bold, design: .monospaced)).foregroundStyle(cyan)
        }
    }
    func control(_ label: String, _ action: String) -> some View {
        Button { game.action(action) } label: {
            Text(label).font(.system(size: label.count > 1 ? 11 : 15, weight: .bold, design: .monospaced)).frame(maxWidth: .infinity).frame(height: 40)
        }.buttonStyle(.plain).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .disabled(game.benchmark || (action == "hold" && (!game.engine.canHold || game.paused)))
            .opacity(action == "hold" && (!game.engine.canHold || game.paused) ? 0.4 : 1)
            .accessibilityLabel(action.capitalized)
            .help(action == "hold" ? "Hold or swap with C. Available once per piece." : action.capitalized)
    }
}

struct ClearBanner: View {
    let effect: ClearAnimation
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var fading = false
    var body: some View {
        Text(effect.title)
            .font(.system(size: effect.allClear ? 27 : 22, weight: .black, design: .monospaced))
            .tracking(2).foregroundStyle(effect.allClear ? Color.yellow : Color.cyan)
            .padding(16).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(reducedMotion ? 1 : (fading ? 1.08 : 0.9)).opacity(fading ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: effect.duration * 0.6).delay(effect.duration * 0.4)) { fading = true }
            }
    }
}

struct PiecePreview: View {
    let kind: Int?
    var body: some View {
        Canvas { context, size in
            guard let kind else {
                context.draw(Text("EMPTY").font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.35)),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let colors: [Color] = [.cyan, .yellow, .purple, .green, .red, .orange, .blue]
            let cells = Piece(kind: kind, x: 0, y: 0).cells
            let minX = cells.map(\.x).min() ?? 0; let minY = cells.map(\.y).min() ?? 0
            let columns = (cells.map(\.x).max() ?? 0) - minX + 1
            let rows = (cells.map(\.y).max() ?? 0) - minY + 1
            let unit = min(24, min((size.width - 12) / CGFloat(columns), (size.height - 8) / CGFloat(rows)))
            let origin = CGPoint(x: (size.width - CGFloat(columns) * unit) / 2, y: (size.height - CGFloat(rows) * unit) / 2)
            for cell in cells {
                let rect = CGRect(x: origin.x + CGFloat(cell.x - minX) * unit, y: origin.y + CGFloat(cell.y - minY) * unit,
                                  width: unit - 2, height: unit - 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(colors[kind]))
            }
        }.background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }
}

#if os(macOS)
typealias SurfaceRepresentable = NSViewRepresentable
final class InputView: MTKView {
    var game: GameState?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        let actions: [UInt16: String] = [123:"left", 124:"right", 125:"down", 126:"rotate", 49:"drop", 8:"hold", 35:"pause", 15:"restart"]
        if let action = actions[event.keyCode] { game?.action(action) } else { super.keyDown(with: event) }
    }
}
#else
typealias SurfaceRepresentable = UIViewRepresentable
final class InputView: MTKView { var game: GameState? }
#endif

struct GameSurface: SurfaceRepresentable {
    let game: GameState
    func makeCoordinator() -> Renderer { Renderer(game: game) }
    private func makeView(context: Context) -> MTKView {
        let view = InputView(frame: .zero, device: context.coordinator.device)
        view.game = game; view.delegate = context.coordinator; view.preferredFramesPerSecond = 60
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

final class Renderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    private let game: GameState
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var lastTime = CACurrentMediaTime()
    private var elapsed: Double = 0
    private var gravity: Double = 0
    private let performance = PerformanceRecorder()
    private let signposter = OSSignposter(subsystem: "dev.example.NeonStack", category: .pointsOfInterest)
    init(game: GameState) {
        self.game = game; super.init(); queue = device?.makeCommandQueue()
        let descriptor = MTLRenderPipelineDescriptor()
        let library = device?.makeDefaultLibrary()
        descriptor.vertexFunction = library?.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library?.makeFunction(name: "neonStack")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do { pipeline = try device?.makeRenderPipelineState(descriptor: descriptor) }
        catch { print("Neon Stack Metal pipeline error: \(error.localizedDescription)") }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(); let delta = now - lastTime; lastTime = now
        elapsed += delta; gravity += min(delta, 0.1)
        let interval = game.benchmark ? 0.35 : max(0.12, 0.8 - Double(game.engine.level - 1) * 0.06)
        if gravity >= interval { game.tick(); gravity = 0 }
        let state = signposter.beginInterval("EncodeFrame")
        defer { signposter.endInterval("EncodeFrame", state) }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let pipeline, let command = queue?.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        command.label = "NeonStack.Frame"; encoder.label = "BoardAndGlow"
        var uniforms = SIMD4<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height), Float(game.reducedMotion ? 0 : elapsed), game.renderMode == "aurora" ? 2 : (game.glow ? 1 : 0))
        let cells = game.engine.displayCells
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        cells.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { encoder.setFragmentBytes(base, length: bytes.count, index: 1) }
        }
        var effect = game.clearAnimation?.uniforms(at: now, reducedMotion: game.reducedMotion) ?? SIMD4<Float>(-1, 0, 0, 0)
        var rowMask = game.clearAnimation?.rowMask ?? 0
        encoder.setFragmentBytes(&effect, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        encoder.setFragmentBytes(&rowMask, length: MemoryLayout<UInt32>.size, index: 3)
        var auroraLayers = UInt32(game.renderMode == "aurora" ? game.auroraLayers : 0)
        encoder.setFragmentBytes(&auroraLayers, length: MemoryLayout<UInt32>.size, index: 4)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        let cpu = (CACurrentMediaTime() - now) * 1000
        let mode = game.renderMode; let lines = game.engine.lines; let score = game.engine.score
        let size = view.drawableSize
        let detail = Int(auroraLayers)
        command.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            self.performance.record(commandBuffer: buffer, frameMilliseconds: delta * 1000, cpuMilliseconds: cpu,
                                    mode: mode, lines: lines, score: score,
                                    width: Int(size.width), height: Int(size.height), auroraLayers: detail)
        }
        command.present(drawable); command.commit()
        if let display = performance.display() { game.fps = display.0; game.gpuMilliseconds = display.1 }
    }
}

import MetalKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import os

enum ReplayError: Error { case unavailable }

enum OffscreenReplay {
    static func run() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["NEON_GAME"] == "flappy-log" { try FlappyOffscreenReplay.run(); return }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { throw ReplayError.unavailable }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name: "neonStack")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                         width: 600, height: 1200, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { throw ReplayError.unavailable }
        var engine = GameEngine(seed: environment["NEON_SEED"].flatMap(UInt64.init) ?? 777)
        let demo = environment["NEON_FEEDBACK_SCENARIO"].flatMap { GameEngine.clearDemo($0) }
        if let demo { engine = demo }
        let duration = environment["NEON_BENCHMARK_SECONDS"].flatMap(Double.init) ?? 20
        let mode = environment["NEON_RENDER_MODE"] ?? "neon"
        let detail = mode == "aurora" ? min(48, max(1, environment["NEON_AURORA_LAYERS"].flatMap(Int.init) ?? 24)) : 0
        let recorder = PerformanceRecorder()
        let signposter = OSSignposter(subsystem: "dev.example.NeonStack", category: .pointsOfInterest)
        let started = CACurrentMediaTime()
        var previous = started
        var frame = 0
        var effect: ClearAnimation?
        var previews: Set<String> = []
        while CACurrentMediaTime() - started < duration {
            try autoreleasepool {
                let now = CACurrentMediaTime()
                let interval = (now - previous) * 1000
                previous = now
                if frame % 21 == 0 {
                    let previousLocks = engine.piecesLocked
                    if demo != nil && frame == 0 { engine.hardDrop() } else { engine.autoplay() }
                    if engine.piecesLocked != previousLocks && engine.lastClear > 0 {
                        effect = ClearAnimation(rows: engine.lastClearRows, allClear: engine.lastAllClear, started: now)
                        signposter.emitEvent("LineClear")
                        if engine.lastAllClear { signposter.emitEvent("AllClear") }
                        else if engine.lastClear == 4 { signposter.emitEvent("FourLineClear") }
                    }
                }
                let state = signposter.beginInterval("OffscreenFrame")
                defer { signposter.endInterval("OffscreenFrame", state) }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                guard let command = queue.makeCommandBuffer(),
                      let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw ReplayError.unavailable }
                command.label = "NeonStack.OffscreenFrame"; encoder.label = "BoardAndGlow"
                encoder.setRenderPipelineState(pipeline)
                var uniforms = SIMD4<Float>(600, 1200, Float(now - started), mode == "aurora" ? 2 : (mode == "neon" ? 1 : 0))
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                engine.displayCells.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress { encoder.setFragmentBytes(base, length: bytes.count, index: 1) }
                }
                var feedback = effect?.uniforms(at: now) ?? SIMD4<Float>(-1, 0, 0, 0)
                var rowMask = effect?.rowMask ?? 0
                encoder.setFragmentBytes(&feedback, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
                encoder.setFragmentBytes(&rowMask, length: MemoryLayout<UInt32>.size, index: 3)
                var auroraLayers = UInt32(detail)
                encoder.setFragmentBytes(&auroraLayers, length: MemoryLayout<UInt32>.size, index: 4)

                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
                let cpu = (CACurrentMediaTime() - now) * 1000
                command.commit(); command.waitUntilCompleted()
                if command.status == .error { throw command.error ?? ReplayError.unavailable }
                if demo != nil, let effect, now - effect.started >= 0.12, now - effect.started < 0.3,
                   let output = environment["NEON_PERF_REPORT"] {
                    let name = effect.allClear ? "all-clear" : (effect.rows.count == 4 ? "four-lines" : "line-clear")
                    if previews.insert(name).inserted {
                        try savePreview(texture, at: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(name + ".png"))
                    }
                }
                let gpu = command.gpuStartTime > 0 ? (command.gpuEndTime - command.gpuStartTime) * 1000 : nil
                recorder.record(frameMilliseconds: interval, cpuMilliseconds: cpu, gpuMilliseconds: gpu,
                                mode: mode, lines: engine.lines, score: engine.score, width: 600, height: 1200,
                                workload: "offscreen", auroraLayers: detail)
                frame += 1
                Thread.sleep(forTimeInterval: max(0, 1.0 / 60.0 - (CACurrentMediaTime() - now)))
            }
        }
        recorder.finish()
        if let output = environment["NEON_PERF_REPORT"] {
            try savePreview(texture, at: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("board.png"))
        }
        print("Offscreen replay completed. Frames: \(frame), lines: \(engine.lines), score: \(engine.score)")
    }

    static func savePreview(_ texture: MTLTexture, at url: URL) throws {
        var bytes = Array(repeating: UInt8(0), count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: texture.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ReplayError.unavailable }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) { throw ReplayError.unavailable }
    }
}

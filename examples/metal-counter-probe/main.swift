import Foundation
import Metal

guard let device = MTLCreateSystemDefaultDevice(), device.supportsCounterSampling(.atStageBoundary),
      let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else {
    print("Stage-boundary timestamp counters are unavailable on this device.")
    exit(0)
}
let descriptor = MTLCounterSampleBufferDescriptor()
descriptor.counterSet = set; descriptor.sampleCount = 8; descriptor.storageMode = .shared
let samples = try device.makeCounterSampleBuffer(descriptor: descriptor)
let library = try device.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
vertex float4 vertexMain(uint index [[vertex_id]]) {
    float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    return float4(p[index],0,1);
}
fragment float4 fragmentMain() { return float4(0.2,0.3,0.7,1); }
""", options: nil)
let pipelineDescriptor = MTLRenderPipelineDescriptor()
pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexMain")
pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
textureDescriptor.usage = .renderTarget
guard let texture = device.makeTexture(descriptor: textureDescriptor), let queue = device.makeCommandQueue(),
      let command = queue.makeCommandBuffer() else { fatalError("Metal resource creation failed") }
let before = device.sampleTimestamps()
for pass in 0..<2 {
    let render = MTLRenderPassDescriptor()
    render.colorAttachments[0].texture = texture
    render.colorAttachments[0].loadAction = .clear; render.colorAttachments[0].storeAction = .store
    let attachment = render.sampleBufferAttachments[0]!
    attachment.sampleBuffer = samples
    attachment.startOfVertexSampleIndex = pass * 4; attachment.endOfVertexSampleIndex = pass * 4 + 1
    attachment.startOfFragmentSampleIndex = pass * 4 + 2; attachment.endOfFragmentSampleIndex = pass * 4 + 3
    guard let encoder = command.makeRenderCommandEncoder(descriptor: render) else { fatalError("Render encoder creation failed") }
    encoder.setRenderPipelineState(pipeline)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
}
command.commit(); command.waitUntilCompleted()
let after = device.sampleTimestamps()
guard command.status == .completed, after.cpu > before.cpu, after.gpu > before.gpu,
      let resolved = try samples.resolveCounterRange(0..<8),
      resolved.count >= 8 * MemoryLayout<MTLCounterResultTimestamp>.stride else {
    print("Counter results or clock calibration are unavailable.")
    exit(1)
}
let timestamps = resolved.withUnsafeBytes { data in
    (0..<8).map { data.loadUnaligned(fromByteOffset: $0 * MemoryLayout<MTLCounterResultTimestamp>.stride, as: UInt64.self) }
}
// Apple supplies CPU timestamps in nanoseconds. Calibrate the GPU clock before interpreting differences.
let millisecondsPerTick = Double(after.cpu - before.cpu) / Double(after.gpu - before.gpu) / 1_000_000
print("device=\(device.name) passes=2 command_buffers=1")
for pass in 0..<2 {
    let row = Array(timestamps[(pass * 4)..<(pass * 4 + 4)])
    guard row.allSatisfy({ $0 > 0 && $0 != UInt64.max }), row[1] >= row[0], row[3] >= row[2] else {
        print("pass=\(pass) timestamps=unavailable")
        continue
    }
    print("pass=\(pass) vertex_ms=\(Double(row[1] - row[0]) * millisecondsPerTick) fragment_ms=\(Double(row[3] - row[2]) * millisecondsPerTick)")
}
print("gpu_command_ms=\((command.gpuEndTime - command.gpuStartTime) * 1000)")

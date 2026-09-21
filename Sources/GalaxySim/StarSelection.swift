import Metal
import simd

/// Picking reads back one candidate per GPU workgroup, not every particle.
/// The caller synchronizes the simulation before inspecting the selected star.
final class StarPicker {
    private let ctx: MetalContext
    private let pipeline: MTLComputePipelineState
    init(ctx: MetalContext) throws {
        self.ctx = ctx
        pipeline = try ctx.computePipeline("pickExplorerStar")
    }
    func pick(sim: Simulation, camera: CameraUniforms, relativity: RelativityUniforms,
              pixel: SIMD2<Float>, radius: Float) -> Int? {
        guard sim.particleCount > 0 else { return nil }
        let groups = (sim.particleCount + 255) / 256
        guard let result = ctx.device.makeBuffer(length: groups * 8, options: .storageModeShared),
              let cb = ctx.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        var cam = camera, rel = relativity, count = UInt32(sim.particleCount)
        var click = SIMD4(pixel.x, pixel.y, radius, 0)
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(sim.particleBuffer, offset: 0, index: 0)
        enc.setBuffer(sim.auxBuffer, offset: 0, index: 1)
        enc.setBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 2)
        enc.setBytes(&rel, length: MemoryLayout<RelativityUniforms>.stride, index: 3)
        enc.setBytes(&count, length: 4, index: 4)
        enc.setBytes(&click, length: 16, index: 5)
        enc.setBuffer(result, offset: 0, index: 6)
        enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        var best = Float.infinity
        var index: UInt32 = .max
        for group in 0..<groups {
            let pointer = result.contents().advanced(by: group * 8)
            let distance = pointer.load(as: Float.self)
            let candidate = pointer.advanced(by: 4).load(as: UInt32.self)
            if distance < best || (distance == best && candidate < index) {
                best = distance; index = candidate
            }
        }
        return index == .max ? nil : Int(index)
    }
}

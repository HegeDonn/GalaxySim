import Foundation
import Metal
import simd

/// A rigid ship-local frame: relativity affects the sky, never the vessel.
struct ShipRenderState {
    var viewProjection: float4x4
    var eye: SIMD3<Float>
    var beta: Float
    var time: Float
}

private struct ShipUniforms {
    var viewProjection: float4x4
    var eye: SIMD4<Float>
    var flight: SIMD4<Float>
}

final class ShipRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let exhaustPipeline: MTLRenderPipelineState
    private let exhaustDepth: MTLDepthStencilState
    /// 2 nozzles x 34 puffs x 6 vertices.
    private let exhaustVertexCount = 2 * 34 * 6
    private let depthState: MTLDepthStencilState
    private let vertices: MTLBuffer
    private let vertexCount: Int
    private var depth: MTLTexture?

    init(ctx: MetalContext) throws {
        device = ctx.device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "City ship HDR"
        descriptor.vertexFunction = try ctx.function("shipVertex")
        descriptor.fragmentFunction = try ctx.function("shipFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)!

        // Additive plume: tested against the hull so the ship occludes it, but
        // not writing depth, so overlapping puffs accumulate instead of
        // punching holes in each other.
        let ed = MTLRenderPipelineDescriptor()
        ed.label = "Engine exhaust"
        ed.vertexFunction = try ctx.function("shipExhaustVertex")
        ed.fragmentFunction = try ctx.function("shipExhaustFragment")
        ed.colorAttachments[0].pixelFormat = .rgba16Float
        ed.colorAttachments[0].isBlendingEnabled = true
        ed.colorAttachments[0].rgbBlendOperation = .add
        ed.colorAttachments[0].alphaBlendOperation = .add
        ed.colorAttachments[0].sourceRGBBlendFactor = .one
        ed.colorAttachments[0].destinationRGBBlendFactor = .one
        ed.colorAttachments[0].sourceAlphaBlendFactor = .one
        ed.colorAttachments[0].destinationAlphaBlendFactor = .one
        ed.depthAttachmentPixelFormat = .depth32Float
        exhaustPipeline = try device.makeRenderPipelineState(descriptor: ed)

        let edd = MTLDepthStencilDescriptor()
        edd.depthCompareFunction = .less
        edd.isDepthWriteEnabled = false
        exhaustDepth = device.makeDepthStencilState(descriptor: edd)!
        guard let url = Bundle.module.url(forResource: "ship", withExtension: "mesh", subdirectory: "Ship") else {
            throw CabinAsset.LoadError.invalid("Missing city ship asset Ship/ship.mesh")
        }
        let mesh = try CabinAsset.loadVertices(from: url)
        vertexCount = mesh.count
        guard let buffer = device.makeBuffer(bytes: mesh, length: mesh.count * MemoryLayout<CabinVertex>.stride,
                                             options: .storageModeShared) else {
            throw CabinAsset.LoadError.invalid("Could not allocate city ship mesh")
        }
        vertices = buffer
        vertices.label = "Procedural Blender city ship"
        print("Loaded city ship: \(vertexCount / 3) triangles, \(vertexCount * 64) vertex bytes")
    }

    /// Opaque ship overwrites the sky, then shares its optical bloom and tone mapping.
    func draw(into target: MTLTexture, commandBuffer: MTLCommandBuffer, state: ShipRenderState) {
        if depth?.width != target.width || depth?.height != target.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                width: target.width, height: target.height, mipmapped: false)
            d.storageMode = .private
            d.usage = .renderTarget
            depth = device.makeTexture(descriptor: d)
        }
        guard let depth else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Exterior city ship"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        var u = ShipUniforms(viewProjection: state.viewProjection, eye: SIMD4(state.eye, 1),
                             flight: SIMD4(state.beta, state.time, 0, 0))
        encoder.setVertexBytes(&u, length: MemoryLayout<ShipUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<ShipUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)

        // Plume last, in the same pass so it can depth-test against the hull
        // it just drew — the nozzles occlude their own exhaust from in front.
        encoder.setRenderPipelineState(exhaustPipeline)
        encoder.setDepthStencilState(exhaustDepth)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: exhaustVertexCount)
        encoder.endEncoding()
    }
}

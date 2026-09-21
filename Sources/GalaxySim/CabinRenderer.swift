import Metal
import simd

/// Ship-local camera. Exterior relativity never transforms this geometry.
struct CabinRenderState {
    var viewProjection: float4x4
    var eye: SIMD3<Float>
    var beta: Float
    var time: Float
}

private struct CabinUniforms {
    var viewProjection: float4x4
    var eye: SIMD4<Float>
    var flight: SIMD4<Float>
}

/// One opaque pass with its own depth buffer, preserving the galaxy in the windows.
final class CabinRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let glassPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let glassDepthState: MTLDepthStencilState
    private let vertices: MTLBuffer
    private let vertexCount: Int
    private let glassVertexCount: Int
    private var depth: MTLTexture?

    init(ctx: MetalContext, colorFormat: MTLPixelFormat) throws {
        device = ctx.device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Solid cabin"
        descriptor.vertexFunction = try ctx.function("cabinVertex")
        descriptor.fragmentFunction = try ctx.function("cabinFragment")
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.label = "Cabin laminated glass"
        descriptor.fragmentFunction = try ctx.function("cabinGlassFragment")
        let blend = descriptor.colorAttachments[0]!
        blend.isBlendingEnabled = true
        blend.sourceRGBBlendFactor = .one
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        glassPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)!
        dd.depthCompareFunction = .lessEqual
        dd.isDepthWriteEnabled = false
        glassDepthState = device.makeDepthStencilState(descriptor: dd)!
        let importedMesh = CabinAsset.loadBundledVertices()
        let mesh = importedMesh ?? CabinGeometry.makeVertices()
        var opaque: [CabinVertex] = []
        var glass: [CabinVertex] = []
        opaque.reserveCapacity(mesh.count)
        for start in stride(from: 0, to: mesh.count, by: 3) {
            let triangle = mesh[start..<start + 3]
            if triangle.allSatisfy({ $0.detail.x >= 3.5 && $0.detail.x < 4.5 }) {
                glass.append(contentsOf: triangle)
            } else {
                opaque.append(contentsOf: triangle)
            }
        }
        vertexCount = opaque.count
        glassVertexCount = glass.count
        opaque.append(contentsOf: glass)
        vertices = device.makeBuffer(bytes: opaque, length: opaque.count * MemoryLayout<CabinVertex>.stride,
                                     options: .storageModeShared)!
        vertices.label = importedMesh == nil ? "Procedural cabin mesh" : "Blender cabin mesh"
    }

    func draw(into target: MTLTexture, commandBuffer: MTLCommandBuffer, state: CabinRenderState,
              exterior: MTLTexture, blurredExterior: MTLTexture, sensor: SensorParams) {
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
        encoder.label = "Ship interior"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        var u = CabinUniforms(viewProjection: state.viewProjection, eye: SIMD4(state.eye, 1),
                              flight: SIMD4(state.beta, state.time, Float(target.width), Float(target.height)))
        encoder.setVertexBytes(&u, length: MemoryLayout<CabinUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<CabinUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        if glassVertexCount > 0 {
            encoder.setRenderPipelineState(glassPipeline)
            encoder.setDepthStencilState(glassDepthState)
            encoder.setFragmentTexture(exterior, index: 0)
            encoder.setFragmentTexture(blurredExterior, index: 1)
            var sensor = sensor
            encoder.setFragmentBytes(&sensor, length: MemoryLayout<SensorParams>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: vertexCount, vertexCount: glassVertexCount)
        }
        encoder.endEncoding()
    }
}

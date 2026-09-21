import Metal
import MetalKit
import simd

/// Mirrors `CameraUniforms` in Render.metal (112 bytes).
struct CameraUniforms {
    var viewProj: float4x4 = matrix_identity_float4x4
    var cameraPos: SIMD4<Float> = .zero
    var viewport: SIMD4<Float> = .zero
    var tuning: SIMD4<Float> = .zero     // pointScale, exposure, fogDensity, brightness
    var extra: SIMD4<Float> = .zero      // wrapCell (0 = no wrapping)
}

/// Mirrors `SensorParams` in Render.metal.
struct SensorParams {
    var a: SIMD4<Float> = .zero   // exposure, filmK, filmN, psfStrength
    var b: SIMD4<Float> = .zero   // psf mip weights
    var c: SIMD4<Float> = .zero   // vignette, saturation, halation, _
}

/// Mirrors `WebParams` in CosmicWeb.metal.
struct WebParams {
    var a = SIMD4<Float>(3.2, 0.20, 0.015, 12)   // scale, growth D, softening, steps
    var b = SIMD4<Float>(0.9, 1.0, 0, 0)         // depth, _, seed, _
    var c = SIMD4<Float>(0.05, 0, 0, 0)          // finite-difference step
}

/// Mirrors `SkyParams` in CosmicWeb.metal.
struct SkyParams {
    var invViewProj: float4x4 = matrix_identity_float4x4
    var params = SIMD4<Float>(1, 0, 0, 0)
}

/// Mirrors `GridParams` in Render.metal.
struct GridParams {
    var invViewProj: float4x4 = matrix_identity_float4x4
    var camPos = SIMD4<Float>(0, 0, 0, 0)    // xyz, w = opacity
    var cursor = SIMD4<Float>(0, 0, 0, 0)    // xyz, w = valid
    var tuning = SIMD4<Float>(10, 400, 6, 0) // spacing kpc, fade kpc, ring radius
}

struct StarLODParams {
    var count: UInt32
    var fraction: Float
    var nearRadius: Float = 10
    var farRadius: Float = 30
}

struct RenderSettings {
    /// Approximate distant-star rendering; physics always retains every star.
    var adaptiveStars = true
    /// Expected distant sample count before visibility culling (not a hard cap).
    var distantStarBudget = 1_000_000

    var starSize: Float = 1.05
    var exposure: Float = 1.0

    /// Optical point-spread. Light is scattered into these four octaves in
    /// linear light *before* exposure, which is what lets an over-exposed
    /// star's halo carry its true colour.
    var psfStrength: Float = 1.0
    /// Scatter fraction per octave — the shape of the PSF wings.
    ///
    /// Heavily weighted toward the NARROW octaves. That is both physically
    /// right (a real PSF is a sharp core with fast-falling wings, not a broad
    /// pedestal) and what makes the effect read: the tight octaves put a
    /// star's light into the pixels immediately around it, which is where the
    /// colour shows. The widest octave is the one that lifts the whole sky off
    /// black, so it stays near zero.
    var psfWeights = SIMD4<Float>(0.260, 0.090, 0.020, 0.003)

    /// Film characteristic curve: K is the exposure rendering as mid-grey
    /// (film speed), N the contrast. N < 1 compresses the several decades
    /// between a galactic nucleus and a tidal tail.
    var filmK: Float = 1.0
    var filmN: Float = 0.85

    /// Warm re-exposure from light scattering off the film base.
    var halation: Float = 0.06

    var fogDensity: Float = 0.0004
    var vignette: Float = 0.15
    var brightness: Float = 4.0
    var saturation: Float = 1.55
    var showBackgroundStars = true
    /// Diagnostics only: disable the wrap fade to A/B the popping.
    var disableWrapFade = false
    /// Camera exposure for the background field, in kpc of arc per unit beta.
    /// This is the shutter time made visible: 0 gives points, larger values
    /// give longer streaks.
    var starExposure: Float = 11
    /// Cosmic-web sky. Deliberately tiny: enough that the sky is not flat
    /// black, and the structure only really emerges if exposure is wound up.
    /// 0 disables it and skips the bake.
/// Very faint. The web is no longer the background — the volumetric star
    /// field is — so this is only here to keep the deep sky from being a flat
    /// black rectangle. At this level it reads as uneven dust, not structure.
    var webStrength: Float = 0.00035
    var web = WebParams()
    var debugParams = false
}

final class Renderer {
    private let ctx: MetalContext
    private let cabinRenderer: CabinRenderer
    private let shipRenderer: ShipRenderer

    private var selectionPipeline: MTLComputePipelineState!
    private var selectedParticlePipeline: MTLRenderPipelineState!
    private var selectedStars: MTLBuffer?
    private var selectionCapacity = 0
    private var selectionArguments: MTLBuffer?
    private var selectionReset: MTLBuffer?
    var selectedParticleIndex: Int?
    private var markerPipeline: MTLRenderPipelineState!
    private var particlePipeline: MTLRenderPipelineState!
    private var downsamplePipeline: MTLRenderPipelineState!
    private var webBakePipeline: MTLRenderPipelineState!
    private var webSkyPipeline: MTLRenderPipelineState!
    private var gridPipeline: MTLRenderPipelineState!
    private var streakPipeline: MTLRenderPipelineState!
    private var webTexture: MTLTexture?
    private var bakedWeb: WebParams?
    private var blurPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!

    private var hdrTexture: MTLTexture!
    /// Four octaves of the point-spread pyramid, at 1/2 .. 1/16 resolution.
    private var psfMip: [MTLTexture] = []
    private var psfTemp: [MTLTexture] = []
    private var currentSize: CGSize = .zero
    private let psfLevels = 4

    private var backgroundBuffer: MTLBuffer!
    private var backgroundCount = 0

    var settings = RenderSettings()
    private(set) var adaptiveSelectionActive = false
    private var fullStarCount = 0
    /// Diagnostics only: read after the frame command buffer has completed.
    var selectedStarCount: Int {
        guard adaptiveSelectionActive, let args = selectionArguments else { return fullStarCount }
        return Int(args.contents().load(as: UInt32.self))
    }

    /// Smallest level of the PSF pyramid — effectively the scene's average
    /// light, already computed. The cockpit samples it to tint its interior,
    /// which is the "fake GI" that makes the canopy feel lit by what is
    /// outside the window rather than pasted on top.
    var ambientTexture: MTLTexture? { psfMip.last }

    /// Diagnostics only. A shared-storage render target defeats lossless
    /// framebuffer compression on Apple Silicon; at Retina resolution that
    /// HDR buffer is ~57 MB written and re-read several times a frame, which
    /// cost roughly 30 ms per frame when it was left on by accident.
    var enableHDRReadback = false {
        didSet { if enableHDRReadback != oldValue { currentSize = .zero } }
    }

    init(ctx: MetalContext, colorFormat: MTLPixelFormat) throws {
        self.ctx = ctx
        cabinRenderer = try CabinRenderer(ctx: ctx, colorFormat: colorFormat)
        shipRenderer = try ShipRenderer(ctx: ctx)
        try buildPipelines(colorFormat: colorFormat)
        let marker = MTLRenderPipelineDescriptor()
        marker.vertexFunction = try ctx.function("explorerMarker")
        marker.fragmentFunction = try ctx.function("explorerMarkerFragment")
        marker.colorAttachments[0].pixelFormat = colorFormat
        marker.colorAttachments[0].isBlendingEnabled = true
        marker.colorAttachments[0].sourceRGBBlendFactor = .one
        marker.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        marker.colorAttachments[0].sourceAlphaBlendFactor = .one
        marker.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        markerPipeline = try ctx.device.makeRenderPipelineState(descriptor: marker)
        buildBackgroundStars()
    }

    private func buildPipelines(colorFormat: MTLPixelFormat) throws {
        // --- particles: additive, no depth, order independent
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = try ctx.function("particleVertex")
        pd.fragmentFunction = try ctx.function("particleFragment")
        pd.colorAttachments[0].pixelFormat = .rgba16Float
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .one
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .one
        particlePipeline = try ctx.device.makeRenderPipelineState(descriptor: pd)
        pd.vertexFunction = try ctx.function("selectedParticleVertex")
        selectedParticlePipeline = try ctx.device.makeRenderPipelineState(descriptor: pd)
        selectionPipeline = try ctx.device.makeComputePipelineState(function: ctx.function("selectVisibleStars"))
        selectionArguments = ctx.device.makeBuffer(length: 16, options: .storageModeShared)
        let emptyDraw: [UInt32] = [0, 1, 0, 0]
        selectionReset = emptyDraw.withUnsafeBytes { bytes in
            ctx.device.makeBuffer(bytes: bytes.baseAddress!, length: 16, options: .storageModeShared)
        }

        // Same additive blend; quads instead of points so a star can be drawn
        // as the line its motion sweeps during the exposure.
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = try ctx.function("starStreakVertex")
        sd.fragmentFunction = try ctx.function("starStreakFragment")
        sd.colorAttachments[0].pixelFormat = .rgba16Float
        sd.colorAttachments[0].isBlendingEnabled = true
        sd.colorAttachments[0].rgbBlendOperation = .add
        sd.colorAttachments[0].alphaBlendOperation = .add
        sd.colorAttachments[0].sourceRGBBlendFactor = .one
        sd.colorAttachments[0].destinationRGBBlendFactor = .one
        sd.colorAttachments[0].sourceAlphaBlendFactor = .one
        sd.colorAttachments[0].destinationAlphaBlendFactor = .one
        streakPipeline = try ctx.device.makeRenderPipelineState(descriptor: sd)

        func fullscreen(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try ctx.function("fullscreenVertex")
            d.fragmentFunction = try ctx.function(fragment)
            d.colorAttachments[0].pixelFormat = format
            return try ctx.device.makeRenderPipelineState(descriptor: d)
        }
        downsamplePipeline = try fullscreen("downsamplePass", .rgba16Float)
        webBakePipeline = try fullscreen("cosmicWebBake", .rgba16Float)
        webSkyPipeline  = try fullscreen("cosmicWebSky", .rgba16Float)

        // The guide is drawn over the scene with normal alpha blending,
        // unlike everything else here which is additive emission.
        let gd = MTLRenderPipelineDescriptor()
        gd.vertexFunction = try ctx.function("fullscreenVertex")
        gd.fragmentFunction = try ctx.function("groundGrid")
        gd.colorAttachments[0].pixelFormat = .rgba16Float
        gd.colorAttachments[0].isBlendingEnabled = true
        gd.colorAttachments[0].rgbBlendOperation = .add
        gd.colorAttachments[0].sourceRGBBlendFactor = .one
        gd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        gd.colorAttachments[0].sourceAlphaBlendFactor = .one
        gd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        gridPipeline = try ctx.device.makeRenderPipelineState(descriptor: gd)
        blurPipeline      = try fullscreen("blurPass", .rgba16Float)
        compositePipeline = try fullscreen("compositePass", colorFormat)
    }

    /// Bake the cosmic web into an equirectangular HDR map.
    ///
    /// The Zel'dovich density needs a full Hessian of the potential, which is
    /// 13 field evaluations per sample, times a ray-march through the slab.
    /// Far too much per frame -- but the sky never changes, so it is paid once
    /// (~0.7 s) and the per-frame cost is a single texture fetch.
    private func bakeWebIfNeeded() {
        guard settings.webStrength > 0 else { return }
        if webTexture != nil, let b = bakedWeb,
           b.a == settings.web.a, b.b == settings.web.b, b.c == settings.web.c { return }

        let w = 2048, h = 1024
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let tex = ctx.device.makeTexture(descriptor: d),
              let cb = ctx.queue.makeCommandBuffer() else { return }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(webBakePipeline)
            var prm = settings.web
            enc.setFragmentBytes(&prm, length: MemoryLayout<WebParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cb.commit(); cb.waitUntilCompleted()
        webTexture = tex
        bakedWeb = settings.web
    }

    /// A fixed shell of faint distant stars. Costs nothing and gives the
    /// scene a sense of depth and scale that an empty black void lacks.
    /// A volumetric field of foreground stars and dust motes.
    ///
    /// The old version was a shell at 4200 kpc — effectively painted on the
    /// sky, so flying produced no parallax and no sense of speed at all. These
    /// live in a cube around the camera and are WRAPPED in the vertex shader
    /// (see `wrapCell` in Render.metal), which makes the field endless from a
    /// finite buffer: fly in any direction forever and stars keep streaming
    /// past. They carry zero mass and never enter the physics.
    private func buildBackgroundStars() {
        backgroundCount = 3600
        var stars = [GPUParticle](repeating: GPUParticle(), count: backgroundCount)
        var state: UInt64 = 0xB5AD4ECE_DA1B2F17

        func rnd() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }

        let cell = Renderer.starCell
        for i in 0..<backgroundCount {
            // Uniform inside the wrap cube. Uniform is what makes the wrapping
            // seamless — any clustering would repeat visibly.
            let pos = SIMD3<Float>(rnd(), rnd(), rnd()) * cell

            // Roughly a fifth are dust motes: dimmer, warmer, larger and
            // softer, so the field has depth instead of being uniform pinpricks.
            let isDust = rnd() < 0.16

            let t = rnd()
            let warm = SIMD3<Float>(1.0, 0.83, 0.62)
            let cool = SIMD3<Float>(0.70, 0.80, 1.0)
            var c = simd_mix(warm, cool, SIMD3(repeating: t))

            var mag: Float
            var size: Float
            if isDust {
                c = simd_mix(c, SIMD3<Float>(0.55, 0.40, 0.33), SIMD3(repeating: 0.55))
                // Small and very dim. Large soft blobs read as dirt on a lens,
                // not as interstellar dust.
                mag = 0.003 + pow(rnd(), 2.8) * 0.013
                size = 26 + rnd() * 36
            } else {
                // steep magnitude distribution: mostly faint, a few bright
                mag = 0.016 + pow(rnd(), 4.8) * 0.52
                size = 11 + rnd() * 17
            }

            stars[i].position = SIMD4(pos, 0)
            stars[i].velocity = .zero
            stars[i].color = SIMD4(c * mag, size)
        }
        backgroundBuffer = ctx.device.makeBuffer(
            bytes: stars,
            length: stars.count * MemoryLayout<GPUParticle>.stride,
            options: .storageModeShared)
    }

    /// Side of the wrap cube, kpc. Large enough that the nearest stars are
    /// tens of kpc away — comparable to the galaxies, so they read as
    /// foreground without crowding the scene.
    static let starCell: Float = 1400

    private func ensureTextures(size: CGSize) {
        guard size != currentSize, size.width > 0, size.height > 0 else { return }
        currentSize = size
        let w = Int(size.width), h = Int(size.height)

        func make(_ w: Int, _ h: Int, shared: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = shared ? .shared : .private
            return ctx.device.makeTexture(descriptor: d)!
        }
        hdrTexture = make(w, h, shared: enableHDRReadback)

        psfMip.removeAll(); psfTemp.removeAll()
        var lw = w, lh = h
        for _ in 0..<psfLevels {
            lw = max(1, lw / 2); lh = max(1, lh / 2)
            psfMip.append(make(lw, lh))
            psfTemp.append(make(lw, lh))
        }
    }

    // MARK: - Drawing

    /// Render one frame into an arbitrary texture. Used both by the live
    /// view and by headless screenshot capture, so what gets evaluated
    /// offscreen is pixel-identical to what the window shows.
    func render(into target: MTLTexture,
                commandBuffer cb: MTLCommandBuffer,
                simulation sim: Simulation,
                camera: Camera,
                viewOverride: (viewProj: float4x4, position: SIMD3<Float>)? = nil,
                relativity: RelativityUniforms = RelativityUniforms(),
                preview: (buffer: MTLBuffer, count: Int)? = nil,
                grid: GridParams? = nil,
                cabin: CabinRenderState? = nil,
                ship: ShipRenderState? = nil,
                backgroundOnly: Bool = false) {
        let size = CGSize(width: target.width, height: target.height)
        ensureTextures(size: size)
        bakeWebIfNeeded()
        guard hdrTexture != nil else { return }

        let aspect = Float(size.width / max(size.height, 1))
        let h = Float(size.height)

        var cam = CameraUniforms()
        cam.viewProj = viewOverride?.viewProj ?? camera.viewProjection(aspect: aspect)
        cam.cameraPos = SIMD4(viewOverride?.position ?? camera.position, 0)
        cam.viewport = SIMD4(Float(size.width), h, 1 / Float(size.width), 1 / h)
        // world size -> pixels for a sprite one unit across at unit distance
        let pointScale = h / (2 * tan(camera.fovY * 0.5)) * settings.starSize * 0.05

        // Additive blending means a core's brightness scales with how many
        // particles land in it. Divide by N so the total emitted light — and
        // therefore the exposure — is the same at 50k and at 2M, and the
        // cores stop clipping to featureless white.
        let reference: Float = 300_000
        let lum = settings.brightness * (reference / Float(max(sim.particleCount, 1)))
        cam.tuning = SIMD4(pointScale, settings.exposure, settings.fogDensity, lum)

        // Keep the original path for small scenes and A/B measurements.
        // Scratch capacity is N, so a camera inside a galaxy cannot overflow
        // when proximity preservation makes the selected count exceed budget.
        var useSelection = false
        let budget = max(1, settings.distantStarBudget)
        if settings.adaptiveStars, !backgroundOnly, sim.particleCount > budget,
           let particles = sim.particleBuffer, let args = selectionArguments {
            if selectionCapacity != sim.particleCount {
                selectedStars = ctx.device.makeBuffer(length: sim.particleCount * 8,
                                                     options: .storageModePrivate)
                selectionCapacity = selectedStars == nil ? 0 : sim.particleCount
            }
            if let selected = selectedStars, let reset = selectionReset {
                // GPU-side reset is ordered with previous in-flight frames;
                // CPU writes to one shared argument buffer would race them.
                if let blit = cb.makeBlitCommandEncoder() {
                    blit.copy(from: reset, sourceOffset: 0, to: args, destinationOffset: 0, size: 16)
                    blit.endEncoding()
                }
                if let compute = cb.makeComputeCommandEncoder() {
                    var lod = StarLODParams(count: UInt32(sim.particleCount),
                                            fraction: Float(budget) / Float(sim.particleCount))
                    var selectionRel = relativity
                    compute.setComputePipelineState(selectionPipeline)
                    compute.setBuffer(particles, offset: 0, index: 0)
                    compute.setBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 1)
                    compute.setBytes(&selectionRel, length: MemoryLayout<RelativityUniforms>.stride, index: 2)
                    compute.setBytes(&lod, length: MemoryLayout<StarLODParams>.stride, index: 3)
                    compute.setBuffer(selected, offset: 0, index: 4)
                    compute.setBuffer(args, offset: 0, index: 5)
                    let width = min(256, selectionPipeline.maxTotalThreadsPerThreadgroup)
                    compute.dispatchThreadgroups(MTLSize(width: (sim.particleCount + width - 1) / width, height: 1, depth: 1),
                                                 threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                    compute.endEncoding()
                    useSelection = true
                }
            }
        } else if selectedStars != nil {
            // Returning to a small scene should release large-scene scratch.
            // In-flight command buffers retain any resources they still use.
            selectedStars = nil
            selectionCapacity = 0
        }

        adaptiveSelectionActive = useSelection
        fullStarCount = backgroundOnly ? 0 : sim.particleCount

        // ---- pass 1: particles into HDR, additive
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdrTexture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.0016, green: 0.0020,
                                                          blue: 0.0048, alpha: 1)
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            // Sky first, opaque, in the same encoder so it replaces the clear
            // instead of costing an extra load/store. Landing it in the HDR
            // buffer means it goes through the PSF and the film curve with
            // everything else.
            if settings.webStrength > 0, let skyTex = webTexture {
                var sky = SkyParams()
                sky.invViewProj = cam.viewProj.inverse
                sky.params = SIMD4(settings.webStrength, 0, 0, 0)
                var skyRel = relativity
                enc.setRenderPipelineState(webSkyPipeline)
                enc.setFragmentTexture(skyTex, index: 0)
                enc.setFragmentBytes(&sky, length: MemoryLayout<SkyParams>.stride, index: 0)
                enc.setFragmentBytes(&skyRel,
                                     length: MemoryLayout<RelativityUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            // Ground guide first: it is an alpha-blended surface, and the
            // galaxies are additive emission on top of it. Drawn after them it
            // would darken every star it crossed.
            if var g = grid, g.camPos.w > 0 {
                g.invViewProj = cam.viewProj.inverse
                enc.setRenderPipelineState(gridPipeline)
                enc.setFragmentBytes(&g, length: MemoryLayout<GridParams>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            enc.setRenderPipelineState(particlePipeline)
            enc.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 1)

            var rel = relativity
            enc.setVertexBytes(&rel, length: MemoryLayout<RelativityUniforms>.stride, index: 2)

            if settings.showBackgroundStars, let bg = backgroundBuffer {
                var bgCam = cam
                bgCam.tuning.w = settings.brightness      // fixed count, no 1/N
                bgCam.extra.x = Renderer.starCell         // endless wrapped field
                bgCam.extra.y = settings.disableWrapFade ? 1 : 0
                bgCam.extra.z = settings.starExposure
                enc.setVertexBytes(&bgCam, length: MemoryLayout<CameraUniforms>.stride, index: 1)
                enc.setVertexBuffer(bg, offset: 0, index: 0)
                // One path for both cases: at beta = 0 the streak length is
                // zero and the quad renders as the same round sprite.
                enc.setRenderPipelineState(streakPipeline)
                enc.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: backgroundCount * 6)
                enc.setRenderPipelineState(particlePipeline)
                enc.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            }
            if !backgroundOnly, let pb = sim.particleBuffer, sim.particleCount > 0 {
                enc.setVertexBuffer(pb, offset: 0, index: 0)
                if useSelection, let selected = selectedStars, let args = selectionArguments {
                    enc.setRenderPipelineState(selectedParticlePipeline)
                    enc.setVertexBuffer(selected, offset: 0, index: 3)
                    enc.drawPrimitives(type: .point, indirectBuffer: args, indirectBufferOffset: 0)
                    enc.setRenderPipelineState(particlePipeline)
                } else {
                    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: sim.particleCount)
                }
            }

            // Ghost of the galaxy about to be placed. Dimmed and drawn with a
            // fixed per-particle weight (it has its own small count, so the
            // scene's 1/N normalisation would make it far too bright).
            if let pv = preview, pv.count > 0 {
                var ghostCam = cam
                ghostCam.tuning.w = settings.brightness
                    * (Float(reference) / Float(max(pv.count, 1))) * 0.30
                enc.setVertexBytes(&ghostCam, length: MemoryLayout<CameraUniforms>.stride, index: 1)
                enc.setVertexBuffer(pv.buffer, offset: 0, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pv.count)
                enc.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            }
            enc.endEncoding()
        }

        if let ship {
            shipRenderer.draw(into: hdrTexture, commandBuffer: cb, state: ship)
        }

        func fullscreenPass(_ pipeline: MTLRenderPipelineState,
                            to dst: MTLTexture,
                            textures: [MTLTexture],
                            bytes: UnsafeRawPointer, length: Int) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = dst
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: d) else { return }
            enc.setRenderPipelineState(pipeline)
            for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentBytes(bytes, length: length, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ---- passes 2..N: build the point-spread pyramid.
        //
        // No brightness threshold here, deliberately. A lens scatters *all*
        // the light it receives, not just the parts above some cutoff; the
        // threshold in a conventional bloom is an efficiency hack that also
        // throws away exactly the faint chromatic halo we are trying to
        // reproduce. Each octave is a box downsample followed by a separable
        // gaussian, so together they approximate the broad wings of a real PSF.
        for level in 0..<psfLevels {
            let src = (level == 0) ? hdrTexture! : psfMip[level - 1]
            let dst = psfMip[level]
            let tmp = psfTemp[level]

            var texel = SIMD2<Float>(1.0 / Float(src.width), 1.0 / Float(src.height))
            fullscreenPass(downsamplePipeline, to: dst, textures: [src],
                           bytes: &texel, length: MemoryLayout<SIMD2<Float>>.stride)

            let bw = Float(dst.width), bh = Float(dst.height)
            var dirH = SIMD2<Float>(1.0 / bw, 0)
            fullscreenPass(blurPipeline, to: tmp, textures: [dst],
                           bytes: &dirH, length: MemoryLayout<SIMD2<Float>>.stride)
            var dirV = SIMD2<Float>(0, 1.0 / bh)
            fullscreenPass(blurPipeline, to: dst, textures: [tmp],
                           bytes: &dirV, length: MemoryLayout<SIMD2<Float>>.stride)
        }

        // ---- final: spread + expose + develop
        var p = SensorParams(
            a: SIMD4(settings.exposure, settings.filmK, settings.filmN, settings.psfStrength),
            b: settings.psfWeights,
            c: SIMD4(settings.vignette, settings.saturation, settings.halation, 0))
        fullscreenPass(compositePipeline, to: target,
                       textures: [hdrTexture, psfMip[0], psfMip[1], psfMip[2], psfMip[3]],
                       bytes: &p, length: MemoryLayout<SensorParams>.stride)
        if let cabin {
            cabinRenderer.draw(into: target, commandBuffer: cb, state: cabin,
                               exterior: hdrTexture, blurredExterior: psfMip[0], sensor: p)
        }
        // Reticle follows the current GPU position, after this frame's physics.
        // Composite after exposure so a bright star cannot wash the marker out.
        if !backgroundOnly, let selected = selectedParticleIndex,
           selected >= 0, selected < sim.particleCount {
            let markerPass = MTLRenderPassDescriptor()
            markerPass.colorAttachments[0].texture = target
            markerPass.colorAttachments[0].loadAction = .load
            markerPass.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: markerPass) {
                var rel = relativity, index = UInt32(selected)
                enc.setRenderPipelineState(markerPipeline)
                enc.setVertexBuffer(sim.particleBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 1)
                enc.setVertexBytes(&rel, length: MemoryLayout<RelativityUniforms>.stride, index: 2)
                enc.setVertexBytes(&index, length: 4, index: 3)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
                enc.endEncoding()
            }
        }
    }

    func draw(in view: MTKView,
              commandBuffer cb: MTLCommandBuffer,
              simulation sim: Simulation,
              camera: Camera,
              viewOverride: (viewProj: float4x4, position: SIMD3<Float>)? = nil,
              relativity: RelativityUniforms = RelativityUniforms(),
              preview: (buffer: MTLBuffer, count: Int)? = nil,
              grid: GridParams? = nil,
                cabin: CabinRenderState? = nil,
                ship: ShipRenderState? = nil) {
        guard let drawable = view.currentDrawable else { return }
        render(into: drawable.texture, commandBuffer: cb, simulation: sim,
               camera: camera, viewOverride: viewOverride, relativity: relativity,
               preview: preview, grid: grid, cabin: cabin, ship: ship)
        cb.present(drawable)
    }
}


// MARK: - Look diagnostics

extension Renderer {
    /// Luminance percentiles of the raw HDR buffer, before bloom or
    /// tonemapping. This is what the stretch has to map into 0...1, so it is
    /// the number that decides every other look parameter.
    func hdrLuminanceReport() -> String {
        guard let t = hdrTexture, t.storageMode == .shared else { return "hdr not readable" }
        let w = t.width, h = t.height
        var buf = [UInt16](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            t.getBytes(p.baseAddress!, bytesPerRow: w * 8,
                       from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var lum: [Float] = []
        lum.reserveCapacity(w * h)
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = Float(Float16(bitPattern: buf[i]))
            let g = Float(Float16(bitPattern: buf[i + 1]))
            let b = Float(Float16(bitPattern: buf[i + 2]))
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if l.isFinite { lum.append(l) }
        }
        lum.sort()
        func p(_ f: Double) -> Float {
            lum.isEmpty ? 0 : lum[min(lum.count - 1, Int(Double(lum.count) * f))]
        }
        return String(format:
            "HDR luminance  p50=%.4f  p90=%.3f  p99=%.2f  p99.9=%.1f  max=%.1f",
            p(0.5), p(0.9), p(0.99), p(0.999), lum.last ?? 0)
    }
}

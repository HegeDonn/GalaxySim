import Metal
import simd
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Everything the simulator needs, independent of any window.
/// The GUI drives this, and so does headless screenshot capture — which
/// means what I evaluate offscreen is exactly what the window shows.
final class SimHost {
    let ctx: MetalContext
    let sim: Simulation
    let renderer: Renderer
    let camera = Camera()

    var customSpecs: [GalaxySpec] = []

    private(set) var previewBuffer: MTLBuffer?
    private(set) var previewCount = 0
    private(set) var previewActive = false
    fileprivate var previewKey = ""
    fileprivate var previewSeeds: [ParticleSeed] = []
    private(set) var scenes: [Scene]
    private(set) var sceneIndex = 0
    var particleBudget: Int

    /// Rolling average of GPU time for one physics step, in milliseconds.
    private(set) var stepMillis: Double = 0
    private var stepSamples: [Double] = []

    init(budget: Int, colorFormat: MTLPixelFormat = .bgra8Unorm) throws {
        ctx = try MetalContext()
        sim = try Simulation(ctx: ctx)
        renderer = try Renderer(ctx: ctx, colorFormat: colorFormat)
        particleBudget = budget
        scenes = Presets.all(budget: budget)
        loadScene(0)
    }

    func loadScene(_ index: Int) {
        sceneIndex = max(0, min(index, scenes.count - 1))
        let s = scenes[sceneIndex]
        sim.load(s)
        camera.target = .zero
        camera.distance = s.cameraDistance
        camera.azimuth = s.cameraAzimuth
        camera.elevation = s.cameraElevation
        stepSamples.removeAll()
    }

    func rebuildScenes(budget: Int) {
        particleBudget = budget
        scenes = Presets.all(budget: budget)
        loadScene(sceneIndex)
    }

    /// Run `steps` physics steps, blocking until the GPU has finished.
    func advance(steps: Int, measure: Bool = false) {
        guard steps > 0 else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<steps {
            guard let cb = ctx.queue.makeCommandBuffer() else { return }
            sim.step(commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        if measure {
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(steps)
            stepSamples.append(ms)
            if stepSamples.count > 30 { stepSamples.removeFirst() }
            stepMillis = stepSamples.reduce(0, +) / Double(stepSamples.count)
        }
    }

    // MARK: - Offscreen capture

    func makeCaptureTexture(_ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return ctx.device.makeTexture(descriptor: d)
    }

    /// Re-frame the camera on the current particle cloud.
    func reframe(immediate: Bool = false) {
        let e = sim.sampleExtent()
        camera.frame(center: e.center, radius: e.radius)
        if immediate {
            // Converge the smoothing so a captured still is correctly framed.
            // The dolly eases at 1 - exp(-dt * 1.1), which is about 1.8% per
            // frame at 60 Hz: 120 frames closes only 89% of the gap, so a
            // still taken right after a scene change kept most of the
            // previous scene's zoom. One update with a large dt lands on the
            // target exactly, which is what "immediate" was always meant
            // to mean.
            camera.update(dt: 30)
        }
    }

    @discardableResult
    func capture(width: Int, height: Int, to path: String,
                 grid: GridParams? = nil) throws -> Bool {
        guard let tex = makeCaptureTexture(width, height),
              let cb = ctx.queue.makeCommandBuffer() else { return false }

        reframe(immediate: true)
        var ghost: (buffer: MTLBuffer, count: Int)? = nil
        if previewActive, let pb = previewBuffer, previewCount > 0 {
            ghost = (pb, previewCount)
        }
        renderer.render(into: tex, commandBuffer: cb, simulation: sim,
                        camera: camera, preview: ghost, grid: grid)
        cb.commit()
        cb.waitUntilCompleted()

        let bytesPerRow = width * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * height)
        raw.withUnsafeMutableBytes { p in
            tex.getBytes(p.baseAddress!, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        // BGRA -> RGBA
        for i in stride(from: 0, to: raw.count, by: 4) {
            raw.swapAt(i, i + 2)
        }

        guard let provider = CGDataProvider(data: Data(raw) as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let img = CGImage(width: width, height: height,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: bytesPerRow, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)
        else { return false }

        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Write an already-rendered shared-storage texture to a PNG.
    @discardableResult
    func saveTexture(_ tex: MTLTexture, to path: String) throws -> Bool {
        let w = tex.width, h = tex.height
        let bytesPerRow = w * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * h)
        raw.withUnsafeMutableBytes { p in
            tex.getBytes(p.baseAddress!, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        for i in stride(from: 0, to: raw.count, by: 4) { raw.swapAt(i, i + 2) }
        guard let provider = CGDataProvider(data: Data(raw) as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: bytesPerRow, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Diagnostics used by the self-evaluation harness.
    func statistics() -> String {
        var sep = "-"
        if sim.cores.count > 1 {
            sep = String(format: "%.1f kpc",
                         simd_length(sim.cores[0].position - sim.cores[1].position))
        }
        return String(format: "t=%.0f Myr  N=%d  sep=%@  step=%.2f ms  intensity=%.2f",
                      sim.currentTime, sim.particleCount, sep, stepMillis,
                      Double(sim.intensityValue))
    }
}

extension Simulation {
    var intensityValue: Float { intensity }
    var dispersalValue: Float { dispersal }
}

// MARK: - Diagnostics

extension SimHost {
    /// Structural and orbital report used to sanity-check the physics.
    func diagnose(until endTime: Float) {
        let stridePrint: Float = 50

        func radii(ofGalaxy g: Int) -> [Float] {
            let p = sim.particleBuffer.contents()
                .bindMemory(to: GPUParticle.self, capacity: sim.particleCount)
            let aux = sim.auxBuffer.contents()
                .bindMemory(to: UInt32.self, capacity: sim.particleCount)
            let centre = sim.cores[g].position
            var out: [Float] = []
            var i = 0
            while i < sim.particleCount {
                if Int(aux[i] >> 8) == g {
                    let v = p[i].position
                    out.append(simd_length(SIMD3(v.x, v.y, v.z) - centre))
                }
                i += 1
            }
            return out.sorted()
        }

        func pct(_ a: [Float], _ f: Float) -> Float {
            a.isEmpty ? 0 : a[min(a.count - 1, Int(Float(a.count) * f))]
        }

        print("\n--- structure at t=0 ---")
        for g in sim.cores.indices {
            let r = radii(ofGalaxy: g)
            let pot = sim.cores[g].potential
            print(String(format:
                "galaxy %d: N=%6d  r50=%5.1f  r90=%5.1f  r99=%5.1f kpc   "
                + "Mtot=%.2f (halo %.2f/a=%.0f, disk %.2f/a=%.1f, bulge %.2f)",
                g, r.count, pct(r, 0.5), pct(r, 0.9), pct(r, 0.99),
                pot.totalMass, pot.haloMass, pot.haloScale,
                pot.diskMass, pot.diskA, pot.bulgeMass))
        }

        print("\n--- orbit ---")
        // fraction of a galaxy's stars flung beyond 35 kpc — the tidal-tail signal
        func tailFraction(_ g: Int) -> Float {
            let r = radii(ofGalaxy: g)
            guard !r.isEmpty else { return 0 }
            return Float(r.filter { $0 > 35 }.count) / Float(r.count)
        }
        print("   t(Myr)   sep(kpc)   relv(km/s)   r90_g0   r99_g0   tail%_g0  tail%_g1")
        var nextPrint: Float = 0
        var minSep: Float = .greatestFiniteMagnitude
        var minSepTime: Float = 0

        while sim.currentTime < endTime {
            advance(steps: 10)
            if sim.cores.count > 1 {
                let sep = simd_length(sim.cores[0].position - sim.cores[1].position)
                if sep < minSep { minSep = sep; minSepTime = sim.currentTime }
            }
            if sim.currentTime >= nextPrint {
                nextPrint += stridePrint
                let sep = sim.cores.count > 1
                    ? simd_length(sim.cores[0].position - sim.cores[1].position) : 0
                let rv = sim.cores.count > 1
                    ? simd_length(sim.cores[0].velocity - sim.cores[1].velocity) : 0
                let r0 = pct(radii(ofGalaxy: 0), 0.9)
                let r1 = sim.cores.count > 1 ? pct(radii(ofGalaxy: 1), 0.9) : 0
                let r99 = pct(radii(ofGalaxy: 0), 0.99)
                _ = r1
                print(String(format: "  %7.0f   %8.1f   %10.0f   %6.1f   %6.1f   %7.1f%%  %7.1f%%",
                             sim.currentTime, sep, Units.kms(rv), r0, r99,
                             tailFraction(0) * 100,
                             sim.cores.count > 1 ? tailFraction(1) * 100 : 0))
            }
        }
        print(String(format: "\npericentre: %.1f kpc at t=%.0f Myr", minSep, minSepTime))
    }
}

// MARK: - Hand-built scenes

extension SimHost {
    /// Galaxies the user has placed by clicking. Rebuilding the scene on every
    /// change means placed galaxies appear immediately (paused) rather than
    /// as abstract markers — you see what you are composing.
    /// Drop a galaxy into whatever is already running.
    ///
    /// Placing used to rebuild the scene from the placed specs alone, which
    /// silently deleted the preset you were watching along with every tail it
    /// had grown. Galaxies are now inserted into the live simulation, so you
    /// can keep adding to a running encounter and clear only when you mean to.
    func addGalaxy(type: GalaxyType, massScale: Float, tiltDegrees: Float, rollDegrees: Float? = nil,
                   at position: SIMD3<Float>) {
        let n = sim.cores.count
        let spin = Presets.tilt(tiltDegrees, roll: rollDegrees ?? Float(n) * 47)
        var spec = Presets.spec(type, perGalaxyBudget(), mass: massScale, spin: spin,
                                seed: 0xC0FFEE &+ UInt64(n &* 7919))
        spec.position = position
        spec.velocity = .zero
        customSpecs.append(spec)
        sim.insertGalaxy(spec)
    }

    /// Particle count for a newly placed galaxy: share the budget with what is
    /// already there, with a floor so a late addition is still visible.
    private func perGalaxyBudget() -> Int {
        let existing = max(sim.cores.count, 1)
        return max(25_000, particleBudget / (existing + 1))
    }

    func clearCustom() {
        customSpecs.removeAll()
        clearPreview()
        loadScene(sceneIndex)
    }

    /// Give the two most massive placed galaxies a proper encounter orbit;
    /// anything else stays where it was put.
    /// Put the two most massive galaxies on a proper encounter orbit, in
    /// place. Operates on the LIVE cores so it works on a running scene,
    /// whether those galaxies came from a preset or were just placed.
    func autoOrbitCustom() {
        guard sim.cores.count >= 2 else { return }
        let order = sim.cores.indices.sorted { sim.cores[$0].mass > sim.cores[$1].mass }
        let i = order[0], j = order[1]
        let a = sim.cores[i], b = sim.cores[j]
        let relPos = a.position - b.position
        let sep = simd_length(relPos)
        guard sep > 1 else { return }

        let relVel = Presets.encounterVelocity(
            potA: a.potential, potB: b.potential,
            spinA: a.spinAxis, spinB: b.spinAxis,
            relPos: relPos, pericenter: max(5, sep * 0.08))

        let ma = a.mass, mb = b.mass
        let total = max(ma + mb, 1e-6)
        sim.setCoreVelocity(i, relVel * (mb / total))
        sim.setCoreVelocity(j, -relVel * (ma / total))
    }

    func rebuildCustom() {
        guard !customSpecs.isEmpty else { return }
        var specs = customSpecs
        let per = max(15_000, particleBudget / specs.count)
        for k in specs.indices { specs[k].particleCount = per }
        let extent = specs.map { simd_length($0.position) }.max() ?? 100
        sim.load(Scene(name: "Custom build", specs: specs,
                       cameraDistance: max(120, extent * 2.4)))
        sim.isPaused = true
        camera.autoFrame = true
        reframe()
    }

    var customDescription: String {
        guard !customSpecs.isEmpty else { return "no galaxies placed" }
        return customSpecs.enumerated().map { i, s in
            String(format: "%d. %@ m=%.2f @(%.0f, %.0f)",
                   i + 1, s.type.rawValue, s.massScale, s.position.x, s.position.z)
        }.joined(separator: "\n")
    }
}

// MARK: - Placement preview

extension SimHost {
    /// A faint ghost of the galaxy about to be dropped, drawn at the cursor.
    ///
    /// Rendered from the real generator rather than a sprite, so what you see
    /// under the cursor is genuinely the galaxy you are about to place —
    /// including its tilt. Kept at a low particle count because it is
    /// regenerated whenever type or tilt changes.
    func updatePreview(type: GalaxyType, tiltDegrees: Float, rollDegrees: Float = 0, at position: SIMD3<Float>) {
        let key = "\(type.rawValue)|\(Int(tiltDegrees.rounded()))|\(Int(rollDegrees.rounded()))"
        if key != previewKey {
            previewKey = key
            var spec = Presets.spec(type, SimHost.previewParticles,
                                    mass: 1.0,
                                    spin: Presets.tilt(tiltDegrees, roll: rollDegrees),
                                    seed: 0x5EED_1234)
            spec.position = .zero
            spec.velocity = .zero
            previewSeeds = GalaxyModels.generate(spec)
            if previewBuffer == nil || previewCount != previewSeeds.count {
                previewCount = previewSeeds.count
                previewBuffer = ctx.device.makeBuffer(
                    length: max(previewCount, 1) * MemoryLayout<GPUParticle>.stride,
                    options: .storageModeShared)
            }
        }
        guard let buf = previewBuffer, previewCount > 0 else { return }
        let p = buf.contents().bindMemory(to: GPUParticle.self, capacity: previewCount)
        for (i, s) in previewSeeds.enumerated() {
            p[i].position = SIMD4(s.position + position, 0)
            p[i].velocity = .zero
            p[i].color    = SIMD4(s.color, s.size)
        }
        previewActive = true
    }

    func clearPreview() { previewActive = false }

    static let previewParticles = 16000
}

import Foundation
import Metal
import simd

/// Reproducible numerical and end-to-end measurements; no saved user settings.
func runPerformanceDiagnostics(host: SimHost, output: String, width: Int, height: Int) throws {
    let ctx = host.ctx
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PerformanceDiagnostics", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    print("device: \(ctx.device.name), RAM: \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MiB, max buffer: \(ctx.device.maxBufferLength / 1_048_576) MiB")
    print("live particle/aux memory: \(host.sim.particleCount * 52 / 1_048_576) MiB; rewind memory: 0")

    let fused = try Simulation(ctx: ctx)
    let split = try Simulation(ctx: ctx)
    split.useFusedRestricted = false
    let scene = Presets.all(budget: 4097)[0]
    try require(fused.load(scene) && split.load(scene), "Test scene allocation failed")
    for step in 1...128 {
        let cb = ctx.queue.makeCommandBuffer()!
        fused.step(commandBuffer: cb)
        split.step(commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        try require(cb.status == .completed, "Physics GPU command failed: \(String(describing: cb.error))")
        if step == 1 || step == 128 {
            let a = fused.particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: fused.particleCount)
            let b = split.particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: split.particleCount)
            var maxP: Float = 0, maxV: Float = 0, maxT: Float = 0
            for i in 0..<fused.particleCount {
                let dp = simd_length(SIMD3(a[i].position.x - b[i].position.x,
                                           a[i].position.y - b[i].position.y,
                                           a[i].position.z - b[i].position.z))
                let dv = simd_length(SIMD3(a[i].velocity.x - b[i].velocity.x,
                                           a[i].velocity.y - b[i].velocity.y,
                                           a[i].velocity.z - b[i].velocity.z))
                try require(dp.isFinite && dv.isFinite, "Non-finite particle \(i)")
                try require(a[i].color == b[i].color && a[i].position.w == b[i].position.w,
                            "Immutable appearance or mass changed")
                maxP = max(maxP, dp); maxV = max(maxV, dv)
                maxT = max(maxT, abs(a[i].velocity.w - b[i].velocity.w))
            }
            print(String(format: "fused vs split, step %d: max position %.8g kpc, velocity %.8g kpc/Myr, burst %.8g", step, maxP, maxV, maxT))
            try require(maxP < (step == 1 ? 0.0001 : 0.02) && maxV < 0.01 && maxT < 0.01,
                        "Fused/reference integration mismatch")
        }
    }
    print("PASS: fused integrator, finite state, unchanged mass/appearance")

    // All synthetic stars are within the exact-retention radius. Sampling
    // budget=1 forces the selection path; every visible star must still survive,
    // including sources initially behind the camera bent forward by aberration.
    let savedSettings = host.renderer.settings
    host.renderer.settings.showBackgroundStars = false
    host.renderer.settings.webStrength = 0
    host.renderer.settings.distantStarBudget = 1
    let smallTarget = host.makeCaptureTexture(512, 320)!
    let pp = fused.particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: fused.particleCount)
    var rng = GalaxyModels.RNG(seed: 777)
    for i in 0..<fused.particleCount {
        let z = rng.uniform(-1, 1), a = rng.uniform(0, 2 * .pi)
        let r = sqrt(max(0, 1 - z * z))
        pp[i].position = SIMD4(SIMD3(r * cos(a), r * sin(a), z) * rng.uniform(2, 8), pp[i].position.w)
        pp[i].velocity.w = 0
    }
    let vp = perspectiveMatrix(fovY: 50 * .pi / 180, aspect: 1.6, near: 0.1, far: 1000)
    func pixels(_ texture: MTLTexture) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        data.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return data
    }
    for beta: Float in [0, 0.99, 0.9999] {
        var rel = RelativityUniforms()
        rel.params.x = 1
        rel.boost = SIMD4(0, 0, -1, beta)
        var reference: [UInt8] = []
        for enabled in [false, true] {
            host.renderer.settings.adaptiveStars = enabled
            let cb = ctx.queue.makeCommandBuffer()!
            host.renderer.render(into: smallTarget, commandBuffer: cb,
                                 simulation: fused, camera: host.camera,
                                 viewOverride: (vp, .zero), relativity: rel)
            cb.commit(); cb.waitUntilCompleted()
            try require(cb.status == .completed, "Near/warp GPU command failed")
            let image = pixels(smallTarget)
            if !enabled { reference = image } else {
                let maxError = zip(image, reference).map { abs(Int($0) - Int($1)) }.max() ?? 0
                print("near-star/culling beta=\(beta): max image channel error \(maxError)/255, selected \(host.renderer.selectedStarCount)")
                try require(maxError <= 4, "Near stars lost or incorrectly culled during warp")
            }
            try host.saveTexture(smallTarget, to: "\(output)/near_beta_\(beta)_\(enabled ? "adaptive" : "full").png")
        }
    }
    host.renderer.settings = savedSettings
    print("PASS: nearby stars retained and aberration-aware visibility at beta 0, .99, .9999")

    host.renderer.enableHDRReadback = false
    host.reframe(immediate: true)
    let target = host.makeCaptureTexture(width, height)!
    func frame(steps: Int) throws -> Double {
        let cb = ctx.queue.makeCommandBuffer()!
        for _ in 0..<steps { host.sim.step(commandBuffer: cb) }
        host.renderer.render(into: target, commandBuffer: cb,
                             simulation: host.sim, camera: host.camera)
        let start = CFAbsoluteTimeGetCurrent()
        cb.commit(); cb.waitUntilCompleted()
        try require(cb.status == .completed, "Frame GPU command failed: \(String(describing: cb.error))")
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
    for enabled in [false, true] {
        host.renderer.settings.adaptiveStars = enabled
        for _ in 0..<3 { _ = try frame(steps: 0) }
        var samples: [Double] = []
        for _ in 0..<20 { samples.append(try frame(steps: 0)) }
        samples.sort()
        print(String(format: "%@ render: median %.2f ms, p95 %.2f ms, selected %d / %d",
                     enabled ? "adaptive" : "full", samples[10], samples[18],
                     enabled && host.renderer.adaptiveSelectionActive ? host.renderer.selectedStarCount : host.sim.particleCount,
                     host.sim.particleCount))
        try host.saveTexture(target, to: "\(output)/\(enabled ? "adaptive" : "full").png")
    }
    for _ in 0..<3 { _ = try frame(steps: 2) }
    var combined: [Double] = []
    for _ in 0..<20 { combined.append(try frame(steps: 2)) }
    combined.sort()
    print(String(format: "combined 2 physics steps + adaptive render: median %.2f ms, p95 %.2f ms (%.1f fps equivalent)", combined[10], combined[18], 1000 / combined[10]))
    print("Short offscreen timings exclude GUI, display synchronization and sustained thermal throttling.")
}

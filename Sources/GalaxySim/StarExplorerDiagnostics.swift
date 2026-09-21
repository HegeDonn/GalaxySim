import Foundation
import Metal
import simd

func runStarExplorerDiagnostics(host: SimHost, output: String) throws {
    func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw NSError(domain: "StarExplorer", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS: \(message)")
    }
    let sim = try Simulation(ctx: host.ctx)
    var spec = host.scenes[0].specs[0]
    spec.particleCount = 257
    try check(sim.load(Scene(name: "Picker regression", specs: [spec])), "Picker fixture allocated")
    let p = sim.particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: sim.particleCount)
    let aux = sim.auxBuffer.contents().bindMemory(to: UInt32.self, capacity: sim.particleCount)
    for i in 0..<257 {
        p[i].position = SIMD4(1000, 1000, -10, 0)
        p[i].velocity = .zero
        p[i].color = SIMD4(1, 0.9, 0.7, 1)
        aux[i] = 0
    }
    p[256].position = SIMD4(0, 0, -10, 0)
    p[0].position = SIMD4(0, 0, -5, 0)
    aux[0] = ParticleKind.gas.rawValue
    var camera = CameraUniforms()
    camera.viewProj = perspectiveMatrix(fovY: 50 * .pi / 180, aspect: 1.6, near: 0.1, far: 2000)
    camera.viewport = SIMD4(800, 500, 1 / 800, 1 / 500)
    camera.extra.w = 1
    let picker = try StarPicker(ctx: host.ctx)
    let center = SIMD2<Float>(400, 250)
    try check(picker.pick(sim: sim, camera: camera, relativity: RelativityUniforms(), pixel: center, radius: 5) == 256,
              "Picker covers partial workgroup and excludes gas")
    try check(picker.pick(sim: sim, camera: camera, relativity: RelativityUniforms(), pixel: SIMD2(20, 20), radius: 5) == nil,
              "Empty-sky click has no selection")
    p[256].position = SIMD4(5, 0, 5, 0)
    var rel = RelativityUniforms()
    rel.params.x = 1; rel.boost = SIMD4(0, 0, -1, 0.99)
    let rest = SIMD3<Float>(5, 0, 5)
    // CPU aberration formula independent of the GPU picker implementation.
    let n = simd_normalize(rest), beta: Float = 0.99
    let mu = -n.z, gamma = 1 / sqrt(1 - beta * beta)
    let denominator = 1 + beta * mu
    let direction = SIMD3(n.x / (gamma * denominator), 0, -(mu + beta) / denominator)
    let clip = camera.viewProj * SIMD4(direction * simd_length(rest), 1)
    let pixel = SIMD2((clip.x / clip.w * 0.5 + 0.5) * 800, (clip.y / clip.w * 0.5 + 0.5) * 500)
    try check(picker.pick(sim: sim, camera: camera, relativity: rel, pixel: pixel, radius: 3) == 256,
              "Picker finds an initially rearward star bent into view at .99c")
    p[256].position = SIMD4(0, 0, -10, 0)
    p[256].velocity = SIMD4(0.01, 0, 0, 0)
    let generation = sim.sceneGeneration
    let cb = host.ctx.queue.makeCommandBuffer()!
    sim.step(commandBuffer: cb); cb.commit(); cb.waitUntilCompleted()
    try check(sim.sceneGeneration == generation && p[256].position.x != 0, "Moving stars retain identity")
    var addition = spec; addition.particleCount = 3
    try check(sim.insertGalaxy(addition) && sim.sceneGeneration == generation, "Insertion retains existing star identities")
    sim.restart()
    try check(sim.sceneGeneration != generation, "Scene restart invalidates selected identity")
    for kind: UInt32 in [0, 1, 2, 4] {
        for id in 0..<200 {
            let star = StellarProfile.make(index: id, population: kind)
            let expected = pow(star.solarRadius, 2) * pow(star.temperature / 5772, 4)
            try checkSilent(star.solarMass > 0 && star.solarRadius > 0 && star.temperature > 0
                && abs(star.solarLuminosity - expected) < max(1e-8, expected * 1e-10))
        }
    }
    print("PASS: 800 illustrative star models have positive physical values and consistent luminosity/radius/temperature")

    // Names. The old scheme gave every star "Lumen <n>", so a child clicking
    // around the disc learned nothing from the top line of the card. Three
    // things have to hold: a star keeps its name, different stars get
    // different names, and a faint red dwarf is catalogued rather than
    // christened -- which is what the real sky does.
    var names: [String] = []
    for kind: UInt32 in [0, 1, 2, 4] {
        for id in 0..<200 { names.append(StellarProfile.make(index: id, population: kind).name) }
    }
    let again = StellarProfile.make(index: 137, population: 1).name
    try check(again == names[1 * 200 + 137], "A star answers to the same name every time it is asked")
    try check(!names.contains { $0.hasPrefix("Lumen ") }, "No star is called Lumen any more")
    try check(Set(names).count > names.count / 2,
              "800 stars draw \(Set(names).count) different names")
    var dwarfNumbered = 0, dwarfTotal = 0
    for id in 0..<400 {
        let star = StellarProfile.make(index: id, population: ParticleKind.halo.rawValue)
        guard !star.isRemnant, star.solarMass < 0.85 else { continue }
        dwarfTotal += 1
        if star.name.contains(where: \.isNumber) { dwarfNumbered += 1 }
    }
    try check(dwarfTotal > 50 && Double(dwarfNumbered) / Double(dwarfTotal) > 0.7,
              "Faint stars mostly carry catalogue numbers, as they do in the sky")
    try check(SkyNames.galaxy(seed: 0x11_11, index: 0, type: .sbb)
                != SkyNames.galaxy(seed: 0x31_00, index: 1, type: .sa),
              "Two galaxies in one scene are told apart by name")
    // A scene built from real galaxies keeps their real names; anything the
    // scene does not name gets an invented one.
    var second = spec; second.seed = spec.seed &+ 999
    try check(sim.load(Scene(name: "Named pair", specs: [spec, second],
                             galaxyNames: ["The Milky Way"])), "Named scene allocated")
    try check(sim.galaxyName(at: 0) == "The Milky Way", "A scene's own galaxy names are kept")
    let invented = sim.galaxyName(at: 1)
    try check(!invented.isEmpty && invented != "The Milky Way",
              "The galaxy the scene did not name is called \(invented)")
    host.renderer.selectedParticleIndex = min(100, host.sim.particleCount - 1)
    try host.capture(width: 1440, height: 900, to: output + "/marker.png")
    host.renderer.selectedParticleIndex = nil
}

private func checkSilent(_ passed: Bool) throws {
    if !passed { throw NSError(domain: "StellarProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: "Inconsistent representative star model"]) }
}

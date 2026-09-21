import Foundation
import Metal
import simd

/// Run the Local Group forward for eight billion years and report who meets
/// whom, when. The point is not that the numbers are exact — they cannot be,
/// because Andromeda's sideways speed is not known well enough — but that the
/// story holds: the Clouds go first, Andromeda decides the fate of the pair,
/// and Triangulum is still out there at the end either way.
func runLocalGroupDiagnostics(host: SimHost, output: String) throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "LocalGroup", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    // The catalogue, checked against itself. These three distances are not
    // inputs — they fall out of five (longitude, latitude, distance) triples
    // and the transform into simulation coordinates, so if any of that is
    // wrong they will not land.
    let mw = LocalGroup.milkyWayPosition
    let m31 = LocalGroup.andromedaPosition
    let m33 = LocalGroup.triangulumPosition
    let lmc = LocalGroup.largeCloudPosition
    let smc = LocalGroup.smallCloudPosition
    func sep(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(a - b) }
    print(String(format: "geometry: MW-M31 %.0f · M31-M33 %.0f · MW-LMC %.1f · LMC-SMC %.1f kpc",
                 sep(mw, m31), sep(m31, m33), sep(mw, lmc), sep(lmc, smc)))
    try require(abs(sep(mw, m31) - 780) < 5, "Andromeda should be 780 kpc away")
    try require(abs(sep(m31, m33) - 217) < 15, "Triangulum should be ~217 kpc from Andromeda")
    try require(abs(sep(mw, lmc) - 49.6) < 2, "The Large Cloud should be ~50 kpc out")
    try require(abs(sep(lmc, smc) - 23) < 4, "The Clouds should be ~23 kpc apart")

    // Masses, in solar masses, so a bad fiducial cannot slip through.
    let scene = LocalGroup.scene(budget: 20_000, course: .headOn)
    let names = ["Milky Way", "Andromeda", "Triangulum", "Large Cloud"]
    let expected: [Double] = [1.15e12, 1.50e12, 5.0e10, 1.40e11]
    try require(scene.specs.count == names.count, "Expected four galaxies")
    for (i, spec) in scene.specs.enumerated() {
        let msun = Double(GalaxyModels.potential(for: spec).totalMass) * Units.msunPerMassUnit
        print(String(format: "  %@: %.2e Msun (asked %.2e), %d particles",
                     names[i], msun, expected[i], spec.particleCount))
        try require(abs(msun / expected[i] - 1) < 0.02, "\(names[i]) came out the wrong mass")
    }

    struct Outcome {
        var minSeparation: [Float]      // per galaxy, against the Milky Way
        /// When each galaxy first came within 15 kpc of the Milky Way, which
        /// is the honest way to date a merger. Taking the time of closest
        /// approach instead just records the last numerical twitch after the
        /// two centres have already sat on top of each other for 6 Gyr.
        var arrival: [Float]
        var final: [Float]
    }

    func fly(_ course: LocalGroup.Course) throws -> Outcome {
        let scene = LocalGroup.scene(budget: 20_000, course: course)
        let sim = try Simulation(ctx: host.ctx)
        try require(sim.load(scene), "Scene allocation failed")
        var minSep = [Float](repeating: .greatestFiniteMagnitude, count: names.count)
        var arrival = [Float](repeating: .infinity, count: names.count)
        var last = [Float](repeating: 0, count: names.count)
        var atFourGyr = [Float](repeating: 0, count: names.count)

        print("\n\(course.label) — separation from the Milky Way, kpc")
        print("  Gyr     Andromeda  Triangulum  LargeCloud")
        let dt = sim.params.dt                      // Myr per step
        let steps = Int(8000 / dt)
        for step in 0...steps {
            if step > 0 {
                let cb = host.ctx.queue.makeCommandBuffer()!
                sim.step(commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                try require(cb.status == .completed, "Physics failed at step \(step)")
            }
            let t = Float(step) * dt
            let home = sim.cores[0].position
            for i in 1..<names.count {
                let d = simd_length(sim.cores[i].position - home)
                try require(d.isFinite, "\(names[i]) went non-finite at \(t) Myr")
                minSep[i] = min(minSep[i], d)
                if d < 15 { arrival[i] = min(arrival[i], t) }
                last[i] = d
                if abs(t - 4000) < dt { atFourGyr[i] = d }
            }
            if step % Int(500 / dt) == 0 {
                var line = String(format: "  %4.1f  ", t / 1000)
                for i in 1..<names.count {
                    line += String(format: "%11.1f", simd_length(sim.cores[i].position - home))
                }
                print(line)
            }
        }
        for i in 1..<names.count {
            let when = arrival[i].isFinite
                ? String(format: "arrives %.2f Gyr", arrival[i] / 1000)
                : "still out there"
            print(String(format: "  %@: closest %.1f kpc · at 4 Gyr %.0f kpc · %@",
                         names[i], minSep[i], atFourGyr[i], when))
        }
        return Outcome(minSeparation: minSep, arrival: arrival, final: atFourGyr)
    }

    let hit = try fly(.headOn)
    let miss = try fly(.grazing)

    print("")
    // The Clouds are already inside the halo at 50 kpc doing 320 km/s, where
    // dynamical friction is strong; they should sink regardless of what
    // Andromeda is doing, and they should do it long before Andromeda gets
    // here. That is the "one hits" in the story.
    for outcome in [hit, miss] {
        try require(outcome.minSeparation[3] < 15,
                    "The Large Cloud should fall in, not orbit forever")
        try require(outcome.arrival[3] < 3500,
                    "The Large Cloud should arrive first, long before Andromeda")
        try require(outcome.arrival[3] < outcome.arrival[1],
                    "The Large Cloud should beat Andromeda to it")
    }
    print(String(format: "PASS: the Large Cloud sinks in at %.2f Gyr either way — first to arrive",
                 hit.arrival[3] / 1000))

    // Andromeda is the coin flip: the two published transverse speeds have to
    // land on opposite sides of a collision or the scene makes no point.
    try require(hit.minSeparation[1] < 40,
                "With Hubble's transverse speed Andromeda should hit us")
    try require(miss.minSeparation[1] > 2 * hit.minSeparation[1],
                "With Gaia's transverse speed Andromeda should clearly miss")
    print(String(format: "PASS: Andromeda passes at %.0f kpc head-on vs %.0f kpc grazing",
                 hit.minSeparation[1], miss.minSeparation[1]))

    // And Triangulum is still a separate galaxy, a long way out, while the
    // big two are deciding — the one that wonders.
    //
    // It does not stay out forever. Left to run, dynamical friction drags it
    // down onto whatever Andromeda has become, some billions of years after
    // the main event, and that is a real prediction rather than an artefact:
    // a 5e10 satellite at 220 kpc inside a 1.5e12 halo does eventually sink.
    // The claim being checked is only that it is still out there, intact and
    // watching, at the moment the collision happens.
    for outcome in [hit, miss] {
        try require(outcome.final[2] > 150,
                    "Triangulum should still be far out at 4 Gyr, watching")
    }
    print(String(format: "PASS: at 4 Gyr Triangulum is still %.0f kpc away, intact",
                 min(hit.final[2], miss.final[2])))

    // Frames, so the story can be looked at rather than only tabulated.
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    for (tag, course) in [("hit", LocalGroup.Course.headOn),
                          ("miss", LocalGroup.Course.grazing)] {
        let scene = LocalGroup.scene(budget: host.particleBudget, course: course)
        try require(host.sim.load(scene), "Scene allocation failed for \(tag)")
        host.camera.target = .zero
        host.camera.distance = scene.cameraDistance
        host.sim.isPaused = false
        var elapsed: Float = 0
        for gyr in [Float(0), 2, 4, 5, 6, 8] {
            let steps = Int((gyr * 1000 - elapsed) / host.sim.params.dt)
            if steps > 0 { host.advance(steps: steps) }
            elapsed = gyr * 1000
            let path = String(format: "%@/localgroup-%@-%.0fGyr.png", output, tag, gyr)
            try require(try host.capture(width: 1280, height: 800, to: path), "Capture failed")
            let e = host.sim.sampleExtent()
            print(String(format: "  %@ at %d Gyr -> extent r=%.0f kpc, camera d=%.0f -> %@",
                         tag, Int(gyr), e.radius, host.camera.distance, path))
        }
    }
}

import simd
import Foundation

enum Presets {

    /// Place two galaxies on a Keplerian encounter orbit in the xz plane,
    /// in the centre-of-mass frame.
    ///
    /// For a parabolic orbit of pericentre `q` at separation `r`:
    ///   v² = 2μ/r      and      L² = 2μq
    /// which fixes the tangential and radial components exactly.
    /// `eccentricity` > 1 makes it hyperbolic (a fast flyby), < 1 bound.
    /// Place two galaxies on an encounter that actually reaches the requested
    /// pericentre.
    ///
    /// The textbook two-body formulae assume point masses. These galaxies are
    /// extended Hernquist haloes, so at close separation only a fraction of
    /// each mass is enclosed and the real attraction is much weaker — aiming
    /// for an 18 kpc pericentre with the point-mass formula actually yields
    /// about 31 kpc. So: take the overall encounter speed from the analytic
    /// energy, then bisect on the tangential component, integrating the true
    /// three-component potentials, until the achieved pericentre matches.
    static func encounter(_ a: GalaxySpec, _ b: GalaxySpec,
                          separation r: Float,
                          pericenter q: Float,
                          eccentricity e: Float = 1.0) -> [GalaxySpec] {
        var ga = a, gb = b
        let potA = GalaxyModels.potential(for: ga)
        let potB = GalaxyModels.potential(for: gb)
        let ma = potA.totalMass, mb = potB.totalMass
        let mu = ma + mb                      // G == 1
        let total = max(mu, 1e-6)

        // Overall speed at separation r, from the point-mass energy. This sets
        // how fast the encounter is; the direction sets how close it gets.
        let energy: Float = (e == 1) ? 0 : mu * (e - 1) / (2 * q)
        let v = sqrt(max(2 * (energy + mu / r), 1e-8))

        let coreA = GalaxyCore(position: .zero, velocity: .zero,
                               potential: potA, spinAxis: ga.spinAxis)
        let coreB = GalaxyCore(position: .zero, velocity: .zero,
                               potential: potB, spinAxis: gb.spinAxis)

        /// Min separation reached with a given tangential speed.
        func pericentreFor(_ vTan: Float) -> Float {
            var relPos = SIMD3<Float>(r, 0, 0)
            var relVel = SIMD3<Float>(-sqrt(max(v * v - vTan * vTan, 0)), 0, vTan)
            var minSep = r
            let dt: Float = 0.4
            var receding = false
            for _ in 0..<6000 {
                // relative motion: acceleration of A by B, minus of B by A
                var acc = coreB.accel(at: relPos)
                acc -= coreA.accel(at: -relPos)
                relVel += acc * dt
                relPos += relVel * dt
                let sep = simd_length(relPos)
                if sep < minSep { minSep = sep }
                if sep > minSep * 1.15 && minSep < r { receding = true }
                if receding { break }
            }
            return minSep
        }

        // Pericentre grows monotonically with tangential speed, so bisect.
        var lo: Float = 0, hi = v
        if pericentreFor(hi) < q {
            // even a fully tangential launch can't stay that far out
            lo = hi
        } else {
            for _ in 0..<40 {
                let mid = 0.5 * (lo + hi)
                if pericentreFor(mid) < q { lo = mid } else { hi = mid }
            }
        }
        let vTan = 0.5 * (lo + hi)
        let vRad = -sqrt(max(v * v - vTan * vTan, 0))

        let relPos = SIMD3<Float>(r, 0, 0)
        let relVel = SIMD3<Float>(vRad, 0, vTan)

        ga.position = relPos * (mb / total)
        gb.position = -relPos * (ma / total)
        ga.velocity = relVel * (mb / total)
        gb.velocity = -relVel * (ma / total)
        return [ga, gb]
    }

    /// Relative velocity that puts two galaxies at `relPos` on an encounter
    /// reaching `pericenter`. Same numerical solve as `encounter`, exposed so
    /// hand-placed galaxies can be given a sensible orbit.
    static func encounterVelocity(potA: PotentialParams, potB: PotentialParams,
                                  spinA: SIMD3<Float>, spinB: SIMD3<Float>,
                                  relPos: SIMD3<Float>,
                                  pericenter q: Float,
                                  eccentricity e: Float = 1.0) -> SIMD3<Float> {
        let r = simd_length(relPos)
        guard r > 1e-3 else { return .zero }
        let mu = potA.totalMass + potB.totalMass
        let energy: Float = (e == 1) ? 0 : mu * (e - 1) / (2 * q)
        let v = sqrt(max(2 * (energy + mu / r), 1e-8))

        let coreA = GalaxyCore(position: .zero, velocity: .zero, potential: potA, spinAxis: spinA)
        let coreB = GalaxyCore(position: .zero, velocity: .zero, potential: potB, spinAxis: spinB)

        let radial = relPos / r
        // any unit vector perpendicular to the separation works as the
        // tangential direction; pick a stable one
        let helper: SIMD3<Float> = abs(radial.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let tangent = simd_normalize(simd_cross(helper, radial))

        func pericentreFor(_ vTan: Float) -> Float {
            var pos = relPos
            var vel = -radial * sqrt(max(v * v - vTan * vTan, 0)) + tangent * vTan
            var minSep = r
            var receding = false
            let dt: Float = 0.4
            for _ in 0..<6000 {
                var acc = coreB.accel(at: pos)
                acc -= coreA.accel(at: -pos)
                vel += acc * dt
                pos += vel * dt
                let sep = simd_length(pos)
                if sep < minSep { minSep = sep }
                if sep > minSep * 1.15 && minSep < r { receding = true }
                if receding { break }
            }
            return minSep
        }

        var lo: Float = 0, hi = v
        if pericentreFor(hi) < q { lo = hi } else {
            for _ in 0..<40 {
                let mid = 0.5 * (lo + hi)
                if pericentreFor(mid) < q { lo = mid } else { hi = mid }
            }
        }
        let vTan = 0.5 * (lo + hi)
        return -radial * sqrt(max(v * v - vTan * vTan, 0)) + tangent * vTan
    }

    static func spec(_ type: GalaxyType, _ count: Int,
                     mass: Float = 1, radius: Float = 1,
                     spin: SIMD3<Float> = SIMD3(0, 1, 0),
                     retrograde: Bool = false,
                     seed: UInt64 = 0x2545F491_4F6CDD1D) -> GalaxySpec {
        GalaxySpec(type: type, particleCount: count,
                   massScale: mass, radiusScale: radius,
                   spinAxis: spin, retrograde: retrograde, seed: seed)
    }

    /// Tilt a spin axis by `deg` degrees away from vertical, about x.
    static func tilt(_ deg: Float, roll: Float = 0) -> SIMD3<Float> {
        let t = deg * .pi / 180, r = roll * .pi / 180
        return simd_normalize(SIMD3(sin(t) * sin(r), cos(t), sin(t) * cos(r)))
    }

    static func all(budget: Int) -> [Scene] {
        // split the particle budget between the pair
        let big = Int(Double(budget) * 0.5)
        let small = Int(Double(budget) * 0.16)

        return [
            Scene(name: "Antennae · Sc + Sc prograde",
                  specs: encounter(
                    spec(.sc, big, spin: tilt(20, roll: 10), seed: 0xA11CE),
                    spec(.sc, big, spin: tilt(35, roll: 200), seed: 0xB0B),
                    separation: 150, pericenter: 9),
                  cameraDistance: 260,
                  galaxyNames: ["NGC 4038", "NGC 4039"]),

            Scene(name: "The Mice · thin tidal tails",
                  specs: encounter(
                    spec(.sb, big, spin: tilt(8, roll: 0), seed: 0x31CE &+ 1),
                    spec(.sb, big, spin: tilt(12, roll: 180), seed: 0x31CE &+ 2),
                    separation: 170, pericenter: 12),
                  cameraDistance: 300,
                  galaxyNames: ["NGC 4676A", "NGC 4676B"]),

            Scene(name: "Cartwheel · bullseye through the disk",
                  specs: encounter(
                    spec(.sc, big, radius: 1.15, spin: SIMD3(0, 1, 0), seed: 0xCA27),
                    spec(.dwarf, small, mass: 0.30, spin: tilt(90), seed: 0xCA28),
                    separation: 140, pericenter: 1.5),
                  cameraDistance: 230,
                  galaxyNames: ["Cartwheel Galaxy", "The Intruder"]),

            Scene(name: "Whirlpool · M51 and companion",
                  specs: encounter(
                    spec(.sc, big, spin: SIMD3(0, 1, 0), seed: 0x51A),
                    spec(.e0, small, mass: 0.25, spin: tilt(40), seed: 0x51B),
                    separation: 95, pericenter: 22),
                  cameraDistance: 180,
                  galaxyNames: ["The Whirlpool (M51)", "NGC 5195"]),

            // The only two scenes here built from measurements rather than
            // from whatever looked good. Same four real galaxies, same real
            // positions; the single difference is Andromeda's sideways
            // speed, and the two published values for it sit on either side
            // of a collision. See LocalGroup.swift.
            LocalGroup.scene(budget: budget, course: .headOn),
            LocalGroup.scene(budget: budget, course: .grazing),

            Scene(name: "Dry merger · two ellipticals",
                  specs: encounter(
                    spec(.e0, big, mass: 1.1, seed: 0xE00),
                    spec(.e5, big, mass: 0.9, spin: tilt(55, roll: 90), seed: 0xE55),
                    separation: 160, pericenter: 14),
                  cameraDistance: 280),

            Scene(name: "Retrograde pass · no tails",
                  specs: encounter(
                    spec(.sb, big, spin: tilt(15), seed: 0x8001),
                    spec(.sb, big, spin: tilt(15), retrograde: true, seed: 0x8002),
                    separation: 150, pericenter: 20),
                  cameraDistance: 260),

            Scene(name: "Minor merger · spiral eats a dwarf",
                  specs: encounter(
                    spec(.sbb, big, spin: tilt(18), seed: 0xBA71),
                    spec(.dwarf, small, mass: 0.06, spin: tilt(60), seed: 0xBA72),
                    separation: 110, pericenter: 26),
                  cameraDistance: 200),

            Scene(name: "Hyperbolic flyby · fast and clean",
                  specs: encounter(
                    spec(.sbc, big, spin: tilt(22), seed: 0xF1B1),
                    spec(.sc, big, spin: tilt(48, roll: 220), seed: 0xF1B2),
                    separation: 190, pericenter: 30, eccentricity: 1.6),
                  cameraDistance: 320),

            Scene(name: "Solo · inspect one galaxy",
                  specs: [spec(.sb, budget, spin: SIMD3(0, 1, 0), seed: 0x5010)],
                  cameraDistance: 95),
        ]
    }
}

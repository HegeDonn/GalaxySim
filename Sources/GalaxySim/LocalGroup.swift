import simd
import Foundation

// MARK: - The Local Group, from the catalogue
//
// Every other preset in this program is invented: a pericentre and a tilt
// chosen because they make a pretty picture. This one is not. The positions
// are measured, the line-of-sight speeds are measured, and the masses are
// the current consensus. Only the sideways speeds are guesses, and they are
// guesses in a very specific way — see `Course` below.
//
// What it shows, in the order the kids will see it:
//
//   The Large Magellanic Cloud falls in first. It is already inside the
//   Milky Way's halo, moving at 320 km/s, and dynamical friction drags it
//   down within about two billion years. That is the one that hits.
//
//   Triangulum rides along with Andromeda as its companion and mostly just
//   watches, a quarter of a million light years off to the side, until the
//   big two have sorted themselves out. That is the one that wonders.
//
//   And everything else in the sky — Virgo, Coma, the lot — is not in this
//   scene at all, because it never arrives. Beyond about 1.5 Mpc the
//   expansion of space wins and those galaxies recede forever. That is the
//   one that flies away, and the honest way to show it is an empty frame.
//
// One caveat, because the dates below look more precise than they are. The
// galaxy centres move under an analytic potential plus Chandrasekhar
// dynamical friction, and that machinery is tuned to make major mergers
// happen on a watchable timescale rather than to track a satellite orbit
// faithfully — it pulls small companions down somewhat faster than a proper
// N-body calculation would. So read every number as "about this many billion
// years". What is robust is the order: the Clouds first, then Andromeda,
// with Triangulum still outside when it happens. The order is the part worth
// showing, and it is the part that survives the uncertainty.
enum LocalGroup {

    /// Distance from the Sun to the galactic centre, kpc.
    static let sunRadius: Float = 8.122

    /// Convert a catalogue position — galactic longitude, galactic latitude,
    /// distance from us — into the simulation's frame.
    ///
    /// The simulation puts the Milky Way's centre at the origin with its disk
    /// in the xz plane and its spin axis along +y, which is what every galaxy
    /// model here assumes. Galactic coordinates instead put *the Sun* at the
    /// origin with the disk in the xy plane. So: build the vector from the
    /// Sun, shift to the galactic centre, then swap the axes. The swap
    /// (x, y, z) -> (x, z, -y) is a rotation, not a reflection: the Local
    /// Group comes out the right way round rather than mirrored.
    static func place(l: Float, b: Float, distance d: Float) -> SIMD3<Float> {
        let lr = l * .pi / 180, br = b * .pi / 180
        let fromSun = SIMD3<Float>(cos(br) * cos(lr), cos(br) * sin(lr), sin(br)) * d
        // The centre is at +x from the Sun, so the Sun sits at -R0, a touch
        // above the midplane.
        let g = SIMD3<Float>(-sunRadius, 0, 0.0208) + fromSun
        return SIMD3(g.x, g.z, -g.y)
    }

    /// How hard Andromeda is aimed at us.
    ///
    /// Its approach speed, 109 km/s straight at the Milky Way, has been known
    /// since 1912 — a spectrum gives it away. Its *sideways* speed is the hard
    /// one: you need to watch the galaxy creep across the sky for decades.
    /// Hubble said 17 km/s in 2012, which is very nearly a dead-centre hit.
    /// Gaia's third data release, once you account for a Large Magellanic
    /// Cloud heavy enough to swing the Milky Way itself, allows something
    /// nearer 57 km/s, and that misses. Same galaxy, same data, one error bar
    /// apart — which is why the 2025 reanalysis put the merger at closer to a
    /// coin flip than the certainty everyone grew up being told.
    enum Course {
        case headOn      // Hubble's number: they collide
        case grazing     // Gaia's number: they sail past each other

        var transverseKms: Float { self == .headOn ? 17 : 57 }

        var label: String {
            self == .headOn ? "Andromeda hits us" : "Andromeda misses us"
        }
    }

    // MARK: - Helpers

    /// The mass scale that makes a galaxy of this type weigh `solarMasses`,
    /// halo included. Read off the fiducial rather than hard-coding it, so
    /// retuning a galaxy model does not silently rewrite the Local Group.
    private static func massScale(_ type: GalaxyType, solarMasses: Double) -> Float {
        let fiducial = GalaxyModels.potential(
            for: GalaxySpec(type: type, particleCount: 0)).totalMass
        return Float(solarMasses / Units.msunPerMassUnit) / max(fiducial, 1e-6)
    }

    /// Some unit vector at right angles to `v`.
    private static func perpendicular(to v: SIMD3<Float>) -> SIMD3<Float> {
        let away = abs(v.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        return simd_normalize(simd_cross(v, away))
    }

    /// Build a velocity the way the measurements arrive: a speed along the
    /// line joining the two galaxies (positive = receding, the sign a redshift
    /// gives you) plus a speed across it.
    ///
    /// `hint` only chooses which way the sideways part points, and therefore
    /// the plane of the orbit. It does not change how close the encounter
    /// gets: that depends on the *size* of the tangential velocity alone.
    private static func velocity(of position: SIMD3<Float>,
                                 about centre: SIMD3<Float>,
                                 radial radialKms: Float,
                                 across tangentialKms: Float,
                                 towards hint: SIMD3<Float>) -> SIMD3<Float> {
        let d = position - centre
        let r = simd_length(d)
        guard r > 1e-4 else { return .zero }
        let outward = d / r
        var tangent = hint - outward * simd_dot(hint, outward)
        if simd_length_squared(tangent) < 1e-8 { tangent = perpendicular(to: outward) }
        tangent = simd_normalize(tangent)
        return outward * Units.speed(fromKms: radialKms)
             + tangent * Units.speed(fromKms: tangentialKms)
    }

    /// A spin axis that presents the galaxy at `inclination` degrees as seen
    /// from the Milky Way: 0 is face-on, 90 is edge-on. Andromeda is 77, which
    /// is why every photograph of it is a long thin ellipse rather than a
    /// spiral seen from above.
    private static func axis(at position: SIMD3<Float>,
                             inclination: Float, roll: Float) -> SIMD3<Float> {
        let sight = simd_length_squared(position) > 1e-8
            ? simd_normalize(position) : SIMD3<Float>(0, 0, 1)
        let p = perpendicular(to: sight)
        let q = simd_cross(sight, p)
        let i = inclination * .pi / 180, r = roll * .pi / 180
        return simd_normalize(sight * cos(i) + (p * cos(r) + q * sin(r)) * sin(i))
    }

    // MARK: - The members

    /// Catalogue positions. Distances in kpc, angles in degrees.
    /// Cross-checks that fall out of these five lines, and should keep
    /// falling out if anyone edits them: Andromeda to Triangulum 217 kpc,
    /// the two Clouds 23 kpc apart, the Large Cloud 49 kpc from the centre.
    static let milkyWayPosition = SIMD3<Float>.zero
    static let andromedaPosition  = place(l: 121.17, b: -21.57, distance: 780)
    static let triangulumPosition = place(l: 133.61, b: -31.33, distance: 840)
    static let largeCloudPosition = place(l: 280.47, b: -32.89, distance: 49.6)
    /// The Small Cloud is not placed as a galaxy — see the note below — but
    /// its catalogue position is kept because it gives the sharpest check on
    /// the coordinate transform: two galaxies in quite different parts of the
    /// sky that have to come out 23 kpc apart.
    static let smallCloudPosition = place(l: 302.80, b: -44.30, distance: 62.0)

    /// Build the scene. `budget` is the total particle count to share out.
    static func scene(budget: Int, course: Course) -> Scene {
        // Galactic north, used only to pick orbit planes (see `velocity`).
        let north = SIMD3<Float>(0, 1, 0)

        // Andromeda: 109 km/s of approach that has been measured for a
        // century, and a sideways speed that is the whole argument.
        let andromedaVelocity = velocity(of: andromedaPosition, about: milkyWayPosition,
                                         radial: -109, across: course.transverseKms,
                                         towards: north)

        // Triangulum is Andromeda's satellite, 217 kpc out from it and going
        // round it a little faster than the circular speed, which keeps it on
        // a wide orbit. It travels as part of the same package, so it arrives
        // late and still in one piece while the big two are busy.
        let triangulumVelocity = andromedaVelocity
            + velocity(of: triangulumPosition, about: andromedaPosition,
                       radial: 0, across: 165, towards: north)

        // The Large Cloud is the one already here. It passed closest a little
        // while ago and is drifting out again at 64 km/s, but it is doing 314
        // km/s sideways at only 50 kpc, deep inside the Milky Way's halo,
        // where dynamical friction bites hardest.
        let largeCloudVelocity = velocity(of: largeCloudPosition, about: milkyWayPosition,
                                          radial: 64, across: 314, towards: north)

        // The Small Cloud is deliberately absent. At 1.5e10 solar masses and
        // 23 kpc from the Large Cloud it is too light to keep its orbit here:
        // the drag this engine applies to a small galaxy inside a big halo is
        // stronger than the Small Cloud's grip on itself, so whatever speed
        // it is given it either fuses with the Large Cloud inside half a
        // billion years or is flung away as a separate satellite. Neither is
        // what the sky does, and a companion that vanishes in the first eight
        // seconds of playback is worse than no companion at all.

        func share(_ f: Double) -> Int { max(200, Int(Double(budget) * f)) }

        let specs = [
            GalaxySpec(type: .sbb, particleCount: share(0.32),
                       massScale: massScale(.sbb, solarMasses: 1.15e12),
                       radiusScale: 1.0,
                       position: milkyWayPosition, velocity: .zero,
                       spinAxis: SIMD3(0, 1, 0), seed: 0x11_11),

            GalaxySpec(type: .sa, particleCount: share(0.38),
                       massScale: massScale(.sa, solarMasses: 1.50e12),
                       radiusScale: 1.40,
                       position: andromedaPosition, velocity: andromedaVelocity,
                       spinAxis: axis(at: andromedaPosition, inclination: 77, roll: 35),
                       seed: 0x31_00),

            GalaxySpec(type: .sc, particleCount: share(0.12),
                       massScale: massScale(.sc, solarMasses: 5.0e10),
                       radiusScale: 0.45,
                       position: triangulumPosition, velocity: triangulumVelocity,
                       spinAxis: axis(at: triangulumPosition, inclination: 54, roll: 210),
                       seed: 0x33_00),

            GalaxySpec(type: .irr, particleCount: share(0.18),
                       massScale: massScale(.irr, solarMasses: 1.40e11),
                       radiusScale: 0.60,
                       position: largeCloudPosition, velocity: largeCloudVelocity,
                       spinAxis: axis(at: largeCloudPosition, inclination: 35, roll: 120),
                       seed: 0x1_ACE),

        ]

        // Stand off to the side of the line from here to Andromeda, rather
        // than on it. See Scene.cameraAzimuth.
        return Scene(name: "Local Group · " + course.label,
                     specs: specs, cameraDistance: 1400,
                     cameraAzimuth: 2.31, cameraElevation: 0.20,
                     galaxyNames: ["The Milky Way", "Andromeda (M31)",
                                   "Triangulum (M33)", "Large Magellanic Cloud"])
    }
}

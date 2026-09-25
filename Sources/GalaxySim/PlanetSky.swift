import Foundation
import simd

// ===================================================================
//  Where the probe is standing, and what its star looks like from there
//
//  Two questions this file answers, both of which used to be dodged:
//
//  1. Which way is up? The night sky used to assume the planet's zenith was
//     the simulation's +Y axis. The galaxy's disc lies near the simulation's
//     XZ plane, so the interesting half of the sky -- the bulge, the lane,
//     the crowded arms -- sat ON the skyline and, as often as not, under it.
//     Nothing about a planet requires its pole to agree with a galaxy's, so
//     the probe now lands with a pole of its own, chosen to put the galaxy
//     where it can be seen.
//
//  2. Where is the star this planet belongs to? It has to be somewhere: a
//     planet is not a rock in free space. Once it is in the sky it answers
//     the question a photograph of a night sky always raises -- what happens
//     to all of this when the sun comes up -- and the answer differs
//     enormously from star to star, which is the whole point.
// ===================================================================

/// A spot on an imagined planet: which way is up, which way it turns, and
/// where its star sits.
///
/// The planet's rotation axis is aimed near the galaxy's brightest quarter.
/// That is a free choice -- obliquity is not constrained by anything -- and
/// it buys two things at once. The galaxy sits at a fixed altitude and
/// circles slowly rather than rising and setting, so it is never lost; and
/// the star trails in a long exposure wheel around the galactic centre,
/// which is exactly what a polar-aligned exposure on Earth does around
/// Polaris.
struct LandingSite {
    /// Rotation axis, galaxy coordinates. The celestial pole of this planet.
    var axis: SIMD3<Float>
    /// Straight up, east and north at `spin == 0`.
    var zenith0: SIMD3<Float>
    var east0: SIMD3<Float>
    var north0: SIMD3<Float>
    /// The host star, fixed in galaxy coordinates. Artistic licence, stated
    /// plainly: the planet does not orbit it here, the planet only turns, so
    /// the star keeps one place among the stars and rises and sets with them.
    /// Over a single night that is very nearly true anyway.
    var sun: SIMD3<Float>
    /// How far the planet has turned since landing, in radians.
    var spin: Float = 0
    /// Hours in one turn. Used only to put a number on "you slept a while".
    var dayLength: Double = 24

    private func turned(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(spin), s = sin(spin)
        return v * c + simd_cross(axis, v) * s + axis * (simd_dot(axis, v) * (1 - c))
    }
    /// The local frame right now. The whole frame turns with the ground, so
    /// the landscape holds still and the sky sweeps past it -- which is the
    /// right way round, and the reason the camera basis is built from these.
    var zenith: SIMD3<Float> { turned(zenith0) }
    var east: SIMD3<Float> { turned(east0) }
    var north: SIMD3<Float> { turned(north0) }

    /// Sine of the altitude of a direction: > 0 is above the skyline.
    func altitude(of d: SIMD3<Float>) -> Float { simd_dot(d, zenith) }
    /// Camera yaw and pitch that look straight at a direction.
    func aim(at d: SIMD3<Float>) -> (yaw: Float, pitch: Float) {
        let u = simd_normalize(d)
        return (atan2(simd_dot(u, east), simd_dot(u, north)),
                asin(max(-1, min(1, simd_dot(u, zenith)))))
    }

    /// The spin angle at which a fixed direction stands highest in the sky.
    ///
    /// altitude(θ) = d·R(axis, θ)·zenith0, which expands to a constant plus
    /// a single sinusoid in θ; this is where that sinusoid peaks. Noon, in
    /// other words, and adding π gives midnight.
    func spinForHighest(_ d: SIMD3<Float>) -> Float {
        let k = simd_dot(d, axis) * simd_dot(axis, zenith0)
        let a = simd_dot(d, zenith0) - k
        let b = -simd_dot(simd_cross(axis, d), zenith0)
        if abs(a) < 1e-7 && abs(b) < 1e-7 { return 0 }
        return atan2(b, a)
    }

    /// A fresh landing spot. `heart` is the direction of the galaxy's
    /// brightest quarter as seen from this star.
    static func choose(heart: SIMD3<Float>,
                       rng: inout SystemRandomNumberGenerator) -> LandingSite {
        func rand(_ lo: Float, _ hi: Float) -> Float { Float.random(in: lo...hi, using: &rng) }

        let pole = simd_normalize(allFinite(heart) && simd_length_squared(heart) > 1e-8
                                  ? heart : SIMD3<Float>(1, 0, 0))
        // A little off the galactic centre, so the galaxy drifts over the
        // course of a night instead of being nailed in place.
        let axis = simd_normalize(pole + perpendicular(to: pole) * rand(-0.10, 0.10))

        // Latitude, in effect: the pole stands (90 - tilt) degrees up, so the
        // galaxy sits between about 56 and 64 degrees above the skyline and
        // stays there all night.
        let tilt = rand(0.45, 0.60)                       // ~26-34 degrees
        let (p, q) = frame(around: axis)
        let phase = rand(0, 2 * .pi)
        let side = p * cos(phase) + q * sin(phase)
        let zenith0 = simd_normalize(axis * cos(tilt) + side * sin(tilt))

        // The star sits far enough round from the pole that it genuinely
        // rises and sets: highest about 8-18 degrees up, lowest some 45
        // degrees under. A low sun is also the prettier one to photograph.
        let sunAngle = tilt + rand(1.26, 1.43)            // 72-82 degrees past the tilt
        let sunPhase = phase + .pi + rand(-0.85, 0.85)    // starts well down: it is night
        let sunSide = p * cos(sunPhase) + q * sin(sunPhase)
        let sun = simd_normalize(axis * cos(sunAngle) + sunSide * sin(sunAngle))

        let north0 = simd_normalize(axis - zenith0 * simd_dot(axis, zenith0))
        let east0 = simd_normalize(simd_cross(north0, zenith0))
        return LandingSite(axis: axis, zenith0: zenith0, east0: east0, north0: north0,
                           sun: sun, spin: 0, dayLength: Double(rand(9, 41)))
    }

    /// Move on this planet without changing its axis, sun, or day length.
    func relocated(to normal: SIMD3<Float>) -> LandingSite {
        let z = simd_normalize(normal)
        let projected = axis - z * simd_dot(axis, z)
        let north = simd_length_squared(projected) > 1e-8
            ? simd_normalize(projected) : Self.perpendicular(to: z)
        return LandingSite(axis: axis, zenith0: z, east0: simd_normalize(simd_cross(north, z)),
                           north0: north, sun: sun, spin: 0, dayLength: dayLength)
    }

    /// Any unit vector at right angles to `v`.
    private static func perpendicular(to v: SIMD3<Float>) -> SIMD3<Float> {
        let ref: SIMD3<Float> = abs(v.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        return simd_normalize(simd_cross(ref, v))
    }
    private static func frame(around v: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let p = perpendicular(to: v)
        return (p, simd_cross(v, p))
    }
    private static func allFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}

/// The star this planet belongs to, and the orbit we are standing in.
///
/// The rule for the orbit is the one a visitor would guess, with the one
/// correction reality forces:
///
///   * 1 AU by default -- Earth's distance from the Sun. A star much like
///     the Sun therefore looks exactly as the Sun does from a beach, and a
///     dim red dwarf at the same distance is genuinely feeble, which is the
///     thing worth finding out.
///   * Not inside the star. A red giant can be wider than Earth's orbit --
///     Betelgeuse would reach past Mars -- so the orbit is pushed out to at
///     least three stellar radii, or there is no planet, only star.
///   * Not on a griddle. Beyond four times Earth's sunlight there is no
///     solid ground worth standing on, so a luminous star pushes the orbit
///     out until the light arriving is four Earths' worth at most.
///
/// The last rule is the one that surprises people: retreat far enough from a
/// supergiant not to be cooked and it is only a few times wider than our own
/// Sun looks, because the same luminosity that makes it huge is what forces
/// you back. Brightness wins the argument, not size.
struct HostStar {
    /// Radius of the Sun in astronomical units: 0.00465 AU, and the reason
    /// the Sun is half a degree wide from here.
    static let solarRadiusAU = 0.004650467

    let profile: StellarProfile
    /// Where the planet sits, in AU.
    let distanceAU: Double
    /// Sunlight arriving, with Earth's as 1.
    let insolation: Double
    /// Half the star's apparent width, in radians.
    let angularRadius: Double
    /// Hue of the photosphere, brightest channel normalised to 1. The disc
    /// itself burns out to white in any exposure this camera can take; the
    /// colour survives in the glow around it, exactly as it does in a
    /// photograph of a sunrise.
    let chroma: SIMD3<Float>
    /// Surface radiance relative to the Sun's. It depends on temperature
    /// alone -- not on distance, and not on size. A star's surface is as
    /// bright close up as it is from far away; moving away only makes it
    /// smaller. That single fact is why every star here over-exposes and
    /// only their sizes differ.
    let surfaceBrightness: Double

    init(profile: StellarProfile) {
        self.profile = profile
        let radiusAU = profile.solarRadius * Self.solarRadiusAU
        let clearance = 3 * radiusAU
        let bearable = (profile.solarLuminosity / 4).squareRoot()
        let d = max(1, max(clearance, bearable))
        distanceAU = d
        insolation = profile.solarLuminosity / (d * d)
        angularRadius = atan(radiusAU / d)
        surfaceBrightness = pow(profile.temperature / 5772, 4)
        let rgb = Relativity.blackbodyRGB(Float(profile.temperature))
        let peak = max(rgb.x, max(rgb.y, rgb.z))
        chroma = rgb / max(peak, 1e-4)
    }

    /// How wide it looks next to our own Sun from Earth.
    var timesOurSun: Double { angularRadius / 0.004652 }

    /// Two or three plain sentences for the corner of the screen. No field
    /// labels: this is read by children as often as by anyone else.
    var description: String {
        let where_: String
        if distanceAU <= 1.0001 {
            where_ = "Your planet is 1 AU out, exactly as far as Earth is from the Sun."
        } else if distanceAU < 12 {
            where_ = String(format: "Your planet had to back off to %.1f AU — closer in it would be cooked, or swallowed.", distanceAU)
        } else {
            where_ = String(format: "Your planet had to back off to %.0f AU, well past where Jupiter orbits.", distanceAU)
        }
        let size: String
        let t = timesOurSun
        if t > 1.6 {
            size = String(format: "From there the star still looks %.0f times wider than our Sun does", t)
        } else if t > 0.75 {
            size = "From there it looks about the size our Sun does"
        } else if t > 0.08 {
            size = String(format: "From there it is only %.0f%% the width of our Sun", t * 100)
        } else {
            size = "From there it is a hard little point, far smaller than our Sun looks"
        }
        let light: String
        if insolation > 3 {
            light = String(format: "and pours %.0f times Earth's daylight down. Nothing else will be visible.", insolation)
        } else if insolation > 0.3 {
            light = String(format: "and gives about %.0f%% of Earth's daylight. Daytime here is daytime.", insolation * 100)
        } else if insolation > 0.01 {
            light = String(format: "and gives %.1f%% of Earth's daylight — a permanent dim afternoon.", insolation * 100)
        } else {
            light = String(format: "and gives only %.2f%% of Earth's daylight. Its day is darker than our dusk, so the galaxy never quite leaves the sky.", insolation * 100)
        }
        return where_ + "\n" + size + " " + light
    }
}

import simd
import Foundation

// ===================================================================
//  Relativity.swift — CPU side of the special-relativistic cockpit.
//
//  Two things live here:
//    1. `RelativityUniforms`, mirroring the struct in Relativity.metal.
//    2. `FlightCamera`, a free-look cockpit camera that travels at a
//       chosen beta, plus CPU ports of the shader maths (`Relativity`)
//       for the HUD and for testing the shader against something.
//
//  CONVENTIONS — identical to Relativity.metal, repeated here so the two
//  files can be checked against each other without cross-referencing:
//
//    n  = direction FROM the observer TO the star, in the REST frame
//         (the line of sight, not the photon's direction of travel).
//    cosTheta = dot(n, boostDir); theta = 0 is dead ahead.
//
//    aberration : cos(theta') = (cosTheta + beta)/(1 + beta*cosTheta)
//                 sin(theta') = sinTheta/(gamma*(1 + beta*cosTheta))
//                 -> stars bunch TOWARD the direction of travel.
//    doppler    : D = gamma*(1 + beta*cosTheta)        [rest-frame angle]
//                   = 1/(gamma*(1 - beta*cos(theta'))) [aberrated angle]
//                 -> D > 1 ahead (blue), D < 1 astern (red).
//                 D(0)    = sqrt((1+beta)/(1-beta))
//                 D(pi)   = sqrt((1-beta)/(1+beta))
//                 D = 1/gamma at APPARENT 90 deg (transverse redshift);
//                 D = gamma   at REST-FRAME 90 deg.
//    beaming    : surface brightness D^4; per-point-source flux D^2.
//                 See the long note in Relativity.metal.
//    colour     : T' = D*T, re-evaluated on the Planckian locus.
// ===================================================================

// MARK: - Uniforms

/// Must match `RelativityUniforms` in Relativity.metal byte for byte.
/// Two float4s = 32 bytes, 16-byte aligned.
struct RelativityUniforms {
    /// xyz = normalised direction of motion, w = beta (0..0.9999)
    var boost: SIMD4<Float> = SIMD4(0, 0, -1, 0)
    /// x = enabled (0/1), y = dopplerStrength, z = beamingStrength,
    /// w = aberrationStrength
    var params: SIMD4<Float> = SIMD4(0, 1, 1, 1)
}

// MARK: - Physics (CPU port of Relativity.metal)

/// CPU mirror of the shader maths. Same constants, same branches, same
/// clamps — if these two ever disagree it is a bug in one of them.
enum Relativity {

    // ---- units -------------------------------------------------------
    //
    //   1 kpc = 3.0856775814913673e16 km
    //   1 Myr = 3.15576e13 s   (Julian year)
    //   => 1 kpc/Myr = 3.0856775814913673e16 / 3.15576e13 = 977.79 km/s
    //   => c = 299792.458 / 977.79 = 306.60209... kpc/Myr
    //
    // which rounds to the 306.6 kpc/Myr quoted in the brief.
    static let cKmS: Double = 299_792.458
    static let cKpcPerMyr: Double = 299_792.458 / Units.kmsPerSpeedUnit   // 306.6021

    static let betaMax: Float = 0.9999
    static let dMin: Float = 1.0e-3
    static let dMax: Float = 2.0e2
    static let beamMax: Float = 1.0e5

    /// See the beaming note in Relativity.metal: 2 is the correct per-sprite
    /// exponent once star positions are aberrated; 4 is the sky-brightness law.
    static let beamingExponent: Float = 2.0

    static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    // ---- blackbody fit coefficients ----------------------------------
    // Planckian locus in CIE xy as a degree-6 polynomial in w = 1000 K / T,
    // highest power first. Fitted to Kim et al. (2002) over 1667-25000 K,
    // to integrated Planck x CIE-1931 outside it, and anchored at w = 0 on
    // the exact Rayleigh-Jeans chromaticity.
    static let locusX: [Float] = [ 0.132082865, -1.89386094, 5.44445801,
                                  -6.24501181,   2.7959342,  0.167333841,
                                   0.241708621]
    static let locusY: [Float] = [ 4.45352125, -16.6438656, 23.750536,
                                 -15.456974,    3.72725964, 0.288324267,
                                   0.235529765]
    // Clamped inside the fit's ground-truth range (which stops at 900 K);
    // the degree-6 polynomial turns over if extrapolated past it.
    static let wMax: Float = 1.0        // => T >= 1000 K
    static let tMin: Float = 1000
    static let tMax: Float = 1.0e6

    // 4/4 rational inverse, highest power of n first.
    static let invNum: [Float] = [0.0255964436, -0.0972754434, 0.0464995727,
                                 -0.0166741982,  0.180966571]
    static let invDen: [Float] = [-0.159533799, -0.195696369, 0.7680673,
                                   1.15803206,   1.0]
    static let nMin: Float = -1.82
    static let nMax: Float =  1.79

    static let wienA: Float = 25923.0        // hc/(k * 555 nm), kelvin
    static let bbPeakT: Float = 6611.8       // wienA / 3.92069
    static let bbPeakL: Float = 3.9004       // log(exp(3.92069) - 1)

    // ---- kinematics ---------------------------------------------------

    static func clampBeta(_ beta: Float) -> Float { min(max(beta, 0), betaMax) }

    static func gamma(_ beta: Float) -> Float {
        let b = clampBeta(beta)
        return 1 / (max(1 - b * b, 1e-9)).squareRoot()
    }

    struct AberrationFrame {
        var axis  = SIMD3<Float>(0, 0, 1)
        var perp  = SIMD3<Float>(1, 0, 0)
        var cosT: Float  = 1
        var sinT: Float  = 0
        var cosTp: Float = 1
        var sinTp: Float = 0
        var valid = false
    }

    static func aberrationFrame(restDir: SIMD3<Float>,
                                boostDir: SIMD3<Float>,
                                beta: Float) -> AberrationFrame {
        var f = AberrationFrame()
        let b = clampBeta(beta)
        let lb = simd_length(boostDir)
        guard b >= 1e-7, lb >= 1e-7 else { return f }
        f.axis = boostDir / lb

        let ln = simd_length(restDir)
        guard ln >= 1e-12 else { return f }
        let n = restDir / ln

        let c = min(max(simd_dot(n, f.axis), -1), 1)
        let p = n - c * f.axis
        let s = simd_length(p)
        // theta = 0 or pi: poles map to themselves, and there is no rotation
        // plane to normalise. Bailing out here is what keeps this NaN-free.
        guard s >= 1e-6 else { return f }

        let denom = 1 + b * c                     // >= 1 - beta > 0
        f.perp  = p / s
        f.cosT  = c
        f.sinT  = s
        f.cosTp = (c + b) / denom
        // exact; sqrt(1 - cosTp^2) would lose all precision near the pole
        f.sinTp = s / (gamma(b) * denom)
        f.valid = true
        return f
    }

    /// Apparent direction of a star seen by the moving observer.
    /// Exact physics, no dials. `restDir` points observer -> star.
    static func aberrate(restDir: SIMD3<Float>,
                         boostDir: SIMD3<Float>,
                         beta: Float) -> SIMD3<Float> {
        let f = aberrationFrame(restDir: restDir, boostDir: boostDir, beta: beta)
        guard f.valid else { return safeNormalize(restDir) }
        return simd_normalize(f.cosTp * f.axis + f.sinTp * f.perp)
    }

    /// Aberration dialled 0..1 by interpolating the angle. 1.0 is exact.
    static func aberrate(restDir: SIMD3<Float>,
                         boostDir: SIMD3<Float>,
                         beta: Float,
                         strength: Float) -> SIMD3<Float> {
        let a = min(max(strength, 0), 1)
        let f = aberrationFrame(restDir: restDir, boostDir: boostDir, beta: beta)
        guard f.valid, a > 0 else { return safeNormalize(restDir) }
        if a >= 1 { return simd_normalize(f.cosTp * f.axis + f.sinTp * f.perp) }
        let th  = atan2(f.sinT,  f.cosT)
        let thp = atan2(f.sinTp, f.cosTp)
        let t   = th + (thp - th) * a
        return simd_normalize(cos(t) * f.axis + sin(t) * f.perp)
    }

    /// D = nu_obs/nu_rest = gamma (1 + beta cos theta), rest-frame angle.
    static func doppler(restDir: SIMD3<Float>,
                        boostDir: SIMD3<Float>,
                        beta: Float) -> Float {
        let b = clampBeta(beta)
        let lb = simd_length(boostDir)
        let ln = simd_length(restDir)
        guard b >= 1e-7, lb >= 1e-7, ln >= 1e-12 else { return 1 }
        let c = min(max(simd_dot(restDir / ln, boostDir / lb), -1), 1)
        return min(max(gamma(b) * (1 + b * c), dMin), dMax)
    }

    static func doppler(restDir: SIMD3<Float>, boostDir: SIMD3<Float>,
                        beta: Float, strength: Float) -> Float {
        let s = min(max(strength, 0), 1)
        guard s > 0 else { return 1 }
        let d = doppler(restDir: restDir, boostDir: boostDir, beta: beta)
        if s >= 1 { return d }
        return min(max(pow(max(d, dMin), s), dMin), dMax)
    }

    // ---- beaming ------------------------------------------------------

    /// Bolometric beaming factor D^4 (surface-brightness law), clamped.
    static func beaming(_ D: Float) -> Float {
        let d = min(max(D, dMin), dMax)
        let d2 = d * d
        return min(max(d2 * d2, 0), beamMax)
    }

    /// Per-point-source flux law for a moving observer, static stars: D^2.
    static func beamingPointSource(_ D: Float) -> Float {
        let d = min(max(D, dMin), dMax)
        return min(max(d * d, 0), beamMax)
    }

    static func beaming(_ D: Float, strength: Float, exponent: Float) -> Float {
        let s = min(max(strength, 0), 1)
        guard s > 0 else { return 1 }
        let d = min(max(D, dMin), dMax)
        return min(max(pow(d, exponent * s), 0), beamMax)
    }

    // ---- blackbody ----------------------------------------------------

    private static func poly(_ c: [Float], _ t: Float) -> Float {
        var r = c[0]
        for i in 1..<c.count { r = r * t + c[i] }
        return r
    }

    /// Blackbody colour in linear sRGB, normalised to unit luminance.
    /// Brightness is not encoded here — beaming owns brightness.
    static func blackbodyRGB(_ T: Float) -> SIMD3<Float> {
        let w = min(max(1000.0 / max(T, 1), 0), wMax)
        let x = poly(locusX, w)
        let y = max(poly(locusY, w), 1e-4)

        let X = x / y
        let Y: Float = 1
        let Z = (1 - x - y) / y

        var rgb = SIMD3<Float>( 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z,
                               -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z,
                                0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z)
        rgb = simd_max(rgb, .zero)
        let l = max(simd_dot(rgb, luma), 1e-6)
        return rgb / l
    }

    /// Approximate inverse of `blackbodyRGB`. See the shader for the method
    /// and the accuracy statement (2.2e-4 relative over 2000-20000 K).
    static func bbTemperatureFromRGB(_ rgb: SIMD3<Float>) -> Float {
        let c = simd_max(rgb, .zero)
        let X = 0.4124564 * c.x + 0.3575761 * c.y + 0.1804375 * c.z
        let Y = 0.2126729 * c.x + 0.7151522 * c.y + 0.0721750 * c.z
        let Z = 0.0193339 * c.x + 0.1191920 * c.y + 0.9503041 * c.z
        let s = X + Y + Z
        guard s >= 1e-9 else { return bbPeakT }

        let x = X / s
        let y = Y / s
        // Always negative on the locus; forcing it keeps the sign of n
        // meaningful for colours that stray off the locus.
        let den = min(0.1858 - y, -1e-4)
        let n = min(max((x - 0.3320) / den, nMin), nMax)

        let num = poly(invNum, n)
        let dnm = poly(invDen, n)
        let w = num / (abs(dnm) < 1e-6 ? 1e-6 : dnm)
        return min(max(1000.0 / max(w, 1e-6), tMin), tMax)
    }

    /// log of the relative luminous efficiency of a blackbody, peaking at
    /// 6612 K. This is what makes extreme shifts fade instead of merely
    /// changing hue. See the shader for the derivation and accuracy.
    static func logVisibleFraction(_ T: Float) -> Float {
        let t = min(max(T, 1), 1e9)
        let xx = wienA / t
        let lem1: Float
        if xx > 20 {
            lem1 = xx
        } else if xx < 0.05 {
            lem1 = log(xx * (1 + xx * (0.5 + xx * (1.0 / 6.0))))
        } else {
            lem1 = log(exp(xx) - 1)
        }
        return bbPeakL + 4 * log(bbPeakT / t) - lem1
    }

    static func visibleFraction(_ T: Float) -> Float {
        exp(min(max(logVisibleFraction(T), -60), 0))
    }

    /// Spectrally shifted colour: T' = D*T re-evaluated on the Planckian
    /// locus, times the change in the visible fraction eta(T')/eta(T).
    /// Carries the input's luminance; it does NOT include beaming.
    static func shiftColour(_ rgb: SIMD3<Float>, _ D: Float) -> SIMD3<Float> {
        let d = min(max(D, dMin), dMax)
        let T = bbTemperatureFromRGB(rgb)
        let Tp = min(max(d * T, 1), 1e9)

        let c0 = blackbodyRGB(T)
        let c1 = blackbodyRGB(Tp)

        let floorC = SIMD3<Float>(repeating: 0.02)
        let ratio = simd_clamp(simd_max(c1, floorC) / simd_max(c0, floorC),
                               SIMD3<Float>(repeating: 0),
                               SIMD3<Float>(repeating: 50))

        let viaRatio = rgb * ratio
        let viaBB = c1 * max(simd_dot(rgb, luma), 0)

        let wgt = min(max(abs(log(d)) / 1.0986123, 0), 1)
        let outc = viaRatio + (viaBB - viaRatio) * wgt

        let band = exp(min(max(logVisibleFraction(Tp) - logVisibleFraction(T),
                               -18), 9))
        return simd_max(outc * band, .zero)
    }

    static func shiftColour(_ rgb: SIMD3<Float>, _ D: Float,
                            strength: Float) -> SIMD3<Float> {
        let s = min(max(strength, 0), 1)
        guard s > 0 else { return rgb }
        if s >= 1 { return shiftColour(rgb, D) }
        let de = pow(min(max(D, dMin), dMax), s)
        let shifted = shiftColour(rgb, de)
        return rgb + (shifted - rgb) * s
    }

    // ---- misc ----------------------------------------------------------

    static func safeNormalize(_ v: SIMD3<Float>,
                              fallback: SIMD3<Float> = SIMD3(0, 0, -1)) -> SIMD3<Float> {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : fallback
    }
}

// MARK: - Flight camera

/// Cockpit flight camera: free-look while travelling at relativistic speed.
///
/// Look direction (yaw/pitch) and travel direction are independent, which is
/// the whole point — the interesting view is the one where you are looking
/// 90 degrees off your heading and can see the sky bunched up on one side.
///
/// TIME. `update(dt:)` is fed real wall-clock seconds, not simulation Myr.
/// At true c you cross a 30 kpc galaxy in 30/306.6 = 0.098 Myr, so running
/// the flight on simulation time would be a single unwatchable frame.
/// `flightTimeScale` maps wall-clock to coordinate time:
///
///     kpc travelled per real second = beta * c * flightTimeScale
///
/// There is no honest way to make this real time. Crossing a 30 kpc disk takes
///     t = D / (beta c) = 30 / (beta * 306.6) Myr ~= 98,000 years
/// even at light speed, and the ship's own clock only divides that by gamma:
/// 13,900 years at beta = 0.99. Crossing in half a minute of proper time would
/// need gamma ~ 1e11, and LHC protons reach about 7,000.
///
/// So the flight is time-compressed, and the HUD says so rather than pretending
/// otherwise. The default 0.0065 Myr per real second gives a 30 kpc crossing in
/// about 15 seconds at beta = 0.99 — long enough to look around, short enough
/// to stay a flight.
///
/// This scaling touches ONLY how fast the ship moves through space. The
/// optics — aberration, Doppler, beaming, colour — are computed from `beta`
/// alone and are exactly correct for that beta at every setting of
/// `flightTimeScale`. Slowing the flight down does not slow light down.
final class FlightCamera {

    // MARK: position and motion

    var position: SIMD3<Float> = SIMD3(0, 0, 260)

    /// Speed as a fraction of c. Clamped to 0.9999 (gamma = 70.7); beyond
    /// that float32 stops being able to represent 1 - beta usefully.
    var beta: Float = 0.5 {
        didSet { beta = min(max(beta, 0), Relativity.betaMax) }
    }

    /// True speed for the HUD, in km/s. Not affected by `flightTimeScale`.
    var speedKmS: Double { Double(beta) * Relativity.cKmS }

    /// Lorentz factor.
    var gamma: Float { Relativity.gamma(beta) }

    /// Myr of coordinate (galaxy-frame) time per real wall-clock second.
    /// See the class note. Raise it to fly faster in real terms.
    var flightTimeScale: Float = 0.0065

    /// Where the ship is actually going. Always kept normalised.
    var travelDirection: SIMD3<Float> {
        get { storedTravel }
        set {
            storedTravel = Relativity.safeNormalize(newValue, fallback: storedTravel)
            reorthogonaliseUp()
        }
    }
    private var storedTravel = SIMD3<Float>(0, 0, -1)

    // MARK: attitude

    /// The ship's own up, and with it the third axis a ship frame needs.
    ///
    /// Everything used to rebuild "up" from the world's Y every time it was
    /// asked for. That is fine until you want to *roll*: a frame derived from
    /// the world vertical has no roll to give, and it flips when the nose
    /// comes near the poles, because the vertical stops being a usable
    /// reference there. Storing the up vector fixes both, and it is what
    /// makes the stick's outer ring mean anything.
    ///
    /// Always perpendicular to `travelDirection`, and re-squared whenever the
    /// heading is set from outside.
    private(set) var shipUp = SIMD3<Float>(0, 1, 0)

    /// Completes the right-handed frame: `right = forward × up`, matching the
    /// convention the chase camera and the cabin already used.
    var shipRight: SIMD3<Float> {
        Relativity.safeNormalize(simd_cross(storedTravel, shipUp), fallback: SIMD3(1, 0, 0))
    }

    private func reorthogonaliseUp() {
        var up = shipUp - storedTravel * simd_dot(shipUp, storedTravel)
        if simd_length(up) < 1e-4 {
            // The stored up has collapsed onto the heading — someone set a
            // heading straight along the old up. Rebuild a level frame, which
            // is what a ship that has never rolled has anyway.
            let helper: SIMD3<Float> = abs(storedTravel.y) < 0.999 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
            let right = simd_normalize(simd_cross(storedTravel, helper))
            up = simd_cross(right, storedTravel)
        }
        shipUp = simd_normalize(up)
    }

    /// Steer left and right about the ship's own up. Positive turns right.
    func turn(_ amount: Float) {
        let q = simd_quatf(angle: -amount, axis: shipUp)
        storedTravel = simd_normalize(q.act(storedTravel))
    }

    /// Nose up and down about the ship's own right. Positive lifts the nose.
    func pitchTurn(_ amount: Float) {
        let q = simd_quatf(angle: amount, axis: shipRight)
        storedTravel = simd_normalize(q.act(storedTravel))
        shipUp = simd_normalize(q.act(shipUp))
    }

    /// Roll about the heading. Nothing but the frame moves.
    ///
    /// Rolling is free, physically: aberration, Doppler and beaming are all
    /// computed from the boost, and the boost is `travelDirection`, which roll
    /// leaves exactly where it was. The sky turns; the aberration bullseye
    /// stays nailed to the direction of travel, which is the honest answer
    /// and also the more interesting one to look at.
    func roll(_ amount: Float) {
        let q = simd_quatf(angle: amount, axis: storedTravel)
        shipUp = simd_normalize(q.act(shipUp))
    }

    // MARK: free look

    /// Yaw, radians. 0 looks down -Z, matching the project's right-handed,
    /// Y-up world. Increasing yaw turns the view toward +X (to the right).
    var yaw: Float = 0
    /// Pitch, radians, clamped just short of the poles so the up vector in
    /// `lookAtMatrix` never becomes degenerate.
    var pitch: Float = 0

    var fovY: Float = 75 * .pi / 180
    var lookSensitivity: Float = 0.005
    /// Flip if the drag feel comes out backwards for your input handling.
    var invertLookX: Bool = false
    var invertLookY: Bool = false

    // MARK: effect dials (see Relativity.metal — 1.0 is exact physics)

    var enabled: Bool = true
    var dopplerStrength: Float = 1
    var beamingStrength: Float = 1
    var aberrationStrength: Float = 1

    // MARK: odometers

    /// Coordinate (galaxy-frame) time elapsed, Myr.
    private(set) var coordinateTimeMyr: Double = 0
    /// Proper time on the ship's own clock, Myr. Runs slow by 1/gamma.
    private(set) var properTimeMyr: Double = 0
    /// Distance flown in the galaxy frame, kpc.
    private(set) var distanceTravelledKpc: Double = 0

    init() {}

    // MARK: derived directions

    /// Where the head is turned. Independent of `travelDirection`.
    var viewDirection: SIMD3<Float> {
        let cp = cos(pitch), sp = sin(pitch)
        return SIMD3(cp * sin(yaw), sp, -cp * cos(yaw))
    }

    /// Angle between where you are looking and where you are going, radians.
    /// 0 means the aberration bullseye is centred in the window.
    var lookOffAxisAngle: Float {
        acos(min(max(simd_dot(viewDirection, storedTravel), -1), 1))
    }

    // MARK: update

    /// Advance by `dt` REAL SECONDS (not simulation Myr).
    func update(dt: Float) {
        guard dt > 0, dt.isFinite else { return }
        let dtMyr = Double(dt) * Double(flightTimeScale)          // coordinate time
        let dist  = Double(beta) * Relativity.cKpcPerMyr * dtMyr  // kpc

        position += storedTravel * Float(dist)
        coordinateTimeMyr    += dtMyr
        properTimeMyr        += dtMyr / Double(gamma)
        distanceTravelledKpc += dist
    }

    // MARK: camera matrices

    func viewProjection(aspect: Float) -> float4x4 {
        // Particles are drawn additively with no depth test, so depth
        // precision is irrelevant here and the range can be generous.
        let proj = perspectiveMatrix(fovY: fovY, aspect: max(aspect, 1e-3),
                                     near: 0.05, far: 50_000)
        let view = lookAtMatrix(eye: position,
                                center: position + viewDirection,
                                up: SIMD3(0, 1, 0))
        return proj * view
    }

    /// Head translation in metres inside the cabin, independent of galactic kpc.
    /// Q/E lean sideways; this creates real parallax against nearby instruments.
    var cabinLean: Float = 0

    var cabinEye: SIMD3<Float> { SIMD3(cabinLean, 0, 0) }

    /// A ship frame follows travel, while mouse look remains an independent
    /// world-space direction. Project both gaze and camera-up into this frame.
    /// Cabin geometry never receives an aberration or Doppler transform.
    func cabinState(aspect: Float) -> CabinRenderState {
        let forward = travelDirection
        let right = shipRight
        let up = shipUp
        func local(_ d: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(simd_dot(d, right), simd_dot(d, up), -simd_dot(d, forward))
        }
        let look = local(viewDirection)
        let cameraUp = local(SIMD3(0, 1, 0))
        let projection = perspectiveMatrix(fovY: fovY, aspect: max(aspect, 0.001), near: 0.035, far: 30)
        return CabinRenderState(viewProjection: projection * lookAtMatrix(
            eye: cabinEye, center: cabinEye + look, up: cameraUp),
            eye: cabinEye, beta: beta, time: Float(coordinateTimeMyr / Double(max(flightTimeScale, 1e-9))))
    }

    // MARK: uniforms

    func uniforms() -> RelativityUniforms {
        var u = RelativityUniforms()
        u.boost = SIMD4(storedTravel, min(max(beta, 0), Relativity.betaMax))
        u.params = SIMD4(enabled ? 1 : 0,
                         min(max(dopplerStrength, 0), 1),
                         min(max(beamingStrength, 0), 1),
                         min(max(aberrationStrength, 0), 1))
        return u
    }

    // MARK: input

    /// Mouse look. `dx`/`dy` are raw NSEvent deltas.
    /// Signs follow the project's existing orbit camera (`Camera.drag`):
    /// drag right and the world swings right, drag down and the nose comes up.
    func look(dx: Float, dy: Float) {
        let sx: Float = invertLookX ? 1 : -1
        let sy: Float = invertLookY ? -1 : 1
        yaw   += sx * dx * lookSensitivity
        pitch += sy * dy * lookSensitivity

        if yaw >  .pi { yaw -= 2 * .pi }
        if yaw < -.pi { yaw += 2 * .pi }
        let lim: Float = .pi / 2 - 0.01
        pitch = min(max(pitch, -lim), lim)
    }

    /// Point the ship where you're looking.
    func setTravelDirectionToView() {
        travelDirection = viewDirection
    }

    /// Point the view back along the ship's heading (recentre the bullseye).
    func setViewToTravelDirection() {
        let d = storedTravel
        pitch = asin(min(max(d.y, -1), 1))
        yaw   = atan2(d.x, -d.z)
    }

    // MARK: HUD

    /// e.g. "beta 0.990 c · 296 794 km/s · gamma 7.09 · ship clock 7.09x slow"
    var timeDilationDisplay: String {
        let g = gamma
        return String(format: "β %.4f c · %.0f km/s · γ %.2f · ship clock %.2f× slow",
                      beta, speedKmS, g, g)
    }

    /// Myr of the ship's own clock per real wall-clock second.
    var properTimePerRealSecond: Float { flightTimeScale / gamma }

    /// Apparent angular radius, in radians, of the cone the ENTIRE rest-frame
    /// sky in front of the observer is squeezed into. (The whole forward
    /// hemisphere, theta <= pi/2, maps into theta' <= acos(beta).)
    var forwardHemisphereConeAngle: Float {
        acos(min(max(Relativity.clampBeta(beta), -1), 1))
    }

    /// CPU version of the shader transform, for HUD readouts and picking.
    func apparentDirection(of worldPosition: SIMD3<Float>) -> SIMD3<Float> {
        guard enabled else { return Relativity.safeNormalize(worldPosition - position) }
        return Relativity.aberrate(restDir: worldPosition - position,
                                   boostDir: storedTravel,
                                   beta: beta,
                                   strength: aberrationStrength)
    }

    func dopplerFactor(of worldPosition: SIMD3<Float>) -> Float {
        guard enabled else { return 1 }
        return Relativity.doppler(restDir: worldPosition - position,
                                  boostDir: storedTravel,
                                  beta: beta)
    }
}

// MARK: - Steering

extension FlightCamera {
    /// Swing the travel direction toward wherever the pilot is looking.
    ///
    /// Turn authority falls off as gamma rises, which is not an arbitrary game
    /// balance: changing the direction of a relativistic momentum vector takes
    /// an impulse proportional to gamma*m*v, so a ship at 0.99c is genuinely
    /// about seven times harder to turn than the same ship at rest. It also
    /// gives the mode its loop — slow down, come about, line up, run through
    /// the collision again.
    func steerTowardView(dt: Float, rate: Float = 1.6) {
        let target = viewDirection
        let current = storedTravelDirection
        let dot = simd_clamp(simd_dot(current, target), -1, 1)
        let angle = acos(dot)
        guard angle > 1e-4 else { return }

        let authority = rate / max(gamma, 1)
        let step = min(angle, authority * dt)

        // rotate `current` toward `target` by `step`, in their common plane
        let axis = simd_cross(current, target)
        let len = simd_length(axis)
        let perp: SIMD3<Float>
        if len > 1e-6 {
            perp = simd_normalize(simd_cross(axis / len, current))
        } else {
            // exactly opposed: any perpendicular will do
            let helper: SIMD3<Float> = abs(current.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            perp = simd_normalize(simd_cross(helper, current))
        }
        travelDirection = simd_normalize(current * cos(step) + perp * sin(step))
    }

    /// Angle between heading and view, in degrees — for HUD feedback.
    var headingOffsetDegrees: Float { lookOffAxisAngle * 180 / .pi }

    private var storedTravelDirection: SIMD3<Float> { travelDirection }
}


// MARK: - Honest time reporting

extension FlightCamera {
    /// Simulated years per real second at the current setting.
    var timeCompression: Double { Double(flightTimeScale) * 1e6 }

    /// How long crossing `kpc` really takes, and how long it takes aboard.
    func crossingTime(kpc: Double) -> (coordinateYears: Double, shipYears: Double) {
        let b = max(Double(beta), 1e-6)
        let myr = kpc / (b * Relativity.cKpcPerMyr)
        let years = myr * 1e6
        return (years, years / Double(gamma))
    }
}

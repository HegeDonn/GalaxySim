import simd
import Foundation

// =============================================================================
//  GalaxyModels
//  -------------------------------------------------------------------------
//  Analytic three-component galaxy potentials (Hernquist halo + Miyamoto-Nagai
//  disk + Hernquist bulge) and matching initial-condition generators.
//
//  Everything is in the G == 1 unit system declared in Types.swift:
//      length kpc, time Myr, mass 2.2229e11 Msun, speed 977.79 km/s.
// =============================================================================

// MARK: - Small helpers

@inline(__always) private func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    guard e1 > e0 else { return x >= e1 ? 1 : 0 }
    let t = min(1, max(0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}

@inline(__always) private func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
    min(hi, max(lo, x))
}

private let twoPi: Float = 2 * Float.pi

// MARK: - Per-type morphology configuration

/// Everything that distinguishes one Hubble type from another at the
/// initial-conditions level. Masses/lengths live in `PotentialParams`.
private struct Morphology {
    var haloFrac: Float = 0.05        // fraction of all particles that are halo tracers
    var spheroidFrac: Float = 0.10    // fraction that are bulge / spheroid stars
    var gasFrac: Float = 0.08         // fraction of the *disk* population that is gas
    var youngBase: Float = 0.05       // young-star probability in the inter-arm disk
    var youngArm: Float = 0.45        // extra young-star probability at arm peak

    // Logarithmic spiral: theta_arm(R) = phase0 + ln(R/R0) / tan(pitch)
    var armCount: Int = 2
    var pitchDeg: Float = 15
    var armAmplitude: Float = 0.0     // azimuthal density contrast, 0..1
    var armSharpness: Float = 2.0     // exponent on cos^2 profile: bigger = narrower
    var armScatter: Float = 0.10      // flocculent phase jitter, radians

    var barFrac: Float = 0.0          // fraction of disk particles on x1-like bar orbits
    var barRadiusFactor: Float = 1.5  // bar semi-major axis in units of the disk scale length

    var diskScaleFactor: Float = 0.80 // exponential Rd in units of Miyamoto-Nagai a
    var diskTrunc: Float = 5.0        // outer truncation in units of Rd
    var sigmaRFrac: Float = 0.10      // sigma_R / v_circ at 2.2 Rd
    var vRotFrac: Float = 1.0         // fraction of the asymmetric-drift-corrected v_phi
    var thicknessFactor: Float = 1.0  // multiplies Miyamoto-Nagai b to give the sech^2 scale height
}

// MARK: - GalaxyModels

public enum GalaxyModels {

    // MARK: Deterministic PRNG

    /// RNG (Steele, Lea & Flood 2014 / Vigna). Small, fast, and — most
    /// importantly here — reproducible: the same seed always yields the same stream.
    public struct RNG {
        @usableFromInline var state: UInt64
        @usableFromInline var gaussCache: Float = 0
        @usableFromInline var hasGauss: Bool = false

        public init(seed: UInt64) {
            // Avalanche the incoming seed so that adjacent seeds (0, 1, 2 …) do not
            // produce correlated streams.
            var z = seed &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            state = z ^ (z >> 31)
        }

        @inlinable @inline(__always)
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1) with 24 bits of mantissa.
        @inlinable @inline(__always)
        public mutating func uniform() -> Float {
            Float(next() >> 40) * (1.0 / 16_777_216.0)
        }

        /// Uniform in (0, 1] — safe to take a logarithm of.
        @inlinable @inline(__always)
        public mutating func positiveUniform() -> Float {
            Float((next() >> 40) &+ 1) * (1.0 / 16_777_216.0)
        }

        @inlinable @inline(__always)
        public mutating func uniform(_ lo: Float, _ hi: Float) -> Float {
            lo + (hi - lo) * uniform()
        }

        /// Marsaglia polar method; the second variate of each pair is cached.
        @inlinable @inline(__always)
        public mutating func gaussian() -> Float {
            if hasGauss { hasGauss = false; return gaussCache }
            var u: Float = 0, v: Float = 0, s: Float = 0
            repeat {
                u = uniform(-1, 1)
                v = uniform(-1, 1)
                s = u * u + v * v
            } while s >= 1 || s < 1e-12
            let f = sqrtf(-2 * logf(s) / s)
            gaussCache = v * f
            hasGauss = true
            return u * f
        }

        /// Gaussian truncated at ±3σ — keeps IC generators free of runaway tails.
        @inlinable @inline(__always)
        public mutating func clampedGaussian() -> Float {
            min(3, max(-3, gaussian()))
        }
    }


    // -------------------------------------------------------------------------
    // MARK: Potentials
    // -------------------------------------------------------------------------

    /// Fiducial three-component potential for a galaxy type, scaled by the spec.
    ///
    /// The Sb reference is a Milky Way analogue:
    ///   halo  Hernquist  M = 4.00,  a = 32 kpc
    ///   disk  Miyamoto-Nagai M = 0.25, a = 3.5 kpc, b = 0.3 kpc
    ///   bulge Hernquist  M = 0.05,  a = 0.6 kpc
    /// giving v_c(8 kpc) = 0.220 (215 km/s) and a curve flat to ±3% over 4–20 kpc.
    ///
    /// Note on the halo scale: the brief quotes "20 kpc", which is the NFW
    /// scale radius of the Milky Way. A Hernquist sphere matched to an NFW
    /// halo of concentration ~10 has a = r_s * sqrt(2[ln(1+c) - c/(1+c)]) ≈ 1.7 r_s,
    /// i.e. ~34 kpc. Using a = 32 kpc with M = 4.0 (total 4.3 mass units, exactly
    /// the 9.5e11 Msun quoted in Types.swift) reproduces the requested 215 km/s;
    /// a = 20 kpc with the same mass would give 257 km/s.
    public static func potential(for spec: GalaxySpec) -> PotentialParams {
        var p = fiducialPotential(spec.type)
        let m = max(1e-6, spec.massScale)
        let r = max(1e-6, spec.radiusScale)
        p.haloMass *= m;  p.haloScale *= r
        p.diskMass *= m;  p.diskA *= r; p.diskB *= r
        p.bulgeMass *= m; p.bulgeScale *= r
        return p
    }

    private static func fiducialPotential(_ type: GalaxyType) -> PotentialParams {
        switch type {
        case .sa:
            // Early-type spiral: massive bulge, compact disk.
            return PotentialParams(haloMass: 4.2, haloScale: 32,
                                   diskMass: 0.20, diskA: 3.0, diskB: 0.32,
                                   bulgeMass: 0.14, bulgeScale: 0.9)
        case .sb:
            // Milky Way analogue — the reference model.
            return PotentialParams(haloMass: 4.0, haloScale: 32,
                                   diskMass: 0.25, diskA: 3.5, diskB: 0.30,
                                   bulgeMass: 0.05, bulgeScale: 0.6)
        case .sc:
            // Late-type: nearly bulgeless, extended disk, lighter halo.
            return PotentialParams(haloMass: 3.0, haloScale: 30,
                                   diskMass: 0.22, diskA: 4.4, diskB: 0.28,
                                   bulgeMass: 0.015, bulgeScale: 0.5)
        case .sbb:
            return PotentialParams(haloMass: 4.0, haloScale: 32,
                                   diskMass: 0.25, diskA: 3.6, diskB: 0.30,
                                   bulgeMass: 0.07, bulgeScale: 0.8)
        case .sbc:
            return PotentialParams(haloMass: 3.1, haloScale: 30,
                                   diskMass: 0.23, diskA: 4.2, diskB: 0.28,
                                   bulgeMass: 0.03, bulgeScale: 0.6)
        case .e0:
            // Stellar body carried entirely by the "bulge" Hernquist component.
            return PotentialParams(haloMass: 5.0, haloScale: 40,
                                   diskMass: 0.0, diskA: 1.0, diskB: 1.0,
                                   bulgeMass: 0.60, bulgeScale: 3.6)
        case .e5:
            return PotentialParams(haloMass: 4.6, haloScale: 38,
                                   diskMass: 0.0, diskA: 1.0, diskB: 1.0,
                                   bulgeMass: 0.52, bulgeScale: 3.2)
        case .s0:
            // Lenticular: big bulge, smooth gas-poor disk, no arms.
            return PotentialParams(haloMass: 4.0, haloScale: 32,
                                   diskMass: 0.20, diskA: 3.2, diskB: 0.55,
                                   bulgeMass: 0.26, bulgeScale: 1.3)
        case .irr:
            return PotentialParams(haloMass: 0.9, haloScale: 14,
                                   diskMass: 0.045, diskA: 2.4, diskB: 0.60,
                                   bulgeMass: 0.004, bulgeScale: 0.5)
        case .dwarf:
            // ~1/50 the mass of the Sb reference (4.3 -> 0.086 mass units).
            return PotentialParams(haloMass: 0.078, haloScale: 6.0,
                                   diskMass: 0.0, diskA: 1.0, diskB: 1.0,
                                   bulgeMass: 0.008, bulgeScale: 0.75)
        case .ring:
            return PotentialParams(haloMass: 3.4, haloScale: 30,
                                   diskMass: 0.22, diskA: 4.0, diskB: 0.25,
                                   bulgeMass: 0.03, bulgeScale: 0.7)
        }
    }

    /// Circular speed of the analytic potential at cylindrical radius R in the
    /// disk plane (z = 0), from the exact dPhi/dR of all three components:
    ///
    ///   Hernquist   dPhi/dr = M / (r + a)^2
    ///   Miyamoto-Nagai (z = 0)
    ///               dPhi/dR = M R / (R^2 + (a + b)^2)^{3/2}
    ///
    ///   v_c^2 = R * dPhi_total/dR
    public static func circularSpeed(_ p: PotentialParams, radius: Float) -> Float {
        let r = max(radius, 1e-5)

        // Hernquist halo.
        let dh = p.haloMass / ((r + p.haloScale) * (r + p.haloScale))
        // Hernquist bulge.
        let db = p.bulgeMass / ((r + p.bulgeScale) * (r + p.bulgeScale))
        // Miyamoto-Nagai disk in its own plane: sqrt(z^2 + b^2) -> b.
        let ab = p.diskA + p.diskB
        let s = r * r + ab * ab
        let dd = p.diskMass * r / (s * sqrtf(s))

        let v2 = r * (dh + db + dd)
        return v2 > 0 ? sqrtf(v2) : 0
    }

    /// Spherically-averaged dPhi/dr, used for the pressure-supported components.
    /// The disk is included through its in-plane monopole, which is an adequate
    /// proxy at the radii where spheroid stars live.
    @inline(__always)
    private static func sphericalGravity(_ p: PotentialParams, _ radius: Float) -> Float {
        let r = max(radius, 1e-5)
        let dh = p.haloMass / ((r + p.haloScale) * (r + p.haloScale))
        let db = p.bulgeMass / ((r + p.bulgeScale) * (r + p.bulgeScale))
        let ab = p.diskA + p.diskB
        let s = r * r + ab * ab
        let dd = p.diskMass * r / (s * sqrtf(s))
        return dh + db + dd
    }

    // -------------------------------------------------------------------------
    // MARK: Generation entry point
    // -------------------------------------------------------------------------

    /// Generate initial conditions in WORLD space: positions/velocities already
    /// rotated into the spec's spinAxis frame and offset by spec.position/velocity.
    public static func generate(_ spec: GalaxySpec) -> [ParticleSeed] {
        var particles: [ParticleSeed] = []
        particles.reserveCapacity(max(0, spec.particleCount))
        generate(spec) { particles.append($0) }
        return particles
    }

    /// Emit initial conditions synchronously in the same deterministic order as
    /// `generate(_:)`, without allocating a particle-sized intermediate array.
    /// The callback is never retained; callers can write directly into a GPU
    /// buffer. Only fixed-size kinematics tables are allocated while generating.
    public static func generate(_ spec: GalaxySpec, emit: (ParticleSeed) -> Void) {
        guard spec.particleCount > 0 else { return }
        // Emitter stores the callback only for this synchronous generation call.
        withoutActuallyEscaping(emit) { output in
            generateStreaming(spec, emit: output)
        }
    }

    private static func generateStreaming(_ spec: GalaxySpec,
                                          emit: @escaping (ParticleSeed) -> Void) {
        let p = potential(for: spec)
        let morph = morphology(for: spec.type)
        // The stream depends on spec.seed alone, so identical specs replay exactly.
        var rng = RNG(seed: spec.seed)

        var emitter = Emitter(spinAxis: spec.spinAxis,
                              origin: spec.position,
                              bulk: spec.velocity, emit: emit)

        let nHalo = Int(Float(spec.particleCount) * morph.haloFrac)
        let spin: Float = spec.retrograde ? -1 : 1

        switch spec.type {
        case .e0, .e5, .dwarf:
            let nBody = spec.particleCount - nHalo
            generateSpheroid(spec: spec, p: p, morph: morph,
                             count: nBody, spin: spin,
                             flattening: spec.type == .e5 ? 0.5 : 1.0,
                             rng: &rng, into: &emitter)
        case .irr:
            let nBody = spec.particleCount - nHalo
            generateIrregular(spec: spec, p: p, morph: morph,
                              count: nBody, spin: spin,
                              rng: &rng, into: &emitter)
        case .ring:
            let nSph = Int(Float(spec.particleCount) * morph.spheroidFrac)
            let nDisk = spec.particleCount - nHalo - nSph
            generateSpheroid(spec: spec, p: p, morph: morph,
                             count: nSph, spin: spin, flattening: 1.0,
                             rng: &rng, into: &emitter)
            generateRing(spec: spec, p: p, morph: morph,
                         count: nDisk, spin: spin, rng: &rng, into: &emitter)
        default:
            let nSph = Int(Float(spec.particleCount) * morph.spheroidFrac)
            let nDisk = spec.particleCount - nHalo - nSph
            generateSpheroid(spec: spec, p: p, morph: morph,
                             count: nSph, spin: spin, flattening: 1.0,
                             rng: &rng, into: &emitter)
            generateDisk(spec: spec, p: p, morph: morph,
                         count: nDisk, spin: spin, rng: &rng, into: &emitter)
        }

        generateHaloTracers(p: p, count: nHalo, rng: &rng, into: &emitter)
    }

    private static func morphology(for type: GalaxyType) -> Morphology {
        var m = Morphology()
        switch type {
        case .sa:
            m.haloFrac = 0.05; m.spheroidFrac = 0.26; m.gasFrac = 0.04
            m.youngBase = 0.02; m.youngArm = 0.30
            m.armCount = 2; m.pitchDeg = 10; m.armAmplitude = 0.70
            m.armSharpness = 3.0; m.armScatter = 0.06
            m.diskScaleFactor = 0.80; m.diskTrunc = 5.0
            m.sigmaRFrac = 0.11
        case .sb:
            m.haloFrac = 0.05; m.spheroidFrac = 0.12; m.gasFrac = 0.08
            m.youngBase = 0.04; m.youngArm = 0.45
            m.armCount = 2; m.pitchDeg = 15; m.armAmplitude = 0.72
            m.armSharpness = 2.4; m.armScatter = 0.10
            m.diskScaleFactor = 0.80; m.diskTrunc = 5.0
            m.sigmaRFrac = 0.10
        case .sc:
            m.haloFrac = 0.05; m.spheroidFrac = 0.035; m.gasFrac = 0.15
            m.youngBase = 0.09; m.youngArm = 0.55
            m.armCount = 2; m.pitchDeg = 25; m.armAmplitude = 0.60
            m.armSharpness = 1.5; m.armScatter = 0.42   // flocculent
            m.diskScaleFactor = 0.85; m.diskTrunc = 5.2
            m.sigmaRFrac = 0.085
        case .sbb:
            m.haloFrac = 0.05; m.spheroidFrac = 0.10; m.gasFrac = 0.07
            m.youngBase = 0.035; m.youngArm = 0.45
            m.armCount = 2; m.pitchDeg = 15; m.armAmplitude = 0.75
            m.armSharpness = 2.6; m.armScatter = 0.09
            m.barFrac = 0.26; m.barRadiusFactor = 1.6
            m.diskScaleFactor = 0.80; m.diskTrunc = 5.0
            m.sigmaRFrac = 0.10
        case .sbc:
            m.haloFrac = 0.05; m.spheroidFrac = 0.04; m.gasFrac = 0.13
            m.youngBase = 0.08; m.youngArm = 0.55
            m.armCount = 2; m.pitchDeg = 25; m.armAmplitude = 0.62
            m.armSharpness = 1.6; m.armScatter = 0.36
            m.barFrac = 0.22; m.barRadiusFactor = 1.5
            m.diskScaleFactor = 0.85; m.diskTrunc = 5.2
            m.sigmaRFrac = 0.09
        case .s0:
            // Lenticular: no arms at all, essentially gas-free, thick smooth disk.
            m.haloFrac = 0.06; m.spheroidFrac = 0.40; m.gasFrac = 0.012
            m.youngBase = 0.008; m.youngArm = 0.0
            m.armAmplitude = 0.0; m.armScatter = 0.0
            m.diskScaleFactor = 0.85; m.diskTrunc = 4.6
            m.sigmaRFrac = 0.14; m.thicknessFactor = 1.4
        case .e0, .e5:
            m.haloFrac = 0.10; m.spheroidFrac = 0.90; m.gasFrac = 0.005
            m.youngBase = 0.0; m.youngArm = 0.0
            m.armAmplitude = 0.0
        case .irr:
            m.haloFrac = 0.06; m.spheroidFrac = 0.02; m.gasFrac = 0.28
            m.youngBase = 0.16; m.youngArm = 0.55
            m.armAmplitude = 0.0; m.armScatter = 0.0
            m.diskScaleFactor = 1.0; m.diskTrunc = 3.6
            m.sigmaRFrac = 0.38; m.vRotFrac = 0.55; m.thicknessFactor = 2.2
        case .dwarf:
            m.haloFrac = 0.16; m.spheroidFrac = 0.84; m.gasFrac = 0.01
            m.youngBase = 0.0; m.armAmplitude = 0.0
        case .ring:
            m.haloFrac = 0.05; m.spheroidFrac = 0.07; m.gasFrac = 0.20
            m.youngBase = 0.05; m.youngArm = 0.60
            m.armAmplitude = 0.0; m.armScatter = 0.0
            m.diskScaleFactor = 0.85; m.diskTrunc = 5.0
            m.sigmaRFrac = 0.09
        }
        return m
    }

    // -------------------------------------------------------------------------
    // MARK: Emitter — local frame -> world frame
    // -------------------------------------------------------------------------

    /// Rotates galaxy-local coordinates (disk plane = local xy, spin along
    /// local +z) into world space and applies the bulk position/velocity offset.
    private struct Emitter {
        let e1: SIMD3<Float>
        let e2: SIMD3<Float>
        let e3: SIMD3<Float>
        let origin: SIMD3<Float>
        let bulk: SIMD3<Float>
        let emit: (ParticleSeed) -> Void

        init(spinAxis: SIMD3<Float>, origin: SIMD3<Float>, bulk: SIMD3<Float>,
             emit: @escaping (ParticleSeed) -> Void) {
            var n = spinAxis
            let len = simd_length(n)
            n = len > 1e-6 ? n / len : SIMD3<Float>(0, 1, 0)
            // Duff et al. (2017) branchless orthonormal basis — numerically
            // stable for every n, unlike naive cross-product constructions.
            let sign: Float = n.z >= 0 ? 1 : -1
            let a = -1 / (sign + n.z)
            let b = n.x * n.y * a
            e1 = SIMD3<Float>(1 + sign * n.x * n.x * a, sign * b, -sign * n.x)
            e2 = SIMD3<Float>(b, sign + n.y * n.y * a, -n.y)
            e3 = n
            self.origin = origin
            self.bulk = bulk
            self.emit = emit
        }

        @inline(__always)
        mutating func add(pos lp: SIMD3<Float>, vel lv: SIMD3<Float>,
                          color: SIMD3<Float>, size: Float, kind: ParticleKind) {
            let wp = origin + e1 * lp.x + e2 * lp.y + e3 * lp.z
            let wv = bulk + e1 * lv.x + e2 * lv.y + e3 * lv.z
            emit(ParticleSeed(position: wp, velocity: wv,
                                        color: color, size: size, kind: kind))
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Disk kinematics table
    // -------------------------------------------------------------------------

    /// Tabulated axisymmetric disk kinematics: circular speed, the epicyclic
    /// ratio sigma_phi^2/sigma_R^2 = kappa^2/(4 Omega^2), the radial dispersion
    /// profile and the asymmetric-drift-corrected mean streaming speed.
    private struct DiskKinematics {
        struct Local {
            var vc: Float
            var vphi: Float
            var sigR: Float
            var sigP: Float
            var sigZ: Float
            /// sech^2 scale height in vertical equilibrium with sigZ.
            var height: Float
        }

        let dr: Float
        let n: Int
        var vc: [Float]
        var vphi: [Float]
        var sigR: [Float]
        var sigP: [Float]
        var sigZ: [Float]
        var height: [Float]

        init(p: PotentialParams, rd: Float, rMax: Float, sigmaFrac: Float,
             vRotFrac: Float, hz: Float, n: Int = 640) {
            self.n = n
            self.dr = rMax * 1.15 / Float(n)
            vc = [Float](repeating: 0, count: n)
            vphi = [Float](repeating: 0, count: n)
            sigR = [Float](repeating: 0, count: n)
            sigP = [Float](repeating: 0, count: n)
            sigZ = [Float](repeating: 0, count: n)
            height = [Float](repeating: 0, count: n)

            // sigma_R(R) = sigma_0 exp(-R / 2Rd)  (so sigma_R^2 has scale length Rd,
            // matching the exponential surface density — this is what makes the
            // asymmetric-drift term below have a clean closed form).
            let rRef = 2.2 * rd
            let sigma0 = sigmaFrac * GalaxyModels.circularSpeed(p, radius: rRef) * expf(rRef / (2 * rd))

            for i in 0..<n {
                let r = (Float(i) + 0.5) * dr
                let v = GalaxyModels.circularSpeed(p, radius: r)
                vc[i] = v

                // kappa^2 / (4 Omega^2) = 0.5 * (1 + dln v_c / dln R)
                let h = max(0.01 * r, 1e-3)
                let vp = GalaxyModels.circularSpeed(p, radius: r + h)
                let vm = GalaxyModels.circularSpeed(p, radius: max(r - h, 1e-4))
                var dlnv: Float = 0
                if v > 1e-8 { dlnv = (vp - vm) / (2 * h) * r / v }
                let epi = clamp(0.5 * (1 + dlnv), 0.20, 1.0)

                var sR = sigma0 * expf(-r / (2 * rd))
                sR = min(sR, 0.35 * max(v, 1e-6))          // never let the disk go hot
                sR = max(sR, 1e-4)
                sigR[i] = sR
                sigP[i] = sR * sqrtf(epi)
                let sZ = 0.50 * sR                          // disks are radially hotter
                sigZ[i] = sZ

                // Vertical equilibrium. The vertical epicyclic frequency at z = 0,
                // nu^2 = d2Phi/dz2, is analytic for all three components:
                //   Hernquist      d2Phi/dz2 = M / (R (R + a)^2)
                //   Miyamoto-Nagai d2Phi/dz2 = M (a + b) / (b (R^2 + (a+b)^2)^{3/2})
                // In the harmonic approximation a population with dispersion sigma_z
                // has <z^2> = sigma_z^2 / nu^2, and a sech^2(z/h) layer has
                // rms z = h * pi / (2 sqrt3) = 0.9069 h. Choosing h from nu (rather
                // than fixing h and hoping) is what stops the disk from either
                // collapsing or puffing during the first few hundred Myr.
                let rSafe = max(r, 1e-3)
                let ab = p.diskA + p.diskB
                let dd = rSafe * rSafe + ab * ab
                var nu2 = p.diskMass * ab / (max(p.diskB, 1e-4) * dd * sqrtf(dd))
                nu2 += p.haloMass / (rSafe * (rSafe + p.haloScale) * (rSafe + p.haloScale))
                nu2 += p.bulgeMass / (rSafe * (rSafe + p.bulgeScale) * (rSafe + p.bulgeScale))
                let nu = sqrtf(max(nu2, 1e-12))
                // `hz` (from the Miyamoto-Nagai b) sets the allowed band, so the
                // requested thickness is honoured to within a factor of a few
                // while equilibrium picks the exact value and the natural flare.
                height[i] = clamp(sZ / (0.9069 * nu), 0.40 * hz, 3.0 * hz)

                // Asymmetric drift (Binney & Tremaine eq. 4.228) for
                // Sigma ∝ exp(-R/Rd) and sigma_R^2 ∝ exp(-R/Rd):
                //   v_c - <v_phi> = sigma_R^2 / (2 v_c) * [ epi - 1 + 2R/Rd ]
                var mean = v
                if v > 1e-6 {
                    let drift = sR * sR / (2 * v) * (epi - 1 + 2 * r / rd)
                    mean = max(0, v - max(0, drift))
                }
                vphi[i] = mean * vRotFrac
            }
        }

        @inline(__always)
        func sample(_ r: Float) -> Local {
            let x = r / dr - 0.5
            if x <= 0 { return at(0) }
            let i0 = Int(x)
            if i0 >= n - 1 { return at(n - 1) }
            let f = x - Float(i0)
            let g = 1 - f
            return Local(vc: vc[i0] * g + vc[i0+1] * f,
                         vphi: vphi[i0] * g + vphi[i0+1] * f,
                         sigR: sigR[i0] * g + sigR[i0+1] * f,
                         sigP: sigP[i0] * g + sigP[i0+1] * f,
                         sigZ: sigZ[i0] * g + sigZ[i0+1] * f,
                         height: height[i0] * g + height[i0+1] * f)
        }

        @inline(__always)
        private func at(_ i: Int) -> Local {
            Local(vc: vc[i], vphi: vphi[i], sigR: sigR[i],
                  sigP: sigP[i], sigZ: sigZ[i], height: height[i])
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Spherical Jeans dispersion table
    // -------------------------------------------------------------------------

    /// Isotropic 1-D velocity dispersion of a Hernquist tracer population
    /// embedded in the full potential, from the spherical Jeans equation
    ///     rho(r) sigma_r^2(r) = ∫_r^inf rho(s) dPhi/ds ds.
    /// Tabulated on a log grid; the tracer mass cancels, as it must.
    private struct SphericalJeans {
        let logRMin: Float
        let invDLog: Float
        let n: Int
        var sigma: [Float]

        init(tracerScale a: Float, p: PotentialParams, n: Int = 512) {
            self.n = n
            let rMin = max(a * 1e-3, 1e-4)
            let rMax = max(a * 400, p.haloScale * 40)
            logRMin = logf(rMin)
            let dLog = (logf(rMax) - logRMin) / Float(n - 1)
            invDLog = 1 / dLog

            var r = [Float](repeating: 0, count: n)
            var rho = [Float](repeating: 0, count: n)
            var f = [Float](repeating: 0, count: n)
            for k in 0..<n {
                let rk = expf(logRMin + Float(k) * dLog)
                r[k] = rk
                // Hernquist (1990) density, unit mass: rho = a / (2 pi r (r+a)^3)
                let d = rk + a
                rho[k] = a / (twoPi * rk * d * d * d)
                f[k] = rho[k] * GalaxyModels.sphericalGravity(p, rk)
            }

            sigma = [Float](repeating: 0, count: n)
            var integral: Float = f[n-1] * r[n-1] * 0.25   // small analytic-ish tail
            sigma[n-1] = rho[n-1] > 0 ? sqrtf(max(0, integral / rho[n-1])) : 0
            var k = n - 2
            while k >= 0 {
                integral += 0.5 * (f[k] + f[k+1]) * (r[k+1] - r[k])
                let s2 = rho[k] > 0 ? integral / rho[k] : 0
                sigma[k] = s2 > 0 ? sqrtf(s2) : 0
                k -= 1
            }
        }

        @inline(__always)
        func sigma(at r: Float) -> Float {
            let x = (logf(max(r, 1e-5)) - logRMin) * invDLog
            if x <= 0 { return sigma[0] }
            let i0 = Int(x)
            if i0 >= n - 1 { return sigma[n-1] }
            let f = x - Float(i0)
            return sigma[i0] * (1 - f) + sigma[i0+1] * f
        }
    }

    /// Hernquist inverse CDF: M(<r)/M = r^2/(r+a)^2  =>  r = a sqrt(u) / (1 - sqrt(u)).
    @inline(__always)
    private static func hernquistRadius(a: Float, u: Float) -> Float {
        let s = sqrtf(clamp(u, 0, 0.999999))
        return a * s / max(1e-6, 1 - s)
    }

    // -------------------------------------------------------------------------
    // MARK: Spiral arm density weighting
    // -------------------------------------------------------------------------

    /// Logarithmic spiral: an arm crest sits where
    ///     m * (phi - phase0 - ln(R/R0)/tan(i)) = 0 (mod 2 pi).
    /// The weight is a sharpened cos^2 lobe in 0..1 — used as a *density*
    /// weighting (rejection sampling in azimuth), never as a positional
    /// displacement, so the arms stay broad stellar structures rather than wires.
    private struct ArmProfile {
        let m: Float
        let invTanPitch: Float
        let r0: Float
        let amplitude: Float
        let sharpness: Float
        let scatter: Float
        let phase0: Float
        let rFadeIn: Float
        let rFadeOut: Float

        init(morph: Morphology, rd: Float, rMax: Float, r0: Float, phase0: Float) {
            m = Float(morph.armCount)
            let pitch = morph.pitchDeg * Float.pi / 180
            invTanPitch = 1 / tanf(max(pitch, 0.02))
            self.r0 = max(r0, 1e-3)
            amplitude = morph.armAmplitude
            sharpness = morph.armSharpness
            scatter = morph.armScatter
            self.phase0 = phase0
            rFadeIn = max(0.6 * r0, 0.35 * rd)
            rFadeOut = rMax
        }

        /// Normalised arm density weight in 0..1 at (R, phi).
        @inline(__always)
        func weight(_ r: Float, _ phi: Float, jitter: Float) -> Float {
            guard amplitude > 0 else { return 0 }
            let theta = phase0 + invTanPitch * logf(max(r, 1e-3) / r0)
            let d = m * (phi + jitter - theta)
            var w = 0.5 + 0.5 * cosf(d)
            if sharpness != 1 { w = powf(max(w, 0), sharpness) }
            // Arms exist only between the bar/inner Lindblad radius and the
            // outer disk; fade at both ends so nothing looks abruptly cut.
            w *= smoothstep(rFadeIn, rFadeIn * 2.0, r)
            w *= 1 - smoothstep(0.75 * rFadeOut, rFadeOut, r)
            return w
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Colour & size
    // -------------------------------------------------------------------------

    /// Linear HDR colour for a stellar population.
    /// `blueBias` in roughly -1..1 shifts along the stellar temperature
    /// sequence (positive = hotter/bluer).
    @inline(__always)
    private static func stellarColor(_ kind: ParticleKind, blueBias: Float,
                                     _ rng: inout RNG) -> SIMD3<Float> {
        let base: SIMD3<Float>
        var bright: Float
        let u = rng.uniform()
        switch kind {
        case .youngDisk:                       // OB associations: blue-white
            base = SIMD3<Float>(0.55, 0.72, 1.00); bright = 1.05 + 0.45 * u * u
        case .oldDisk:                         // old thin disk: yellow-white
            base = SIMD3<Float>(1.00, 0.92, 0.72); bright = 0.68 + 0.34 * u
        case .bulge:                           // metal-rich spheroid: warm orange-red
            base = SIMD3<Float>(1.00, 0.74, 0.45); bright = 0.62 + 0.40 * u
        case .gas:                             // faint cyan-teal HII / HI
            base = SIMD3<Float>(0.24, 0.62, 0.68); bright = 0.28 + 0.34 * u
        case .halo:                            // metal-poor tracers: dim grey-blue
            base = SIMD3<Float>(0.40, 0.45, 0.60); bright = 0.20 + 0.24 * u
        }
        // Per-particle temperature scatter so no population reads as flat colour.
        let t = clamp(blueBias + rng.gaussian() * 0.18, -0.9, 0.9)
        var c = SIMD3<Float>(base.x * (1 - 0.30 * t),
                             base.y * (1 + 0.04 * t),
                             base.z * (1 + 0.38 * t)) * bright
        // Small achromatic luminosity jitter.
        c *= 1 + rng.gaussian() * 0.07
        c = simd_max(c, SIMD3<Float>(repeating: 0))
        // Clamp by rescaling rather than per-channel, so hue survives the ceiling.
        let peak = max(c.x, max(c.y, c.z))
        if peak > 1.5 { c *= 1.5 / peak }
        return c
    }

    @inline(__always)
    private static func pointSize(_ kind: ParticleKind, _ rng: inout RNG) -> Float {
        let u = rng.uniform()
        switch kind {
        case .bulge:     return 0.42 + 0.38 * u
        case .oldDisk:   return 0.58 + 0.45 * u
        case .youngDisk: return 1.05 + 0.95 * u * u
        case .gas:       return 0.85 + 0.75 * u
        case .halo:      return 0.35 + 0.28 * u
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Disk generator (Sa, Sb, Sc, SBb, SBc, S0)
    // -------------------------------------------------------------------------

    private static func generateDisk(spec: GalaxySpec, p: PotentialParams,
                                     morph: Morphology, count: Int, spin: Float,
                                     rng: inout RNG, into e: inout Emitter) {
        guard count > 0 else { return }

        let rd = max(0.05, p.diskA * morph.diskScaleFactor)
        let rMax = rd * morph.diskTrunc
        let hz = max(0.02, p.diskB * morph.thicknessFactor)
        let kin = DiskKinematics(p: p, rd: rd, rMax: rMax,
                                 sigmaFrac: morph.sigmaRFrac, vRotFrac: morph.vRotFrac, hz: hz)

        let barRadius = morph.barFrac > 0 ? rd * morph.barRadiusFactor : 0
        // Spiral arms are anchored at the bar ends when a bar is present,
        // otherwise they wind out from ~1 scale length.
        let armR0 = morph.barFrac > 0 ? barRadius : rd
        let armPhase0 = rng.uniform(0, twoPi)
        let arms = ArmProfile(morph: morph, rd: rd, rMax: rMax, r0: armR0, phase0: armPhase0)
        // The bar is aligned to local x; arms leave from its ends, so phase0 for
        // the arm family is chosen relative to the bar's major axis.
        let barAngle: Float = 0

        let nBar = Int(Float(count) * morph.barFrac)
        let nSmooth = count - nBar

        // ---- bar: elongated x1-like orbits inside barRadius ------------------
        if nBar > 0 {
            for _ in 0..<nBar {
                // Nested ellipses, semi-major axis a, rounder towards the ends
                // of the bar family (real x1 orbits are most elongated inside).
                let a = barRadius * powf(rng.positiveUniform(), 0.55)
                let q = 0.30 + 0.30 * (a / max(barRadius, 1e-4))
                let t = rng.uniform(0, twoPi)
                let ct = cosf(t), st = sinf(t)
                var x = a * ct
                var y = q * a * st
                // Rotate into the bar frame (bar along local x).
                let cb = cosf(barAngle), sb = sinf(barAngle)
                let xr = x * cb - y * sb
                let yr = x * sb + y * cb
                x = xr; y = yr

                let aGeom = a * sqrtf(q)
                let k = kin.sample(aGeom)
                // Bars are vertically thick (boxy/peanut bulges).
                let z = k.height * 1.6 * atanhf(clamp(2 * rng.uniform() - 1, -0.9995, 0.9995))

                // Tangent to the ellipse, normalised.
                let dx0 = -a * st, dy0 = q * a * ct
                let dnorm = max(1e-6, sqrtf(dx0 * dx0 + dy0 * dy0))
                let dxr = dx0 * cb - dy0 * sb
                let dyr = dx0 * sb + dy0 * cb

                // Choose the speed so specific angular momentum matches the
                // circular value at the ellipse's geometric-mean radius.
                let speed = k.vphi * aGeom * dnorm / max(1e-6, q * a * a)
                var vx = spin * speed * dxr / dnorm
                var vy = spin * speed * dyr / dnorm
                let sig = 0.6 * k.sigR
                vx += rng.clampedGaussian() * sig
                vy += rng.clampedGaussian() * sig
                let vz = rng.clampedGaussian() * k.sigZ

                // Bars are old, metal-rich and gas-poor; a little star formation
                // survives at the ends where the arms attach.
                let endness = powf(abs(ct), 4)
                var kind: ParticleKind = .oldDisk
                let r1 = rng.uniform()
                if r1 < 0.10 * endness { kind = .youngDisk }
                else if r1 < 0.10 * endness + 0.03 { kind = .gas }
                else if rng.uniform() < 0.22 { kind = .bulge }

                let bias: Float = kind == .youngDisk ? 0.35 : -0.18
                e.add(pos: SIMD3<Float>(x, y, z),
                      vel: SIMD3<Float>(vx, vy, vz),
                      color: stellarColor(kind, blueBias: bias, &rng),
                      size: pointSize(kind, &rng),
                      kind: kind)
            }
        }

        // ---- smooth exponential disk with spiral density weighting -----------
        let innerCut = morph.barFrac > 0 ? barRadius * 0.85 : 0
        for _ in 0..<nSmooth {
            // Exponential surface density Sigma ∝ exp(-R/Rd) implies the radial
            // PDF R exp(-R/Rd), i.e. Gamma(shape 2, scale Rd) — exactly the sum
            // of two exponential variates. No rejection needed.
            var r: Float = 0
            var tries = 0
            repeat {
                r = -rd * (logf(rng.positiveUniform()) + logf(rng.positiveUniform()))
                tries += 1
            } while (r > rMax || r < innerCut) && tries < 24
            r = clamp(r, max(innerCut, 1e-3), rMax)

            // Azimuth by rejection against the arm weight: accept with
            // probability (1 - A) + A * w, whose maximum is 1.
            var phi: Float = 0
            var w: Float = 0
            if morph.armAmplitude > 0 {
                var n = 0
                repeat {
                    phi = rng.uniform(0, twoPi)
                    let jitter = morph.armScatter > 0 ? rng.gaussian() * morph.armScatter : 0
                    w = arms.weight(r, phi, jitter: jitter)
                    n += 1
                } while rng.uniform() > (1 - morph.armAmplitude) + morph.armAmplitude * w && n < 16
            } else {
                phi = rng.uniform(0, twoPi)
            }

            // Vertical: isothermal sheet rho ∝ sech^2(z/h), inverted exactly as
            // z = h * atanh(2u - 1), with h taken from vertical equilibrium so
            // the layer neither collapses nor puffs (it flares outward naturally).
            let k = kin.sample(r)
            let z = k.height * atanhf(clamp(2 * rng.uniform() - 1, -0.9995, 0.9995))

            // Population: young stars track the arms, gas likewise but colder.
            var kind: ParticleKind = .oldDisk
            let pYoung = min(0.95, morph.youngBase + morph.youngArm * w)
            let u = rng.uniform()
            if u < pYoung { kind = .youngDisk }
            else if u < pYoung + morph.gasFrac * (0.5 + 0.9 * w) { kind = .gas }

            // Young stars and gas are dynamically cold (they were born from it).
            let cold: Float = (kind == .oldDisk) ? 1.0 : 0.45
            let vR = rng.clampedGaussian() * k.sigR * cold
            let vP = k.vphi + rng.clampedGaussian() * k.sigP * cold
            let vZ = rng.clampedGaussian() * k.sigZ * cold

            let cp = cosf(phi), sp = sinf(phi)
            let x = r * cp, y = r * sp
            let vx = vR * cp - spin * vP * sp
            let vy = vR * sp + spin * vP * cp

            // Outer disks are bluer (lower metallicity, younger mean age).
            let bias = (kind == .youngDisk ? 0.30 : -0.05) + 0.25 * (r / rMax) + 0.20 * w
            e.add(pos: SIMD3<Float>(x, y, z),
                  vel: SIMD3<Float>(vx, vy, vZ),
                  color: stellarColor(kind, blueBias: bias, &rng),
                  size: pointSize(kind, &rng),
                  kind: kind)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Spheroid generator (bulges, E0/E5, dwarf)
    // -------------------------------------------------------------------------

    private static func generateSpheroid(spec: GalaxySpec, p: PotentialParams,
                                         morph: Morphology, count: Int, spin: Float,
                                         flattening q: Float,
                                         rng: inout RNG, into e: inout Emitter) {
        guard count > 0 else { return }
        let a = max(1e-3, p.bulgeScale)
        let jeans = SphericalJeans(tracerScale: a, p: p)
        // Truncate at 12 a: that is 85% of the Hernquist mass and ~6.6 effective
        // radii (R_e = 1.8153 a), beyond which the profile is only a faint tail
        // that would otherwise smear the spheroid over the whole disk.
        let rCut = a * 12
        let uMax = (rCut / (rCut + a)) * (rCut / (rCut + a))

        // Dwarf spheroidals get no streaming term at all: pressure supported.
        let isElliptical = (spec.type == .e0 || spec.type == .e5)
        // Flattened ellipticals are partly rotationally supported; the
        // v/sigma ≈ sqrt((1-q)/q) * 0.7 relation for oblate isotropic rotators
        // is a decent first-order stand-in.
        let vOverSigma: Float = q < 0.999 ? 0.70 * sqrtf((1 - q) / q) : 0

        for _ in 0..<count {
            // Hernquist inverse CDF.
            let r = hernquistRadius(a: a, u: rng.uniform() * uMax)
            // Isotropic direction.
            let cth = rng.uniform(-1, 1)
            let sth = sqrtf(max(0, 1 - cth * cth))
            let ph = rng.uniform(0, twoPi)
            let x = r * sth * cosf(ph)
            let y = r * sth * sinf(ph)
            var z = r * cth

            let sig = max(1e-5, jeans.sigma(at: r))
            var vx = rng.clampedGaussian() * sig
            var vy = rng.clampedGaussian() * sig
            var vz = rng.clampedGaussian() * sig

            if q < 0.999 {
                // Flatten along local z and shrink the vertical dispersion to
                // match; add azimuthal streaming so the figure is supported.
                z *= q
                vz *= q
                let rc = max(1e-4, sqrtf(x * x + y * y))
                let vstream = spin * vOverSigma * sig
                vx += -y / rc * vstream
                vy += x / rc * vstream
            } else if isElliptical {
                // Even "round" ellipticals rotate slowly.
                let rc = max(1e-4, sqrtf(x * x + y * y))
                let vstream = spin * 0.12 * sig
                vx += -y / rc * vstream
                vy += x / rc * vstream
            }

            var kind: ParticleKind = .bulge
            if rng.uniform() < morph.gasFrac { kind = .gas }
            // Central regions of bulges are redder (metallicity gradient).
            let bias = -0.22 + 0.20 * smoothstep(0, 3 * a, r)
            e.add(pos: SIMD3<Float>(x, y, z),
                  vel: SIMD3<Float>(vx, vy, vz),
                  color: stellarColor(kind, blueBias: bias, &rng),
                  size: pointSize(kind, &rng),
                  kind: kind)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Irregular generator
    // -------------------------------------------------------------------------

    private static func generateIrregular(spec: GalaxySpec, p: PotentialParams,
                                          morph: Morphology, count: Int, spin: Float,
                                          rng: inout RNG, into e: inout Emitter) {
        guard count > 0 else { return }
        let rd = max(0.05, p.diskA * morph.diskScaleFactor)
        let rMax = rd * morph.diskTrunc
        let hz = max(0.05, p.diskB * morph.thicknessFactor)
        let kin = DiskKinematics(p: p, rd: rd, rMax: rMax,
                                 sigmaFrac: morph.sigmaRFrac, vRotFrac: morph.vRotFrac, hz: hz)

        // Several off-centre star-forming knots.
        let knotCount = 4 + Int(rng.next() % 5)          // 4..8
        var knotX = [Float](repeating: 0, count: knotCount)
        var knotY = [Float](repeating: 0, count: knotCount)
        var knotR = [Float](repeating: 0, count: knotCount)
        var knotWeight = [Float](repeating: 0, count: knotCount)
        var wSum: Float = 0
        for i in 0..<knotCount {
            let rr = rMax * rng.uniform(0.12, 0.85)
            let pp = rng.uniform(0, twoPi)
            knotX[i] = rr * cosf(pp)
            knotY[i] = rr * sinf(pp)
            knotR[i] = rMax * rng.uniform(0.07, 0.17)
            knotWeight[i] = rng.uniform(0.4, 1.0)
            wSum += knotWeight[i]
        }
        for i in 0..<knotCount { knotWeight[i] /= wSum }

        // Lopsidedness: an m = 1 azimuthal bias makes the body asymmetric.
        let lopsidedPhase = rng.uniform(0, twoPi)
        let lopsidedAmp: Float = 0.45

        let knotFraction: Float = 0.40

        for _ in 0..<count {
            var x: Float, y: Float
            var inKnot = false

            if rng.uniform() < knotFraction {
                // Pick a knot by weight, then a Gaussian blob around it.
                var u = rng.uniform()
                var idx = knotCount - 1
                for i in 0..<knotCount {
                    if u < knotWeight[i] { idx = i; break }
                    u -= knotWeight[i]
                }
                x = knotX[idx] + rng.clampedGaussian() * knotR[idx]
                y = knotY[idx] + rng.clampedGaussian() * knotR[idx]
                inKnot = true
            } else {
                var r: Float = 0
                var phi: Float = 0
                var tries = 0
                repeat {
                    r = -rd * (logf(rng.positiveUniform()) + logf(rng.positiveUniform()))
                    phi = rng.uniform(0, twoPi)
                    tries += 1
                    // m = 1 lopsided weighting via rejection.
                    let w = 0.5 + 0.5 * cosf(phi - lopsidedPhase)
                    if rng.uniform() <= (1 - lopsidedAmp) + lopsidedAmp * w { break }
                } while tries < 12
                r = min(r, rMax)
                x = r * cosf(phi)
                y = r * sinf(phi)
            }

            let r = max(1e-4, sqrtf(x * x + y * y))
            let k = kin.sample(r)
            let z = k.height * atanhf(clamp(2 * rng.uniform() - 1, -0.999, 0.999))

            // Slow, chaotic rotation: dispersion-dominated with sigma ~ 0.4 v_c.
            let cp = x / r, sp = y / r
            let vR = rng.clampedGaussian() * k.sigR
            let vP = k.vphi + rng.clampedGaussian() * k.sigP
            let vZ = rng.clampedGaussian() * k.sigZ
            let vx = vR * cp - spin * vP * sp
            let vy = vR * sp + spin * vP * cp

            var kind: ParticleKind = .oldDisk
            let u = rng.uniform()
            let pYoung = inKnot ? 0.55 : morph.youngBase
            let pGas = morph.gasFrac * (inKnot ? 1.3 : 0.9)
            if u < pYoung { kind = .youngDisk }
            else if u < pYoung + pGas { kind = .gas }

            let bias: Float = (inKnot ? 0.45 : 0.20) + (kind == .youngDisk ? 0.25 : 0)
            e.add(pos: SIMD3<Float>(x, y, z),
                  vel: SIMD3<Float>(vx, vy, vZ),
                  color: stellarColor(kind, blueBias: bias, &rng),
                  size: pointSize(kind, &rng),
                  kind: kind)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Collisional ring generator
    // -------------------------------------------------------------------------

    private static func generateRing(spec: GalaxySpec, p: PotentialParams,
                                     morph: Morphology, count: Int, spin: Float,
                                     rng: inout RNG, into e: inout Emitter) {
        guard count > 0 else { return }
        let rd = max(0.05, p.diskA * morph.diskScaleFactor)
        let rMax = rd * morph.diskTrunc
        let hz = max(0.02, p.diskB * morph.thicknessFactor)
        let kin = DiskKinematics(p: p, rd: rd, rMax: rMax,
                                 sigmaFrac: morph.sigmaRFrac, vRotFrac: morph.vRotFrac, hz: hz)

        let rRing = 0.82 * rMax
        let ringWidth = 0.085 * rRing
        let ringFraction: Float = 0.76          // most of the mass sits in the annulus
        let expansion: Float = 0.22             // outward v_R as a fraction of v_c

        for _ in 0..<count {
            var r: Float
            var inRing = false
            if rng.uniform() < ringFraction {
                r = rRing + rng.clampedGaussian() * ringWidth
                r = clamp(r, 0.25 * rRing, rMax * 1.05)
                inRing = true
            } else {
                // Thin, sparse inner disk left behind by the intruder.
                var t = 0
                repeat {
                    r = -0.45 * rd * (logf(rng.positiveUniform()) + logf(rng.positiveUniform()))
                    t += 1
                } while r > 0.42 * rRing && t < 20
                r = min(r, 0.42 * rRing)
            }

            let phi = rng.uniform(0, twoPi)
            let k = kin.sample(max(r, 1e-4))
            // The shocked annulus is puffed up; the swept-out interior is razor thin.
            let z = k.height * (inRing ? 1.5 : 0.6)
                  * atanhf(clamp(2 * rng.uniform() - 1, -0.999, 0.999))
            let coldness: Float = inRing ? 0.8 : 1.0
            let vR = (inRing ? expansion * k.vc : 0) + rng.clampedGaussian() * k.sigR * coldness
            let vP = k.vphi + rng.clampedGaussian() * k.sigP * coldness
            let vZ = rng.clampedGaussian() * k.sigZ * coldness

            let cp = cosf(phi), sp = sinf(phi)
            let vx = vR * cp - spin * vP * sp
            let vy = vR * sp + spin * vP * cp

            // The ring is a propagating density wave: intense star formation.
            var kind: ParticleKind = .oldDisk
            let u = rng.uniform()
            let pYoung = inRing ? 0.50 : morph.youngBase
            let pGas = inRing ? morph.gasFrac * 1.2 : morph.gasFrac * 0.3
            if u < pYoung { kind = .youngDisk }
            else if u < pYoung + pGas { kind = .gas }

            let bias: Float = inRing ? 0.45 : -0.05
            e.add(pos: SIMD3<Float>(r * cp, r * sp, z),
                  vel: SIMD3<Float>(vx, vy, vZ),
                  color: stellarColor(kind, blueBias: bias, &rng),
                  size: pointSize(kind, &rng),
                  kind: kind)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Halo tracers
    // -------------------------------------------------------------------------

    /// A sparse, dim, near-isotropic population following the halo Hernquist
    /// profile — the stellar halo / globular-cluster analogue. These are what
    /// paint the tidal debris during an encounter.
    private static func generateHaloTracers(p: PotentialParams, count: Int,
                                            rng: inout RNG, into e: inout Emitter) {
        guard count > 0 else { return }
        let a = max(1e-3, p.haloScale)
        let jeans = SphericalJeans(tracerScale: a, p: p)
        let rCut = 2.0 * a
        let uMax = (rCut / (rCut + a)) * (rCut / (rCut + a))

        for _ in 0..<count {
            let r = max(1e-3, hernquistRadius(a: a, u: rng.uniform() * uMax))
            let cth = rng.uniform(-1, 1)
            let sth = sqrtf(max(0, 1 - cth * cth))
            let ph = rng.uniform(0, twoPi)
            let x = r * sth * cosf(ph)
            let y = r * sth * sinf(ph)
            let z = r * cth
            let sig = max(1e-5, jeans.sigma(at: r))
            let vx = rng.clampedGaussian() * sig
            let vy = rng.clampedGaussian() * sig
            let vz = rng.clampedGaussian() * sig
            e.add(pos: SIMD3<Float>(x, y, z),
                  vel: SIMD3<Float>(vx, vy, vz),
                  color: stellarColor(.halo, blueBias: 0.15, &rng),
                  size: pointSize(.halo, &rng),
                  kind: .halo)
        }
    }
}

import simd
import Foundation

// MARK: - Unit system
//
// Internal simulation units are chosen so that G == 1 exactly.
//
//   length : 1 kpc
//   time   : 1 Myr
//   mass   : 2.2229e11 Msun      (= 1 / G  in kpc^3 Msun^-1 Myr^-2)
//   speed  : 1 kpc/Myr = 977.79 km/s
//
// So the Milky Way (~9.5e11 Msun including halo) is about 4.3 mass units,
// and its 220 km/s rotation curve is about 0.225 speed units.
public enum Units {
    public static let msunPerMassUnit: Double = 2.2229e11
    public static let kmsPerSpeedUnit: Double = 977.79
    public static func kms(_ v: Float) -> Float { v * Float(kmsPerSpeedUnit) }
    public static func speed(fromKms v: Float) -> Float { v / Float(kmsPerSpeedUnit) }
}

// MARK: - Galaxy taxonomy

public enum GalaxyType: String, CaseIterable, Codable, Sendable {
    case sa       = "Sa"        // tight-wound spiral, big bulge
    case sb       = "Sb"        // classic spiral (Milky Way-like)
    case sc       = "Sc"        // loose open arms, small bulge
    case sbb      = "SBb"       // barred spiral
    case sbc      = "SBc"       // loose barred spiral
    case e0       = "E0"        // round elliptical
    case e5       = "E5"        // flattened elliptical
    case s0       = "S0"        // lenticular: disk, no arms
    case irr      = "Irr"       // irregular / clumpy
    case dwarf    = "Dwarf"     // dwarf spheroidal satellite
    case ring     = "Ring"      // collisional ring galaxy

    public var displayName: String {
        switch self {
        case .sa:    return "Sa · Tight Spiral"
        case .sb:    return "Sb · Classic Spiral"
        case .sc:    return "Sc · Open Spiral"
        case .sbb:   return "SBb · Barred"
        case .sbc:   return "SBc · Loose Barred"
        case .e0:    return "E0 · Round Elliptical"
        case .e5:    return "E5 · Flat Elliptical"
        case .s0:    return "S0 · Lenticular"
        case .irr:   return "Irr · Irregular"
        case .dwarf: return "dSph · Dwarf"
        case .ring:  return "Ring · Collisional"
        }
    }
}

/// Particle population, drives colour and star-formation response.
public enum ParticleKind: UInt32, Sendable {
    case oldDisk    = 0   // old yellow disk stars
    case youngDisk  = 1   // young blue stars in arms
    case bulge      = 2   // old red bulge/spheroid
    case gas        = 3   // gas — can be shocked into starburst
    case halo       = 4   // faint dark-ish halo tracer
}

/// One particle as produced by the initial-conditions generator.
public struct ParticleSeed {
    public var position: SIMD3<Float>   // kpc, galaxy-local then transformed to world
    public var velocity: SIMD3<Float>   // kpc/Myr
    public var color: SIMD3<Float>      // linear HDR rgb, roughly 0..1
    public var size: Float              // point sprite scale, ~0.5..2
    public var kind: ParticleKind
    public var galaxyIndex: UInt32

    public init(position: SIMD3<Float>, velocity: SIMD3<Float>,
                color: SIMD3<Float>, size: Float,
                kind: ParticleKind, galaxyIndex: UInt32 = 0) {
        self.position = position; self.velocity = velocity
        self.color = color; self.size = size
        self.kind = kind; self.galaxyIndex = galaxyIndex
    }
}

// MARK: - Analytic potential description
//
// Each galaxy carries a smooth three-component potential used by the
// RESTRICTED integrator:
//   halo  : Hernquist      Phi = -G M / (r + a)
//   disk  : Miyamoto-Nagai Phi = -G M / sqrt(R^2 + (a + sqrt(z^2+b^2))^2)
//   bulge : Hernquist
public struct PotentialParams: Sendable {
    public var haloMass:   Float
    public var haloScale:  Float
    public var diskMass:   Float
    public var diskA:      Float   // radial scale length
    public var diskB:      Float   // vertical scale height
    public var bulgeMass:  Float
    public var bulgeScale: Float

    public init(haloMass: Float, haloScale: Float,
                diskMass: Float, diskA: Float, diskB: Float,
                bulgeMass: Float, bulgeScale: Float) {
        self.haloMass = haloMass; self.haloScale = haloScale
        self.diskMass = diskMass; self.diskA = diskA; self.diskB = diskB
        self.bulgeMass = bulgeMass; self.bulgeScale = bulgeScale
    }

    public var totalMass: Float { haloMass + diskMass + bulgeMass }
}

/// A galaxy placed in the world, before particles are generated.
public struct GalaxySpec: Sendable {
    public var type: GalaxyType
    public var particleCount: Int
    public var massScale: Float          // multiplies the type's fiducial mass
    public var radiusScale: Float        // multiplies the type's fiducial radius
    public var position: SIMD3<Float>    // kpc
    public var velocity: SIMD3<Float>    // kpc/Myr
    /// Disk spin axis in world space (normalised). Controls inclination of the
    /// encounter, which is what decides whether you get tails or a ring.
    public var spinAxis: SIMD3<Float>
    /// true = disk rotates retrograde relative to the orbit
    public var retrograde: Bool
    public var seed: UInt64

    public init(type: GalaxyType,
                particleCount: Int,
                massScale: Float = 1,
                radiusScale: Float = 1,
                position: SIMD3<Float> = .zero,
                velocity: SIMD3<Float> = .zero,
                spinAxis: SIMD3<Float> = SIMD3(0, 1, 0),
                retrograde: Bool = false,
                seed: UInt64 = 0x9E3779B97F4A7C15) {
        self.type = type; self.particleCount = particleCount
        self.massScale = massScale; self.radiusScale = radiusScale
        self.position = position; self.velocity = velocity
        self.spinAxis = simd_normalize(spinAxis)
        self.retrograde = retrograde; self.seed = seed
    }
}

// MARK: - GPU-side layouts (must mirror Shaders/Common.metal exactly)

/// 48 bytes, 16-byte aligned.
public struct GPUParticle {
    public var position: SIMD4<Float>   // xyz = kpc, w = mass (0 for test particles)
    public var velocity: SIMD4<Float>   // xyz = kpc/Myr, w = temperature/starburst 0..1
    public var color:    SIMD4<Float>   // rgb linear, a = point size
    public init() {
        position = .zero; velocity = .zero; color = .zero
    }
}

/// Mirrors `GalaxyPotential` in Common.metal. 64 bytes.
public struct GPUGalaxy {
    public var position: SIMD4<Float>   // xyz kpc, w = total mass
    public var velocity: SIMD4<Float>   // xyz kpc/Myr, w = unused
    public var halo:     SIMD4<Float>   // mass, scale, _, _
    public var disk:     SIMD4<Float>   // mass, a, b, _
    public var bulge:    SIMD4<Float>   // mass, scale, _, _
    /// Rows of the world->galaxy-local rotation (disk plane = local xy).
    public var basisX:   SIMD4<Float>
    public var basisY:   SIMD4<Float>
    public var basisZ:   SIMD4<Float>
    public init() {
        position = .zero; velocity = .zero
        halo = .zero; disk = .zero; bulge = .zero
        basisX = SIMD4(1,0,0,0); basisY = SIMD4(0,1,0,0); basisZ = SIMD4(0,0,1,0)
    }
}

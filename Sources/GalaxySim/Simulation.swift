import Metal
import simd
import Foundation

// MARK: - Solver selection

public enum SolverMode: UInt32, CaseIterable {
    case restricted = 0    // analytic potentials, O(N)
    case barnesHut  = 2    // GPU octree, O(N log N) — the box approximation
    case direct     = 1    // exact N^2

    var displayName: String {
        switch self {
        case .restricted: return "Restricted (O(N))"
        case .barnesHut:  return "Barnes-Hut (self-gravity)"
        case .direct:     return "Direct N² (exact)"
        }
    }

    /// True when particle-particle gravity is computed, so the particles must
    /// carry only the baryonic mass and the dark halo stays analytic.
    var isSelfGravitating: Bool { self != .restricted }

    /// Supported selectable budget. Restricted 20M is an experimental capacity
    /// limit, not a promise of real-time merger evolution on an M1.
    var recommendedMax: Int {
        switch self {
        case .restricted: return 20_000_000
        case .barnesHut:  return 60_000
        case .direct:     return 32_768
        }
    }
}

/// Uniforms handed to every physics kernel. Mirrors `SimParams` in Common.metal.
struct SimParams {
    var dt: Float = 0.5
    var time: Float = 0
    var particleCount: UInt32 = 0
    var galaxyCount: UInt32 = 0
    var softening: Float = 0.25
    var mode: UInt32 = 0
    var starburstGain: Float = 150
    /// Per-Myr cooling. A triggered burst should stay lit for the ~50-100 Myr
    /// that an OB association actually shines, not the ~1 Myr that a decay
    /// near 1.0 would give — at dt=0.5 that subtracted far more per step than
    /// the trigger could add, pinning every particle at zero.
    var starburstDecay: Float = 0.010
    /// External acceleration a gas particle must feel from the *other* galaxy
    /// before it counts as shocked. Sets how localised the bursts look.
    var starburstThreshold: Float = 0.005
}

// MARK: - Galaxy core state (integrated on the CPU — there are only a few)

struct GalaxyCore {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var potential: PotentialParams
    var spinAxis: SIMD3<Float>

    var mass: Float { potential.totalMass }

    /// Three-component acceleration this galaxy exerts at a world point.
    func accel(at world: SIMD3<Float>) -> SIMD3<Float> {
        let d = world - position
        var a = Self.hernquist(d, potential.haloMass, potential.haloScale)
        a += Self.hernquist(d, potential.bulgeMass, potential.bulgeScale)

        let (bx, by, bz) = basis(forAxis: spinAxis)
        let local = SIMD3(simd_dot(bx, d), simd_dot(by, d), simd_dot(bz, d))
        let la = Self.miyamotoNagai(local, potential.diskMass, potential.diskA, potential.diskB)
        a += la.x * bx + la.y * by + la.z * bz
        return a
    }

    static func hernquist(_ d: SIMD3<Float>, _ m: Float, _ a: Float) -> SIMD3<Float> {
        let r = simd_length(d)
        let rs = r + a
        return -m * d / max(r * rs * rs, 1e-4)
    }

    static func miyamotoNagai(_ p: SIMD3<Float>, _ m: Float, _ a: Float, _ b: Float) -> SIMD3<Float> {
        let R2 = p.x * p.x + p.y * p.y
        let zeta = sqrt(p.z * p.z + b * b)
        let D = a + zeta
        let s = R2 + D * D
        let denom = max(s * sqrt(s), 1e-6)
        return SIMD3(-m * p.x / denom,
                     -m * p.y / denom,
                     -m * p.z * D / max(zeta * denom, 1e-6))
    }

    /// Hernquist halo density at radius r — needed for dynamical friction.
    func haloDensity(at r: Float) -> Float {
        let a = potential.haloScale
        let rr = max(r, 1e-3)
        return potential.haloMass * a / (2 * .pi * rr * pow(rr + a, 3))
    }

    /// Local 1-D velocity dispersion estimate from the halo circular speed.
    func dispersion(at r: Float) -> Float {
        let a = potential.haloScale
        let rr = max(r, 1e-3)
        let vc = sqrt(potential.haloMass) * rr / (rr + a)
        return max(vc / sqrt(2), 1e-4)
    }
}

// MARK: - A placed scene

public struct Scene {
    public var name: String
    public var specs: [GalaxySpec]
    public var cameraDistance: Float
    /// Where to stand to look at this scene, in the camera's own orbit
    /// coordinates. The defaults are the camera's own, so every scene that
    /// does not care is framed exactly as before.
    ///
    /// It matters for a scene whose geometry is not free. An invented
    /// encounter can be laid out in the xz plane where any viewpoint works,
    /// but the Local Group's positions come from a catalogue, and the default
    /// viewpoint happens to look almost straight down its long axis — 780 kpc
    /// of separation between the Milky Way and Andromeda collapsing into
    /// about fifty pixels. Turning a quarter of the way round the group
    /// spreads the same four galaxies across two thirds of the frame.
    public var cameraAzimuth: Float
    public var cameraElevation: Float
    /// What to call each galaxy, for the scenes built from real ones. A scene
    /// that leaves this empty gets invented names from `SkyNames`; a scene
    /// modelled on NGC 4038 should say so.
    public var galaxyNames: [String]
    public init(name: String, specs: [GalaxySpec], cameraDistance: Float = 160,
                cameraAzimuth: Float = 0.6, cameraElevation: Float = 0.45,
                galaxyNames: [String] = []) {
        self.name = name; self.specs = specs; self.cameraDistance = cameraDistance
        self.cameraAzimuth = cameraAzimuth; self.cameraElevation = cameraElevation
        self.galaxyNames = galaxyNames
    }
}

// MARK: - Simulation

final class Simulation {
    let ctx: MetalContext

    /// One name per loaded galaxy, in scene order. Filled by `load`.
    private(set) var galaxyNames: [String] = []

    /// What to call the galaxy a particle belongs to. The galaxy index rides
    /// in the top bits of the particle's aux word, so any star can say where
    /// it lives.
    func galaxyName(at index: Int) -> String {
        index >= 0 && index < galaxyNames.count ? galaxyNames[index] : ""
    }

    internal private(set) var particleBuffer: MTLBuffer!
    internal private(set) var auxBuffer: MTLBuffer!
    internal var galaxyBuffer: MTLBuffer!

    internal var barnesHut: BarnesHutSolver?
    /// Opening angle. 0.5-0.6 is the usual accuracy/speed compromise.
    var theta: Float = 0.6

    private var pDrift: MTLComputePipelineState!
    private var pRestricted: MTLComputePipelineState!
    private var pRestrictedStep: MTLComputePipelineState!
    /// Numerical diagnostics can retain the original three-pass reference.
    var useFusedRestricted = true
    private var pDirect: MTLComputePipelineState!

    internal private(set) var cores: [GalaxyCore] = []
    internal private(set) var particleCount: Int = 0
    private(set) var stepIndex: Int = 0

    var params = SimParams()
    var mode: SolverMode = .restricted {
        didSet {
            guard mode != oldValue else { return }
            if mode.isSelfGravitating { barnesHut?.resize(count: particleCount) }
            // disk/bulge move between the analytic potential and live particles
            // depending on the solver, so the scene has to be rebuilt.
            if mode.isSelfGravitating != oldValue.isSelfGravitating { restart() }
        }
    }
    var timeScale: Float = 1.0
    var isPaused = false

    /// 0 = compact, 1 = stars flung into wide tidal tails. Drives the noise bed.
    private(set) var dispersal: Float = 0
    private var smoothedRadius: Float = 0

    /// 0 = quiet, 1 = violent close passage. Drives the music.
    private(set) var intensity: Float = 0

    /// The galaxy-core state changes on the CPU every step, but the GPU may
    /// not have executed the previous step yet. Writing one shared slot would
    /// let every queued step read the newest cores instead of its own. A ring
    /// of slots gives each in-flight step its own immutable copy.
    private let galaxyRing = 64
    internal var galaxySlotStride = 0

    /// Changes on reset/reload; live insertion preserves existing identities.
    private(set) var sceneGeneration: UInt64 = 0
    private var scene: Scene?
    init(ctx: MetalContext) throws {
        self.ctx = ctx
        pDrift      = try ctx.computePipeline("drift")
        pRestricted = try ctx.computePipeline("accelKickRestricted")
        pRestrictedStep = try ctx.computePipeline("stepRestricted")
        pDirect     = try ctx.computePipeline("accelKickDirect")
        barnesHut   = try? BarnesHutSolver(ctx: ctx)
    }

    // MARK: Scene loading

    /// Allocate only the live GPU arrays. Initial conditions stream directly
    /// into them: no concatenated CPU seeds and no rewind copies.
    @discardableResult
    func load(_ scene: Scene) -> Bool {
        let count = scene.specs.reduce(0) { $0 + max(0, $1.particleCount) }
        let stride = MemoryLayout<GPUParticle>.stride
        guard count >= 0, count <= Int(UInt32.max),
              count <= ctx.device.maxBufferLength / stride,
              let particles = ctx.device.makeBuffer(length: max(1, count) * stride,
                                                     options: .storageModeShared),
              let auxiliary = ctx.device.makeBuffer(length: max(1, count) * 4,
                                                     options: .storageModeShared) else {
            NSLog("Galaxy allocation failed for %d stars; previous scene retained", count)
            return false
        }
        let slotStride = max(scene.specs.count, 1) * MemoryLayout<GPUGalaxy>.stride
        guard let galaxies = ctx.device.makeBuffer(length: slotStride * galaxyRing,
                                                     options: .storageModeShared) else { return false }
        self.scene = scene
        sceneGeneration &+= 1
        particleBuffer = particles
        auxBuffer = auxiliary
        galaxyBuffer = galaxies
        galaxySlotStride = slotStride
        particleCount = count
        stepIndex = 0
        params.time = 0
        params.particleCount = UInt32(count)
        smoothedRadius = 0
        dispersal = 0
        cores.removeAll()
        let p = particles.contents().bindMemory(to: GPUParticle.self, capacity: max(count, 1))
        let aux = auxiliary.contents().bindMemory(to: UInt32.self, capacity: max(count, 1))
        var offset = 0
        galaxyNames.removeAll()
        for (i, spec) in scene.specs.enumerated() {
            var s = spec
            s.seed = spec.seed &+ UInt64(i &* 0x9E37_79B9)
            galaxyNames.append(i < scene.galaxyNames.count
                ? scene.galaxyNames[i]
                : SkyNames.galaxy(seed: s.seed, index: i, type: spec.type))
            let pot = GalaxyModels.potential(for: s)
            cores.append(GalaxyCore(position: s.position, velocity: s.velocity,
                                    potential: pot, spinAxis: s.spinAxis))
            // Live particles carry baryons only; the dark halo stays analytic.
            let mass = (pot.diskMass + pot.bulgeMass) / Float(max(s.particleCount, 1))
            GalaxyModels.generate(s) { seed in
                p[offset].position = SIMD4(seed.position, mass)
                p[offset].velocity = SIMD4(seed.velocity, 0)
                p[offset].color = SIMD4(seed.color, seed.size)
                aux[offset] = seed.kind.rawValue | (UInt32(i) << 8)
                offset += 1
            }
        }
        assert(offset == count)
        params.galaxyCount = UInt32(cores.count)
        if mode.isSelfGravitating { barnesHut?.resize(count: particleCount) }
        params.softening = softeningForCurrentMode()
        return true
    }

    // MARK: Stepping

    /// Advance one physics step. `frameDt` is real seconds, converted to Myr.
    func step(commandBuffer cb: MTLCommandBuffer) {
        guard particleCount > 0, !isPaused else { return }
        advanceCores()
        updateIntensity()
        let galaxyOffset = uploadGalaxies()
        encodePhysics(cb, galaxyOffset: galaxyOffset)
        stepIndex += 1
        params.time += params.dt
    }

    private func encodePhysics(_ cb: MTLCommandBuffer, galaxyOffset: Int) {
        params.mode = mode.rawValue

        func run(_ pipe: MTLComputePipelineState, threadgroupMemory: Int = 0) {
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.setComputePipelineState(pipe)
            enc.setBuffer(particleBuffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 1)
            enc.setBuffer(galaxyBuffer, offset: galaxyOffset, index: 2)
            enc.setBuffer(auxBuffer, offset: 0, index: 3)
            if threadgroupMemory > 0 {
                enc.setThreadgroupMemoryLength(threadgroupMemory, index: 0)
            }
            let w = 256
            let groups = (particleCount + w - 1) / w
            enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
            enc.endEncoding()
        }

        if mode == .restricted && useFusedRestricted {
            run(pRestrictedStep)
            return
        }
        run(pDrift)
        switch mode {
        case .restricted:
            run(pRestricted)
        case .direct:
            run(pDirect, threadgroupMemory: 256 * 16)
            run(pRestricted)          // adds the rigid dark halo
        case .barnesHut:
            barnesHut?.encode(commandBuffer: cb,
                              particles: particleBuffer,
                              count: particleCount,
                              params: params,
                              theta: theta)
            run(pRestricted)          // adds the rigid dark halo
        }
        run(pDrift)
    }

    /// Galaxy centres: mutual analytic gravity plus Chandrasekhar dynamical
    /// friction, which is what actually sinks the orbit and makes them merge
    /// instead of flying apart forever.
    private func advanceCores() {
        guard cores.count > 1 else { return }
        let dt = params.dt
        var acc = [SIMD3<Float>](repeating: .zero, count: cores.count)

        // Mutual gravity, symmetrised.
        //
        // Each galaxy is a point when it *feels* the other's potential but an
        // extended, disk-flattened mass when it *generates* one. With two
        // differently tilted Miyamoto-Nagai disks that makes m_i*a_ij and
        // -m_j*a_ji disagree, so the pair quietly gains momentum and the whole
        // system walks out of frame. Averaging the two estimates into a single
        // pair force restores Newton's third law exactly, and reduces to the
        // plain answer when the two galaxies are identical.
        for i in cores.indices {
            for j in cores.indices where j > i {
                let aij = cores[j].accel(at: cores[i].position)   // on i, from j
                let aji = cores[i].accel(at: cores[j].position)   // on j, from i
                let f = 0.5 * (cores[i].mass * aij - cores[j].mass * aji)
                acc[i] += f / cores[i].mass
                acc[j] -= f / cores[j].mass
            }
        }
        // Dynamical friction, applied as an action/reaction pair. The drag on
        // one galaxy is momentum handed to the other's halo; without booking
        // that reaction the pair's centre of mass accelerates out of the frame.
        for i in cores.indices {
            for j in cores.indices where j != i {
                let adf = dynamicalFriction(on: i, from: j)
                acc[i] += adf
                acc[j] -= adf * (cores[i].mass / max(cores[j].mass, 1e-6))
            }
        }
        for i in cores.indices {
            cores[i].velocity += acc[i] * dt
            cores[i].position += cores[i].velocity * dt
        }
    }

    /// Chandrasekhar (1943):
    ///   a = -4πG²M ρ lnΛ [erf(X) - 2X/√π e^{-X²}] v / |v|³ ,  X = |v| / (√2 σ)
    private func dynamicalFriction(on i: Int, from j: Int) -> SIMD3<Float> {
        let d = cores[i].position - cores[j].position
        let r = simd_length(d)
        guard r > 1e-3 else { return .zero }
        // Chandrasekhar assumes a small body moving through a smooth, much
        // larger background. Once two comparable galaxies overlap that picture
        // fails outright: the Hernquist density diverges as 1/r and the drag
        // runs away. Evaluate the background at a softened radius and cap the
        // result against the mutual gravity below.
        let rSoft = max(r, 2.0)

        let v = cores[i].velocity - cores[j].velocity
        let vmag = simd_length(v)
        guard vmag > 1e-5 else { return .zero }

        let rho = cores[j].haloDensity(at: rSoft)
        let sigma = cores[j].dispersion(at: rSoft)
        let X = vmag / (sqrt(2) * sigma)
        let g = erf(Double(X)) - 2 * Double(X) / Double.pi.squareRoot() * exp(-Double(X * X))
        let lnLambda = log(1 + cores[i].mass / max(cores[j].mass, 1e-6))

        let coeff = -4 * Float.pi * cores[i].mass * rho * lnLambda * Float(max(g, 0))
        var a = coeff * v / (vmag * vmag * vmag)

        // Friction must never outrun gravity — it is a perturbation on the
        // orbit, not a driver of it. Cap at half the mutual gravitational
        // acceleration, which keeps the merger sinking realistically while
        // staying stable when the cores pass through each other.
        let gravMag = simd_length(cores[j].accel(at: cores[i].position))
        let cap = 0.5 * gravMag
        let mag = simd_length(a)
        if mag > cap && mag > 0 { a *= cap / mag }
        return a
    }

    @discardableResult
    private func uploadGalaxies() -> Int {
        guard let buf = galaxyBuffer, !cores.isEmpty else { return 0 }
        let offset = (stepIndex % galaxyRing) * galaxySlotStride
        let g = buf.contents().advanced(by: offset)
                   .bindMemory(to: GPUGalaxy.self, capacity: cores.count)
        for (i, c) in cores.enumerated() {
            var e = GPUGalaxy()
            e.position = SIMD4(c.position, c.mass)
            e.velocity = SIMD4(c.velocity, 0)
            e.halo  = SIMD4(c.potential.haloMass,  c.potential.haloScale, 0, 0)
            if mode.isSelfGravitating {
                // disk and bulge are live particles in these modes; only the
                // dark halo remains a smooth background
                e.disk  = .zero
                e.bulge = .zero
            } else {
                e.disk  = SIMD4(c.potential.diskMass,  c.potential.diskA, c.potential.diskB, 0)
                e.bulge = SIMD4(c.potential.bulgeMass, c.potential.bulgeScale, 0, 0)
            }
            let (bx, by, bz) = basis(forAxis: c.spinAxis)
            e.basisX = SIMD4(bx, 0); e.basisY = SIMD4(by, 0); e.basisZ = SIMD4(bz, 0)
            g[i] = e
        }
        return offset
    }

    /// Gravitational softening.
    ///
    /// A live disk needs far more softening than a test-particle one. These
    /// initial conditions are built for a *rigid* potential, with radial
    /// dispersion around 10% of the circular speed; under live self-gravity
    /// that sits below the Toomre threshold and the disk fragments into clumps
    /// within a few hundred Myr. Softening suppresses the small-scale
    /// collapse and the two-body scattering that drives it. Measured on a
    /// 60k live Sb disk over 300 Myr, r90 goes 10.6 -> 15.6 kpc at 0.25 kpc
    /// softening but holds at 9.9-11.0 kpc at 0.8 kpc.
    ///
    /// Scaled as N^(-1/3), tracking the mean interparticle separation.
    private func softeningForCurrentMode() -> Float {
        guard mode.isSelfGravitating, particleCount > 0 else { return 0.25 }
        let ref: Float = 60_000
        let scaled = 0.8 * pow(ref / Float(particleCount), 1.0 / 3.0)
        return min(max(scaled, 0.35), 2.0)
    }

    /// Rises as the galaxies close in and as the relative speed peaks.
    private func updateIntensity() {
        guard cores.count > 1 else { intensity = 0; return }
        var closest: Float = .greatestFiniteMagnitude
        var speed: Float = 0
        for i in cores.indices {
            for j in (i + 1)..<cores.count {
                let r = simd_length(cores[i].position - cores[j].position)
                if r < closest {
                    closest = r
                    speed = simd_length(cores[i].velocity - cores[j].velocity)
                }
            }
        }
        let proximity = 1 - simd_smoothstep(20, 220, closest)
        let violence = simd_smoothstep(0.05, 0.55, speed)
        let target = simd_clamp(proximity * 0.75 + violence * 0.35, 0, 1)
        intensity += (target - intensity) * 0.03
    }

    // MARK: Simulation time

    var currentTime: Float { params.time }
    /// Star-formation response, for checking the starburst trigger fires.
    func starburstReport() -> String {
        guard let buf = particleBuffer, particleCount > 0 else { return "no particles" }
        let p = buf.contents().bindMemory(to: GPUParticle.self, capacity: particleCount)
        let aux = auxBuffer.contents().bindMemory(to: UInt32.self, capacity: particleCount)
        var gas = 0, hot = 0
        var maxT: Float = 0, sumT: Float = 0
        var i = 0
        while i < particleCount {
            if aux[i] & 0xFF == ParticleKind.gas.rawValue {
                gas += 1
                let t = p[i].velocity.w
                sumT += t
                if t > maxT { maxT = t }
                if t > 0.15 { hot += 1 }
            }
            i += 1
        }
        guard gas > 0 else { return "no gas particles!" }
        return String(format: "gas=%d  starbursting=%d (%.1f%%)  meanT=%.3f  maxT=%.3f",
                      gas, hot, 100 * Float(hot) / Float(gas), sumT / Float(gas), maxT)
    }

    func restart() {
        if let s = scene { load(s) }
    }

    // MARK: Framing

    /// Centroid and a robust radius of the particle cloud, from a sparse
    /// sample. Uses a high percentile rather than the maximum so a handful
    /// of escaping stars can't pull the camera back to infinity.
    func sampleExtent(samples: Int = 3072) -> (center: SIMD3<Float>, radius: Float) {
        guard let buf = particleBuffer, particleCount > 0 else {
            return (.zero, 60)
        }
        let p = buf.contents().bindMemory(to: GPUParticle.self, capacity: particleCount)
        let stride = max(1, particleCount / samples)
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(samples + 1)

        var sum = SIMD3<Float>.zero
        var i = 0
        while i < particleCount {
            let v = p[i].position
            if v.x.isFinite && v.y.isFinite && v.z.isFinite {
                let q = SIMD3(v.x, v.y, v.z)
                pts.append(q)
                sum += q
            }
            i += stride
        }
        guard !pts.isEmpty else { return (.zero, 60) }

        // Centre on the mass-weighted galaxy cores. The particle mean gets
        // dragged sideways by the sparse extended halo tracers and by
        // whichever tail happens to be longer.
        var center = sum / Float(pts.count)
        if !cores.isEmpty {
            var wsum: Float = 0
            var acc = SIMD3<Float>.zero
            for c in cores { acc += c.position * c.mass; wsum += c.mass }
            if wsum > 0 { center = acc / wsum }
        }
        var d = pts.map { simd_length($0 - center) }
        d.sort()
        // 85th percentile, not 93rd: tidal tails are long and faint, and
        // framing them fully shrinks the bright interacting cores to nothing.
        // Let the tails run toward the edges instead.
        let idx = min(d.count - 1, Int(Float(d.count) * 0.85))

        // Dispersal, free of charge: we already have the sorted radii, so the
        // r90/r50 ratio costs nothing. A compact pair sits near 1.3; once the
        // encounter throws out tidal tails the outer radius runs away from the
        // median and the ratio climbs past 4.
        let r50 = d[min(d.count - 1, d.count / 2)]
        let r90 = d[min(d.count - 1, Int(Float(d.count) * 0.90))]
        let spread = r90 / max(r50, 1e-3)
        let target = simd_clamp((spread - 1.3) / 2.5, 0, 1)
        dispersal += (target - dispersal) * 0.15

        // Temporally smooth the measured radius before the camera ever sees
        // it. The percentile is computed from a fixed particle sample, but
        // those particles are moving — near pericentre the outer radius can
        // swing several percent between frames, and feeding that straight to
        // the camera reads as jitter.
        let raw = max(d[idx], 8)
        if smoothedRadius <= 0 {
            smoothedRadius = raw
        } else {
            smoothedRadius += (raw - smoothedRadius) * 0.05
        }
        return (center, smoothedRadius)
    }
}

// MARK: - Live insertion

extension Simulation {
    /// Drop a galaxy into the RUNNING simulation without disturbing anything
    /// already there.
    ///
    /// The scene is normally rebuilt from its list of specs, which is fine at
    /// load time but destroys the current state: placing a galaxy mid-run
    /// wiped every tidal tail, every evolved orbit, and every other galaxy.
    /// This grows the buffers and appends instead, so what is on screen stays
    /// on screen and the new galaxy simply joins it.
    @discardableResult
    func insertGalaxy(_ spec: GalaxySpec) -> Bool {
        guard spec.particleCount > 0, let oldP = particleBuffer, let oldA = auxBuffer else {
            return false
        }

        let stride = MemoryLayout<GPUParticle>.stride
        let newCount = particleCount + spec.particleCount
        guard newCount <= ctx.device.maxBufferLength / stride,
              newCount <= Int(UInt32.max) else { return false }
        let galaxyIndex = UInt32(cores.count)

        guard let np = ctx.device.makeBuffer(length: newCount * stride,
                                             options: .storageModeShared),
              let na = ctx.device.makeBuffer(length: newCount * 4,
                                             options: .storageModeShared)
        else { return false }

        // carry the live state across verbatim
        np.contents().copyMemory(from: oldP.contents(), byteCount: particleCount * stride)
        na.contents().copyMemory(from: oldA.contents(), byteCount: particleCount * 4)

        let pot = GalaxyModels.potential(for: spec)
        cores.append(GalaxyCore(position: spec.position,
                                velocity: spec.velocity,
                                potential: pot,
                                spinAxis: spec.spinAxis))

        // Same live-baryons / rigid-halo split the loader uses.
        let baryons = pot.diskMass + pot.bulgeMass
        let m = baryons / Float(spec.particleCount)

        let p = np.contents().bindMemory(to: GPUParticle.self, capacity: newCount)
        let a = na.contents().bindMemory(to: UInt32.self, capacity: newCount)
        var j = particleCount
        GalaxyModels.generate(spec) { s in
            p[j].position = SIMD4(s.position, mode.isSelfGravitating ? m : 0)
            p[j].velocity = SIMD4(s.velocity, 0)
            p[j].color    = SIMD4(s.color, s.size)
            a[j] = s.kind.rawValue | (galaxyIndex << 8)
            j += 1
        }
        assert(j == newCount)

        particleBuffer = np
        auxBuffer = na
        particleCount = newCount
        params.particleCount = UInt32(newCount)
        params.galaxyCount = UInt32(cores.count)

        // The galaxy ring is sized for the old core count, so it has to grow
        // with them or the kernels read past the end of a slot.
        galaxySlotStride = max(cores.count, 1) * MemoryLayout<GPUGalaxy>.stride
        galaxyBuffer = ctx.device.makeBuffer(length: galaxySlotStride * galaxyRing,
                                             options: .storageModeShared)

        if mode.isSelfGravitating { barnesHut?.resize(count: particleCount) }
        return true
    }
}

extension Simulation {
    /// Set one galaxy core's velocity in place, leaving its particles alone.
    func setCoreVelocity(_ index: Int, _ velocity: SIMD3<Float>) {
        guard cores.indices.contains(index) else { return }
        cores[index].velocity = velocity
    }
}

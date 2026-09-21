// ===================================================================
//  Integrator: drift-kick-drift leapfrog (2nd order symplectic).
//  Split into three dispatches so every solver mode shares one path:
//     drift(dt/2)  ->  accelKick*(dt)  ->  drift(dt/2)
//  Only the middle kernel differs between solvers.
//  Restricted gravity has no particle-particle dependency, so its production
//  path fuses all three operations. Keep split kernels as a numerical reference
//  and for direct/tree solvers, which require globally completed half-drifts.
// ===================================================================

// aux word per particle:  bits 0-7 = ParticleKind, bits 8-31 = galaxy index
inline uint auxKind(uint a)   { return a & 0xFFu; }
inline uint auxGalaxy(uint a) { return a >> 8; }

kernel void stepRestricted(device Particle *particles [[buffer(0)]],
                           constant SimParams &prm [[buffer(1)]],
                           constant GalaxyPotential *galaxies [[buffer(2)]],
                           device const uint *aux [[buffer(3)]],
                           uint gid [[thread_position_in_grid]])
{
    if (gid >= prm.particleCount) return;
    float4 position = particles[gid].position;
    float4 velocity = particles[gid].velocity;
    position.xyz += velocity.xyz * (prm.dt * 0.5f);
    uint a = aux[gid];
    float3 acc = float3(0.0f);
    float external = 0.0f;
    for (uint g = 0; g < prm.galaxyCount; ++g) {
        float3 ga = galaxyAccel(position.xyz, galaxies[g]);
        acc += ga;
        if (g != auxGalaxy(a)) external = max(external, length(ga));
    }
    velocity.xyz += acc * prm.dt;
    float temp = velocity.w;
    if (auxKind(a) == 3u)
        temp += max(external - prm.starburstThreshold, 0.0f)
              * prm.starburstGain * prm.dt;
    velocity.w = clamp(temp - prm.starburstDecay * prm.dt, 0.0f, 1.0f);
    position.xyz += velocity.xyz * (prm.dt * 0.5f);
    particles[gid].position = position;
    particles[gid].velocity = velocity;
}

kernel void drift(device Particle *particles [[buffer(0)]],
                  constant SimParams &prm    [[buffer(1)]],
                  uint gid [[thread_position_in_grid]])
{
    if (gid >= prm.particleCount) return;
    device Particle &p = particles[gid];
    p.position.xyz += p.velocity.xyz * (prm.dt * 0.5f);
}

// -------------------------------------------------------------------
//  RESTRICTED: stars are test particles in the summed analytic
//  potentials of every galaxy. O(N * Ngal), scales to millions.
// -------------------------------------------------------------------
kernel void accelKickRestricted(device Particle          *particles [[buffer(0)]],
                                constant SimParams       &prm       [[buffer(1)]],
                                constant GalaxyPotential *galaxies  [[buffer(2)]],
                                device const uint        *aux       [[buffer(3)]],
                                uint gid [[thread_position_in_grid]])
{
    if (gid >= prm.particleCount) return;
    device Particle &p = particles[gid];
    float3 pos = p.position.xyz;

    uint  a       = aux[gid];
    uint  ownGal  = auxGalaxy(a);
    uint  kind    = auxKind(a);

    float3 acc      = float3(0.0f);
    float  external = 0.0f;   // strongest pull from a galaxy that isn't ours

    for (uint g = 0; g < prm.galaxyCount; ++g) {
        float3 ga = galaxyAccel(pos, galaxies[g]);
        acc += ga;
        if (g != ownGal) external = max(external, length(ga));
    }

    p.velocity.xyz += acc * prm.dt;

    // ---- tidally triggered star formation -------------------------
    // Gas that suddenly feels a strong pull from the *other* galaxy is
    // being shocked. Ramp a temperature the renderer turns into a
    // blue-white starburst flash; let it cool afterwards.
    float temp = p.velocity.w;
    if (kind == 3u) {                       // ParticleKind.gas
        float drive = max(external - prm.starburstThreshold, 0.0f);
        temp += drive * prm.starburstGain * prm.dt;
    }
    temp -= prm.starburstDecay * prm.dt;
    p.velocity.w = clamp(temp, 0.0f, 1.0f);
}

// -------------------------------------------------------------------
//  DIRECT: exact O(N^2), tiled through threadgroup memory.
//  Reference solution — accurate, and the yardstick the approximate
//  solvers get measured against.
// -------------------------------------------------------------------

kernel void accelKickDirect(device Particle    *particles [[buffer(0)]],
                            constant SimParams &prm       [[buffer(1)]],
                            threadgroup float4 *shared    [[threadgroup(0)]],
                            uint gid  [[thread_position_in_grid]],
                            uint lid  [[thread_position_in_threadgroup]],
                            uint tgs  [[threads_per_threadgroup]])
{
    float3 pos  = float3(0.0f);
    bool   live = gid < prm.particleCount;
    if (live) pos = particles[gid].position.xyz;

    float eps2 = prm.softening * prm.softening;
    float3 acc = float3(0.0f);

    uint tiles = (prm.particleCount + tgs - 1) / tgs;
    for (uint t = 0; t < tiles; ++t) {
        uint src = t * tgs + lid;
        // xyz = position, w = mass
        shared[lid] = (src < prm.particleCount)
                        ? float4(particles[src].position.xyz, particles[src].position.w)
                        : float4(0.0f);
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (live) {
            for (uint j = 0; j < tgs; ++j) {
                float4 o = shared[j];
                acc += softenedAccel(o.xyz - pos, o.w, eps2);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (live) {
        device Particle &p = particles[gid];
        p.velocity.xyz += acc * prm.dt;
        p.velocity.w = clamp(p.velocity.w - prm.starburstDecay * prm.dt, 0.0f, 1.0f);
    }
}

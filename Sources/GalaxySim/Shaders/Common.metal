#include <metal_stdlib>
using namespace metal;

// ===================================================================
//  Shared layouts. These MUST mirror Types.swift byte-for-byte.
//  Simulation units: G == 1, length kpc, time Myr, mass 2.2229e11 Msun.
// ===================================================================

struct Particle {
    float4 position;   // xyz kpc,      w = mass (0 for massless test particles)
    float4 velocity;   // xyz kpc/Myr,  w = starburst temperature 0..1
    float4 color;      // rgb linear,   w = point size
};

struct GalaxyPotential {
    float4 position;   // xyz kpc, w = total mass
    float4 velocity;   // xyz kpc/Myr
    float4 halo;       // mass, scale
    float4 disk;       // mass, a, b
    float4 bulge;      // mass, scale
    float4 basisX;     // rows of the world -> galaxy-local rotation
    float4 basisY;
    float4 basisZ;
};

struct SimParams {
    float  dt;
    float  time;
    uint   particleCount;
    uint   galaxyCount;
    float  softening;      // Plummer softening, kpc
    uint   mode;           // 0 = restricted, 1 = direct N^2, 2 = barnes-hut
    float  starburstGain;
    float  starburstDecay;
    float  starburstThreshold;
};

// -------------------------------------------------------------------
//  Analytic accelerations
// -------------------------------------------------------------------

// Hernquist sphere:  Phi = -M / (r + a)   ->   g = -M * r_vec / (r (r+a)^2)
inline float3 hernquistAccel(float3 d, float mass, float scale) {
    float r = length(d);
    float rs = r + scale;
    // guard the centre; 1e-4 kpc is far below any resolved scale
    float denom = max(r * rs * rs, 1e-4f);
    return -mass * d / denom;
}

// Miyamoto-Nagai disk, evaluated in the galaxy-local frame where the disk
// lies in the xy plane:
//   Phi = -M / sqrt(R^2 + (a + sqrt(z^2 + b^2))^2)
inline float3 miyamotoNagaiAccel(float3 p, float mass, float a, float b) {
    float R2   = p.x * p.x + p.y * p.y;
    float zeta = sqrt(p.z * p.z + b * b);
    float D    = a + zeta;
    float s    = R2 + D * D;
    float denom = max(s * sqrt(s), 1e-6f);          // s^(3/2)
    float3 acc;
    acc.xy = -mass * p.xy / denom;
    acc.z  = -mass * p.z * D / max(zeta * denom, 1e-6f);
    return acc;
}

// Full three-component acceleration from one galaxy, in world space.
inline float3 galaxyAccel(float3 worldPos, constant GalaxyPotential &g) {
    float3 d = worldPos - g.position.xyz;

    float3 acc = hernquistAccel(d, g.halo.x,  g.halo.y);
    acc       += hernquistAccel(d, g.bulge.x, g.bulge.y);

    // rotate into the disk frame, apply MN, rotate back
    float3 local = float3(dot(g.basisX.xyz, d),
                          dot(g.basisY.xyz, d),
                          dot(g.basisZ.xyz, d));
    float3 la = miyamotoNagaiAccel(local, g.disk.x, g.disk.y, g.disk.z);
    acc += la.x * g.basisX.xyz + la.y * g.basisY.xyz + la.z * g.basisZ.xyz;

    return acc;
}

// Plummer-softened point mass, used by the direct and tree solvers.
inline float3 softenedAccel(float3 d, float mass, float eps2) {
    float r2 = dot(d, d) + eps2;
    float inv = rsqrt(r2);
    return d * (mass * inv * inv * inv);
}

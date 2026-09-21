#include <metal_stdlib>
using namespace metal;

struct ShipVertexData { float4 position; float4 normal; float4 color; float4 detail; };
struct ShipUniformData { float4x4 viewProjection; float4 eye; float4 flight; };
struct ShipRaster {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float4 color;
    float4 detail;
};
vertex ShipRaster shipVertex(uint id [[vertex_id]],
    const device ShipVertexData* mesh [[buffer(0)]], constant ShipUniformData& u [[buffer(1)]]) {
    ShipVertexData v = mesh[id];
    ShipRaster out;
    out.position = u.viewProjection * v.position;
    out.world = v.position.xyz;
    out.normal = v.normal.xyz;
    out.color = v.color;
    out.detail = v.detail;
    return out;
}

// Sparse, subdued environment reflections; no uniformly lit studio hemisphere.
float3 shipEnvironment(float3 r) {
    float blue = pow(max(dot(r,normalize(float3(-0.8,0.22,-0.6))),0.0),36.0);
    float red = pow(max(dot(r,normalize(float3(0.9,0.12,0.4))),0.0),48.0);
    return float3(0.015,0.055,0.12)*blue + float3(0.07,0.007,0.003)*red;
}
float3 hullLamp(float3 p, float3 n, float3 v, float3 base, float roughness,
                float3 source, float3 radiance, float radius) {
    float3 offset = source-p;
    float d2 = max(dot(offset,offset),0.1);
    float3 l = offset*rsqrt(d2);
    float falloff = (1.0-smoothstep(radius*0.6,radius,sqrt(d2))) / (1.0+d2/32.0);
    float ndl = max(dot(n,l),0.0);
    float3 h = normalize(l+v);
    float spec = pow(max(dot(n,h),0.0),mix(160.0,25.0,roughness));
    return radiance*falloff*ndl*(base*0.5 + spec*1.6);
}
fragment float4 shipFragment(ShipRaster in [[stage_in]], constant ShipUniformData& u [[buffer(1)]]) {
    float material = in.detail.x;
    float3 base = max(in.color.rgb, float3(0.002));
    float ao = clamp(in.color.a, 0.12, 1.0);
    if (material > 0.5 && material < 1.5) {
        // Stable lit districts; no high-frequency blinking or flashing.
        return float4(base * 2.3, 1);
    }
    if (material > 1.5 && material < 2.5) {
        float drive = smoothstep(0.0, 0.995, clamp(u.flight.x, 0.0, 0.99999));
        return float4(base * (1.4 + 4.5 * drive), 1);
    }
    float3 n = normalize(in.normal);
    float3 v = normalize(u.eye.xyz - in.world);
    float roughness = clamp(in.detail.y,0.22,0.85);
    float ndv = max(dot(n,v),0.0);
    float3 f0 = mix(float3(0.04),base,0.85);
    float3 fresnel = f0+(1.0-f0)*pow(1.0-ndv,5.0);
    float3 reflection = shipEnvironment(reflect(-v,n));
    // World-space micro plating, filtered to disappear below a pixel.
    float3 an = abs(n);
    float2 plate = an.y > max(an.x, an.z) ? in.world.xz : (an.x > an.z ? in.world.zy : in.world.xy);
    plate /= float2(3.8, 6.2);
    float2 cell = floor(plate);
    float random = fract(sin(dot(cell,float2(12.9898,78.233))) * 43758.5453);
    float2 edgeDistance = min(fract(plate),1.0-fract(plate));
    float2 footprint = max(fwidth(plate),float2(0.001));
    float2 seam = 1.0-smoothstep(float2(0.008),float2(0.008)+footprint,edgeDistance);
    float resolved = 1.0-smoothstep(0.18,0.65,max(footprint.x,footprint.y));
    base *= mix(1.0,0.82+random*0.28,resolved);
    base *= 1.0-0.35*max(seam.x,seam.y)*resolved;
    ao = pow(ao,1.35);
    float3 color = base*float3(0.0003,0.0005,0.0009);
    color += fresnel*reflection*0.45;
    color += hullLamp(in.world,n,v,base,roughness,float3(-45,16,-46),float3(0.08,0.45,1.5),55);
    color += hullLamp(in.world,n,v,base,roughness,float3(44,15,18),float3(1.2,0.045,0.018),48);
    color += hullLamp(in.world,n,v,base,roughness,float3(-18,15,95),float3(0.04,0.35,1.2),42);
    color += hullLamp(in.world,n,v,base,roughness,float3(18,15,95),float3(0.04,0.35,1.2),42);
    float drive = 0.6+1.8*smoothstep(0.0,0.995,u.flight.x);
    color += hullLamp(in.world,n,v,base,roughness,float3(-31,-3,142),float3(0.035,0.6,1.6)*drive,48);
    color += hullLamp(in.world,n,v,base,roughness,float3(31,-3,142),float3(0.035,0.6,1.6)*drive,48);
    color *= ao;
    if (material > 2.5) color *= 0.35;
    return float4(color,1);
}

// ===================================================================
//  Engine exhaust
//
//  Generated entirely from vertex_id — no mesh, no buffer, no CPU work.
//  Two nozzles emit a column of camera-facing billboards that stretch and
//  brighten with speed. Additive, depth-tested against the hull but not
//  writing depth, so the plume glows over the sky without cutting into it.
//
//  Drawn into the galaxy's HDR buffer before the PSF and film passes, so the
//  bloom around it is the same bloom the stars get.
// ===================================================================

struct ExhaustRaster {
    float4 position [[position]];
    float2 uv;
    float3 tint;
    float  intensity;
};

constant float2 kQuad[6] = {
    float2(-1,-1), float2(1,-1), float2(-1,1),
    float2(-1, 1), float2(1,-1), float2( 1,1)
};

/// Nozzle anchors, matching the engine lamp positions in the hull shader.
constant float3 kNozzle[2] = { float3(-31,-3,142), float3(31,-3,142) };

// Many small overlapping puffs, not a few big ones: at low counts the column
// separates into visible beads instead of reading as one continuous plume.
constant int kPuffs = 34;

inline float exhaustHash(float n) { return fract(sin(n) * 43758.5453123); }

vertex ExhaustRaster shipExhaustVertex(uint vid [[vertex_id]],
                                       constant ShipUniformData& u [[buffer(1)]])
{
    int corner = int(vid % 6);
    int quad   = int(vid / 6);
    int puff   = quad % kPuffs;
    int engine = quad / kPuffs;

    float beta = clamp(u.flight.x, 0.0f, 0.99999f);
    float time = u.flight.y;

    ExhaustRaster out;
    out.uv = kQuad[corner];

    // Drive: nothing at rest, so a parked ship has dark nozzles.
    float drive = smoothstep(0.02f, 0.65f, beta);
    if (drive <= 0.0f) {
        out.position = float4(0, 0, -2, 1);   // behind the near plane: clipped
        out.tint = float3(0);
        out.intensity = 0;
        return out;
    }

    // Puffs stream aft, recycling so the column never runs dry.
    float seed = float(puff) * 7.13f + float(engine) * 31.7f;
    float speed = 26.0f + 70.0f * drive;
    float travel = fract(float(puff) / float(kPuffs) + time * speed * 0.006f);
    float dist = travel * (14.0f + 62.0f * drive);

    float3 anchor = kNozzle[engine];
    // slight outward splay, and a lazy wobble so it is not a straight tube
    float wob = sin(time * 2.3f + seed) * 0.9f * travel;
    float3 centre = anchor + float3(wob, wob * 0.6f, dist);

    // Billboard toward the camera.
    float3 toEye = u.eye.xyz - centre;
    float3 f = normalize(toEye);
    float3 right = normalize(cross(float3(0, 1, 0), f));
    float3 up = cross(f, right);

    // Widens and softens downstream, like a real underexpanded plume.
    float width = mix(2.2f, 6.5f, travel) * (0.5f + 0.5f * drive);
    float length_ = width * mix(1.2f, 2.0f, drive);

    float3 world = centre
                 + right * (out.uv.x * width)
                 + up * (out.uv.y * length_);

    out.position = u.viewProjection * float4(world, 1);

    // Hot blue-white at the throat, cooling to deep blue as it disperses.
    float3 hot  = float3(0.75f, 0.95f, 1.00f);
    float3 cool = float3(0.05f, 0.30f, 0.95f);
    out.tint = mix(hot, cool, travel);

    // Fade in off the nozzle, out at the end of the run.
    float fade = smoothstep(0.0f, 0.06f, travel) * (1.0f - smoothstep(0.30f, 0.95f, travel));
    float flicker = 0.88f + 0.12f * exhaustHash(seed + floor(time * 18.0f));
    // Divided by the puff count so adding overlap does not add brightness.
    out.intensity = drive * fade * flicker * 5.0f / float(kPuffs);
    return out;
}

fragment float4 shipExhaustFragment(ExhaustRaster in [[stage_in]])
{
    // Soft elliptical falloff; a hard edge would read as a sprite.
    float r2 = dot(in.uv, in.uv);
    if (r2 > 1.0f) discard_fragment();
    float a = exp(-r2 * 3.2f) * (1.0f - r2);
    return float4(in.tint * in.intensity * a, a);
}

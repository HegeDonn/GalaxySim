// ===================================================================
//  Rendering: HDR point sprites -> bloom chain -> ACES tonemap.
//  Particles are additively blended with no depth test, which makes
//  the pass order-independent (and is physically right for emission).
// ===================================================================

struct CameraUniforms {
    float4x4 viewProj;
    float4   cameraPos;     // xyz world, w = unused
    float4   viewport;      // width, height, 1/width, 1/height
    float4   tuning;        // pointScale, exposure, fogDensity, brightness
    float4   extra;         // wrapCell (0 = no wrapping), _, _, _
};

struct PointOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float4 color;
    float  intensity;
};

/// Wrap a point into the cube of side `cell` centred on the camera.
///
/// Turns a finite buffer of stars into an endless field: whatever direction
/// you fly, stars keep arriving. Because the source points are uniform in the
/// cube, the seams are invisible — there is no structure to repeat.
inline float3 wrapCell(float3 p, float3 camera, float cell) {
    float3 d = p - camera;
    d -= cell * floor(d / cell + 0.5f);
    return camera + d;
}

inline PointOut shadeParticle(Particle p, constant CameraUniforms &cam, constant RelativityUniforms &rel)
{
    PointOut out;

    // Only the background field wraps; simulation particles must not.
    //
    // Wrapping teleports a star from one face of the cube to the opposite
    // face, so without help it blinks out and reappears instantly — a hard
    // shell of popping stars at half the cell size, which is what reads as a
    // "wall". Fading over the outer part of the cell hides the seam: a star
    // has already gone dark before it is moved, and comes back up gradually
    // on the far side.
    float wrapFade = 1.0f;
    if (cam.extra.x > 0.0f) {
        p.position.xyz = wrapCell(p.position.xyz, cam.cameraPos.xyz, cam.extra.x);
        float radius = cam.extra.x * 0.5f;          // furthest a wrapped star can be
        float d = length(p.position.xyz - cam.cameraPos.xyz);
        // out by the boundary, in well before it
        wrapFade = (cam.extra.y > 0.5f) ? 1.0f
                 : 1.0f - smoothstep(radius * 0.28f, radius * 0.86f, d);
        // and ease the nearest ones too, so one does not swell into the lens
        if (cam.extra.y <= 0.5f) wrapFade *= smoothstep(0.0f, radius * 0.10f, d);
        if (wrapFade <= 0.001f) {
            out.position = float4(0, 0, -2, 1);     // clipped, costs nothing
            out.pointSize = 1;
            out.color = float4(0);
            out.intensity = 0;
            return out;
        }
    }

    // Relativistic optics. Aberration moves where the star APPEARS, so the
    // sprite is re-placed along its aberrated direction at the same distance;
    // Doppler re-colours it and beaming rescales it. With the transform
    // disabled this is an exact pass-through.
    float3 restDir = p.position.xyz - cam.cameraPos.xyz;
    RelStar star = relTransformStar(restDir, p.color.rgb, rel);
    float3 worldPos = cam.cameraPos.xyz + star.direction * length(restDir);

    float4 clip = cam.viewProj * float4(worldPos, 1.0f);
    out.position = clip;

    float dist = max(length(worldPos - cam.cameraPos.xyz), 0.05f);

    // Perspective-correct sprite size, clamped so near stars don't become
    // screen-filling blobs and far ones never vanish below a pixel.
    // Aberration compresses angular size by 1/D (differentiating the sine
    // form gives dtheta' = dtheta / D), so a sprite's apparent width must
    // shrink as its neighbours crowd toward the forward pole. Without this
    // the sprites keep their rest-frame pixel size while their positions
    // converge, so a galaxy stays fat while the sky around it compresses --
    // and its surface brightness comes out far below the D^4 that the
    // background correctly gets.
    float px = p.color.w * cam.tuning.x / (dist * max(star.doppler, 1e-3f));
    out.pointSize = clamp(px, 1.0f, 48.0f);

    // Starburst: hot gas goes blue-white and brightens hard.
    float temp = clamp(p.velocity.w, 0.0f, 1.0f);
    float3 hot = float3(0.75f, 0.88f, 1.0f);
    float3 rgb = mix(star.colour, hot, temp * 0.85f);
    float boost = (1.0f + temp * 6.0f) * star.brightness;

    // Distance falloff: keeps the far galaxy from washing out the near one.
    float fog = exp(-dist * cam.tuning.z);

    out.color     = float4(rgb, 1.0f);
    out.intensity = boost * fog * cam.tuning.w * wrapFade;

    // Sprites below a pixel would alias; fade them instead of shrinking.
    // A point sprite smaller than a pixel cannot be drawn smaller, only
    // dimmer — and switching that on abruptly at exactly one pixel makes
    // distant stars scintillate as they drift across the grid. Ramp it.
    float subPixel = smoothstep(0.35f, 1.6f, px);
    out.intensity *= mix(0.04f, 1.0f, subPixel);

    return out;
}

// Stable sampling is an approximation of the real particle field, not a
// fabricated galaxy. The fade has analytically unit expected flux, while
// changing continuously as camera distance changes. Close stars stay exact.
struct StarSelection { uint index; float weight; };
struct StarLODParams { uint count; float fraction; float nearRadius; float farRadius; };

inline uint starHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    return x ^ (x >> 16);
}

kernel void selectVisibleStars(device const Particle *particles [[buffer(0)]],
                               constant CameraUniforms &cam [[buffer(1)]],
                               constant RelativityUniforms &rel [[buffer(2)]],
                               constant StarLODParams &lod [[buffer(3)]],
                               device StarSelection *selected [[buffer(4)]],
                               device atomic_uint *drawArgs [[buffer(5)]],
                               uint id [[thread_position_in_grid]],
                               uint lane [[thread_index_in_simdgroup]]) {
    bool keep = false;
    float weight = 1.0f;
    if (id < lod.count) {
        float3 delta = particles[id].position.xyz - cam.cameraPos.xyz;
        float distance = length(delta);
        float near = 1.0f - smoothstep(lod.nearRadius, lod.farRadius, distance);
        float p = mix(lod.fraction, 1.0f, near);
        float u = float(starHash(id) >> 8) * (1.0f / 16777216.0f);
        // Rejection before expensive relativistic optics / colour work.
        if (u < p) {
            float width = min(p, 1.0f - p) * 0.2f;
            weight = (width > 1e-7f ? smoothstep(0.0f, width, p - u) : 1.0f)
                   / max(p - width * 0.5f, 1e-8f);
            float3 dir = distance > 1e-12f ? delta / distance : REL_FALLBACK_DIR;
            if (rel.params.x >= 0.5f)
                dir = relAberrateScaled(delta, rel.boost.xyz, rel.boost.w, rel.params.w);
            float4 clip = cam.viewProj * float4(cam.cameraPos.xyz + dir * distance, 1);
            // Maximum sprite diameter is 48 px: retain centres just outside
            // the viewport, including stars bent into view by aberration.
            float2 margin = 48.0f * cam.viewport.zw * clip.w;
            keep = clip.w > 0 && clip.z >= 0 && clip.z <= clip.w
                && all(abs(clip.xy) <= clip.w + margin);
        }
    }
    uint n = simd_sum(uint(keep));
    uint offset = simd_prefix_exclusive_sum(uint(keep));
    uint base = 0;
    if (lane == 0 && n > 0)
        base = atomic_fetch_add_explicit(drawArgs, n, memory_order_relaxed);
    base = simd_broadcast_first(base);
    if (keep) selected[base + offset] = {id, weight};
}

vertex PointOut particleVertex(device const Particle *particles [[buffer(0)]],
                               constant CameraUniforms &cam [[buffer(1)]],
                               constant RelativityUniforms &rel [[buffer(2)]],
                               uint vid [[vertex_id]]) {
    return shadeParticle(particles[vid], cam, rel);
}

vertex PointOut selectedParticleVertex(device const Particle *particles [[buffer(0)]],
                                       constant CameraUniforms &cam [[buffer(1)]],
                                       constant RelativityUniforms &rel [[buffer(2)]],
                                       device const StarSelection *selected [[buffer(3)]],
                                       uint vid [[vertex_id]]) {
    StarSelection s = selected[vid];
    PointOut out = shadeParticle(particles[s.index], cam, rel);
    out.intensity *= s.weight;
    return out;
}

fragment float4 particleFragment(PointOut in [[stage_in]],
                                 float2 uv [[point_coord]])
{
    // Gaussian core plus a faint wide halo — a hard disc reads as a
    // sprite, this reads as a star.
    float2 d = uv - 0.5f;
    float r2 = dot(d, d) * 4.0f;               // 0 at centre, 1 at edge
    if (r2 > 1.0f) discard_fragment();

    float core = exp(-r2 * 9.0f);
    float halo = exp(-r2 * 1.8f) * 0.11f;
    float a = core + halo;

    return float4(in.color.rgb * in.intensity * a, a);
}

// -------------------------------------------------------------------
//  Fullscreen passes
// -------------------------------------------------------------------

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreenVertex(uint vid [[vertex_id]])
{
    // single oversized triangle
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    o.uv = float2(p.x, 1.0f - p.y);
    return o;
}

// Box downsample. The target is half the source size, so four bilinear taps
// at quarter-texel offsets average a 4x4 neighbourhood.
fragment float4 downsamplePass(FSOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               constant float2 &texel [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c  = src.sample(s, in.uv + texel * float2(-1, -1)).rgb;
    c        += src.sample(s, in.uv + texel * float2( 1, -1)).rgb;
    c        += src.sample(s, in.uv + texel * float2(-1,  1)).rgb;
    c        += src.sample(s, in.uv + texel * float2( 1,  1)).rgb;
    return float4(c * 0.25f, 1.0f);
}

fragment float4 brightPass(FSOut in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           constant float &threshold [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = src.sample(s, in.uv).rgb;
    float  l = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    // soft knee so the bloom fades in instead of popping
    float  k = smoothstep(threshold, threshold * 2.0f, l);
    return float4(c * k, 1.0f);
}

// Separable 9-tap gaussian. `dir` is (1/w, 0) or (0, 1/h).
fragment float4 blurPass(FSOut in [[stage_in]],
                         texture2d<float> src [[texture(0)]],
                         constant float2 &dir [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    const float w[5] = { 0.2270270270f, 0.1945945946f, 0.1216216216f,
                         0.0540540541f, 0.0162162162f };
    float3 sum = src.sample(s, in.uv).rgb * w[0];
    for (int i = 1; i < 5; ++i) {
        float2 off = dir * float(i) * 1.4f;
        sum += src.sample(s, in.uv + off).rgb * w[i];
        sum += src.sample(s, in.uv - off).rgb * w[i];
    }
    return float4(sum, 1.0f);
}

// Narkowicz ACES filmic curve — keeps bright cores from clipping to
// flat white and gives the highlights a natural roll-off.
inline float3 acesFilm(float3 x) {
    const float a = 2.51f, b = 0.03f, c = 2.43f, d = 0.59f, e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0f, 1.0f);
}

struct SensorParams {
    float4 a;   // exposure, filmK (half-saturation), filmN (contrast), psfStrength
    float4 b;   // psf weights for mip 0..3
    float4 c;   // vignette, saturation, halationAmount, _
};

// ---------------------------------------------------------------
//  Film / sensor response
// ---------------------------------------------------------------
//
// A real emulsion (or photosite) responds to accumulated exposure and
// saturates as its silver-halide crystals are used up — a Naka-Rushton /
// Michaelis-Menten curve. The essential point is that this happens PER
// CHANNEL, independently.
//
// That is what makes an over-exposed star look right. Its core drives all
// three channels past saturation and renders white; the surrounding halo
// — spread there by the lens PSF *before* exposure — is orders of magnitude
// dimmer, stays on the responsive part of the curve, and therefore keeps the
// star's true colour. Applying a curve to luminance instead (and carrying
// chroma through unchanged) mathematically forbids that: it forces the core
// to keep a hue it should have lost, and denies the wings the colour they
// should have gained.
//
//   R(E) = E^n / (E^n + K^n)
//
// n < 1 compresses the several decades of surface brightness between a
// galactic nucleus and a tidal tail; K sets the exposure that renders as
// mid-grey, i.e. the film speed.
inline float3 filmResponse(float3 E, float K, float n) {
    float3 e = pow(max(E, 0.0f), n);
    float  k = pow(max(K, 1e-6f), n);
    return e / (e + k);
}

fragment float4 compositePass(FSOut in [[stage_in]],
                              texture2d<float> scene [[texture(0)]],
                              texture2d<float> psf0  [[texture(1)]],
                              texture2d<float> psf1  [[texture(2)]],
                              texture2d<float> psf2  [[texture(3)]],
                              texture2d<float> psf3  [[texture(4)]],
                              constant SensorParams &prm [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    // --- Optical point spread, applied in LINEAR light before exposure.
    // Four octaves of blur with falling weights approximate the broad
    // power-law wings of a real PSF far better than one gaussian does.
    float3 core = scene.sample(s, in.uv).rgb;
    float3 w0 = psf0.sample(s, in.uv).rgb;
    float3 w1 = psf1.sample(s, in.uv).rgb;
    float3 w2 = psf2.sample(s, in.uv).rgb;
    float3 w3 = psf3.sample(s, in.uv).rgb;

    float4 w = prm.b;
    float3 wings = w0 * w.x + w1 * w.y + w2 * w.z + w3 * w.w;

    // Halation: light that penetrates the emulsion, scatters off the film
    // base and re-exposes from behind. The return path is filtered by the
    // upper layers, so it comes back warm — the familiar red bloom around
    // bright highlights on film.
    float halation = prm.c.z;
    if (halation > 0.0f) {
        float3 warm = float3(1.0f, 0.42f, 0.22f);
        // Hug the highlight: halation is a tight ring around a bright point,
        // not a wide atmospheric haze, so it rides the narrow octaves.
        wings += (w0 * 0.5f + w1) * warm * halation;
    }

    float psfStrength = prm.a.w;
    float3 E = core + wings * psfStrength;

    // normalise so changing PSF strength re-spreads light without also
    // changing the overall exposure
    float wsum = (w.x + w.y + w.z + w.w) * psfStrength;
    E /= (1.0f + wsum * 0.5f);

    E *= prm.a.x;                       // exposure

    // --- Per-channel film response
    float3 c = filmResponse(E, prm.a.y, prm.a.z);

    // Optional chroma trim. Kept mild: the response curve is doing the real
    // colour work now, so this is a finishing control rather than a rescue.
    float lum = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    c = mix(float3(lum), c, prm.c.y);

    c = clamp(c, 0.0f, 1.0f);
    c = pow(c, float3(1.0f / 2.2f));    // linear -> sRGB

    float2 q = in.uv - 0.5f;
    float vig = 1.0f - dot(q, q) * prm.c.x;
    c *= clamp(vig, 0.0f, 1.0f);

    return float4(c, 1.0f);
}

// ===================================================================
//  Ground guide for placement mode.
//
//  Clicking maps the cursor onto the y = 0 orbital plane, but with nothing
//  drawn there it is an invisible surface -- you cannot tell where in depth
//  a galaxy will land, and the scene reads as flat. This draws that plane
//  faintly while painting, which is the whole spatial cue.
// ===================================================================

struct GridParams {
    float4x4 invViewProj;
    float4   camPos;    // xyz camera position, w = opacity
    float4   cursor;    // xyz cursor world point, w = 1 if valid
    float4   tuning;    // spacingKpc, fadeKpc, ringRadius, _
};

fragment float4 groundGrid(FSOut in [[stage_in]],
                           constant GridParams &prm [[buffer(0)]])
{
    float2 ndc = float2(in.uv.x, 1.0f - in.uv.y) * 2.0f - 1.0f;
    float4 p0 = prm.invViewProj * float4(ndc, 0.0f, 1.0f);
    float4 p1 = prm.invViewProj * float4(ndc, 1.0f, 1.0f);
    float3 o = p0.xyz / p0.w;
    float3 d = normalize(p1.xyz / p1.w - o);

    // Behind the camera or parallel to the plane: nothing to draw.
    if (abs(d.y) < 1e-4f) discard_fragment();
    float t = -o.y / d.y;
    if (t <= 0.0f) discard_fragment();

    float3 hit = o + d * t;
    float spacing = prm.tuning.x;
    float dist = length(hit - prm.camPos.xyz);

    // Analytic line coverage: distance to the nearest gridline in cells,
    // widened by the screen-space derivative so far lines stay ~1px and do
    // not alias into moire.
    float2 g = hit.xz / spacing;
    float2 w = fwidth(g) * 1.2f;
    float2 f = abs(fract(g) - 0.5f) / max(w, 1e-5f);
    float line = 1.0f - clamp(min(f.x, f.y), 0.0f, 1.0f);

    // every 5th line brighter, for readable scale
    float2 g5 = hit.xz / (spacing * 5.0f);
    float2 w5 = fwidth(g5) * 1.2f;
    float2 f5 = abs(fract(g5) - 0.5f) / max(w5, 1e-5f);
    float major = 1.0f - clamp(min(f5.x, f5.y), 0.0f, 1.0f);

    float fade = exp(-dist / max(prm.tuning.y, 1.0f));
    float a = (line * 0.35f + major * 0.65f) * fade;

    float3 col = float3(0.30f, 0.52f, 0.78f);

    // Cursor ring, so the drop point is unambiguous.
    if (prm.cursor.w > 0.5f) {
        float r = length(hit.xz - prm.cursor.xz);
        float rw = max(fwidth(r), 1e-4f) * 1.5f;
        float ring = 1.0f - clamp(abs(r - prm.tuning.z) / rw, 0.0f, 1.0f);
        float disc = 1.0f - smoothstep(0.0f, prm.tuning.z, r);
        a += ring * 3.2f + disc * 0.25f;
        col = mix(col, float3(0.95f, 0.80f, 0.45f),
                  clamp(ring + disc * 0.5f, 0.0f, 1.0f));
    }

    a *= prm.camPos.w;
    if (a < 0.002f) discard_fragment();
    return float4(col * a, a);
}

// ===================================================================
//  Star streaks
//
//  Aberration already moves every star to where it truly appears, but a point
//  that has moved is still just a point — nothing about it says "fast". What
//  reads as speed is the STREAK, and we have a principled reason to draw one:
//  this renderer models a camera with a finite exposure (see the film response
//  in compositePass), and a real shutter records a fast-moving point as a line.
//
//  The length is not invented. For a camera moving at velocity v, a star in
//  direction n at distance r drifts at angular rate
//
//      omega = |v| sin(theta) / r
//
//  so over an exposure dt it sweeps an arc of r*omega*dt = |v| sin(theta) dt
//  in world units — the same physical length for every star, which is why
//  nearer stars draw longer streaks on screen. Stars at the apex of travel
//  (theta = 0) do not move at all, which is what carves the still eye at the
//  centre of the tunnel.
// ===================================================================

struct StreakOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float  intensity;
};

constant float2 kStreakQuad[6] = {
    float2(-1,-1), float2(1,-1), float2(-1,1),
    float2(-1, 1), float2(1,-1), float2( 1,1)
};

vertex StreakOut starStreakVertex(device const Particle *particles [[buffer(0)]],
                                  constant CameraUniforms &cam     [[buffer(1)]],
                                  constant RelativityUniforms &rel [[buffer(2)]],
                                  uint vid [[vertex_id]])
{
    uint index = vid / 6u;
    int corner = int(vid % 6u);
    Particle p = particles[index];

    StreakOut out;
    out.uv = kStreakQuad[corner];

    // Same endless-field wrap and fade as the point path.
    float wrapFade = 1.0f;
    if (cam.extra.x > 0.0f) {
        p.position.xyz = wrapCell(p.position.xyz, cam.cameraPos.xyz, cam.extra.x);
        float radius = cam.extra.x * 0.5f;
        float d0 = length(p.position.xyz - cam.cameraPos.xyz);
        wrapFade = 1.0f - smoothstep(radius * 0.28f, radius * 0.86f, d0);
        wrapFade *= smoothstep(0.0f, radius * 0.10f, d0);
    }
    if (wrapFade <= 0.001f) {
        out.position = float4(0, 0, -2, 1);
        out.color = float4(0); out.intensity = 0;
        return out;
    }

    float3 restDir = p.position.xyz - cam.cameraPos.xyz;
    float dist = max(length(restDir), 0.05f);

    RelStar star = relTransformStar(restDir, p.color.rgb, rel);
    float3 world = cam.cameraPos.xyz + star.direction * dist;

    // ---- streak geometry
    float beta = rel.params.x > 0.5f ? rel.boost.w : 0.0f;
    float3 bdir = rel.boost.xyz;
    float3 n = star.direction;

    // Component of travel perpendicular to the line of sight: the direction
    // the star actually drifts, and zero at the apex.
    float3 vPerp = bdir - n * dot(bdir, n);
    float sinTheta = length(vPerp);

    // cam.extra.z carries the exposure in kpc per unit beta.
    float streakLen = beta * sinTheta * cam.extra.z;

    // The world-space length is the same for every star, so a NEAR star
    // subtends a huge angle and draws a line clear across the frame. That is
    // formally what a long exposure would record, but it reads as a scratch
    // rather than a star, so cap the angle it may cover. Energy conservation
    // below already dims whatever is left.
    const float maxAngle = 0.18f;            // radians, about 10 degrees
    streakLen = min(streakLen, dist * maxAngle);

    float3 axis = sinTheta > 1e-5f ? -vPerp / sinTheta : float3(0);

    // Sprite half-width in world units at this distance, matching the point
    // path's pixel size so a stationary star looks identical either way.
    float pxWidth = p.color.w * cam.tuning.x / (dist * max(star.doppler, 1e-3f));
    // tuning.x includes the 0.05 star-size factor: using it to unproject
    // pixels made the background quads about 20x too large.
    float projectionScale = length(float3(cam.viewProj[0][1],cam.viewProj[1][1],cam.viewProj[2][1]));
    float pixelsPerUnit = cam.viewport.y * 0.5f * projectionScale;
    float halfW = 0.5f * clamp(pxWidth,0.8f,5.0f) * dist / max(pixelsPerUnit,1e-4f);

    float3 toEye = cam.cameraPos.xyz - world;
    float3 f = normalize(toEye);
    float3 side = normalize(cross(f, axis.x == 0 && axis.y == 0 && axis.z == 0
                                     ? float3(0, 1, 0) : axis));

    // A stationary star still needs two-dimensional area.
    float3 along = length(axis)>0.5f ? axis : normalize(cross(side,f));
    float3 alongWorld = along * (streakLen * 0.5f + halfW);
    float3 offset = alongWorld * out.uv.y + side * (halfW * out.uv.x);
    out.position = cam.viewProj * float4(world + offset, 1.0f);

    // Starburst tint as in the point path.
    float temp = clamp(p.velocity.w, 0.0f, 1.0f);
    float3 hot = float3(0.75f, 0.88f, 1.0f);
    float3 rgb = mix(star.colour, hot, temp * 0.85f);

    float fog = exp(-dist * cam.tuning.z);
    float boost = (1.0f + temp * 6.0f) * star.brightness;

    // Conserve light: smearing a fixed amount of energy over a longer line
    // must not make the star brighter, or the sky would blaze at speed.
    float spread = 1.0f + streakLen / max(halfW * 2.0f, 1e-3f);
    float sub = smoothstep(0.35f, 1.6f, pxWidth);

    out.color = float4(rgb, 1.0f);
    out.intensity = boost * fog * cam.tuning.w * wrapFade
                  * mix(0.04f, 1.0f, sub) / spread;
    return out;
}

fragment float4 starStreakFragment(StreakOut in [[stage_in]])
{
    // Round across the streak, tapered along it, so the ends fade out instead
    // of stopping dead.
    float across = in.uv.x * in.uv.x;
    float along = in.uv.y * in.uv.y;
    float a = exp(-across * 7.0f) * exp(-along * 2.2f) * (1.0f - smoothstep(0.75f, 1.0f, along));
    if (a < 0.003f) discard_fragment();
    return float4(in.color.rgb * in.intensity * a, a);
}

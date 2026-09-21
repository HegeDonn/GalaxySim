// ===================================================================
//  Cosmic web background.
//
//  Not an imitation of large-scale structure -- an evolution of it. See the
//  Zel'dovich block below. Emits LINEAR HDR radiance into the scene buffer
//  before the PSF and film curve, so the exposure control reaches it: at
//  normal exposure it is a faint mottling that just stops the sky being flat
//  black, and winding exposure up reveals the web.
// ===================================================================

struct WebParams {
    float4 a;   // scale, growth D, softening, marchSteps
    float4 b;   // depth, strength, seed, _
    float4 c;   // hStep, _, _, _
};

struct SkyParams {
    float4x4 invViewProj;
    float4   params;      // strength, _, _, _
};

inline float3 hash33(float3 p) {
    p = float3(dot(p, float3(127.1, 311.7, 74.7)),
               dot(p, float3(269.5, 183.3, 246.1)),
               dot(p, float3(113.5, 271.9, 124.6)));
    return fract(sin(p) * 43758.5453123);
}
inline float hash13(float3 p) {
    return fract(sin(dot(p, float3(12.9898, 78.233, 37.719))) * 43758.5453123);
}
inline float vnoise(float3 p) {
    float3 i = floor(p), f = p - i;
    // Quintic, not cubic. The Zel'dovich density needs the HESSIAN of this
    // field, and cubic smoothstep f*f*(3-2f) is only C1 -- its second
    // derivative jumps at every lattice boundary, so the Hessian comes out as
    // noise and the whole structure collapses to speckle. Quintic is C2.
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = mix(mix(mix(hash13(i+float3(0,0,0)), hash13(i+float3(1,0,0)), f.x),
                      mix(hash13(i+float3(0,1,0)), hash13(i+float3(1,1,0)), f.x), f.y),
                  mix(mix(hash13(i+float3(0,0,1)), hash13(i+float3(1,0,1)), f.x),
                      mix(hash13(i+float3(0,1,1)), hash13(i+float3(1,1,1)), f.x), f.y), f.z);
    return a;
}
/// Worley returning the four nearest feature distances.
///
/// In 3D the codimensions of the Voronoi diagram map straight onto cosmic-web
/// morphology, which is why this primitive fits the problem so well:
///
///   F2 - F1 -> 0   a SURFACE   -- the wall between two cells (a sheet)
///   F3 - F1 -> 0   a LINE      -- where three cells meet (a FILAMENT)
///   F4 - F1 -> 0   a POINT     -- where four cells meet (a CLUSTER)
///
/// Using F2-F1 as "the filament" (the obvious choice, and the one I started
/// with) actually draws the sheets, which is why they came out as broad
/// membranes rather than strands.
inline float4 worley4(float3 p) {
    float3 i = floor(p), f = p - i;
    float f1 = 1e9, f2 = 1e9, f3 = 1e9, f4 = 1e9;
    for (int z = -1; z <= 1; ++z)
    for (int y = -1; y <= 1; ++y)
    for (int x = -1; x <= 1; ++x) {
        float3 g = float3(x, y, z);
        float3 o = hash33(i + g);
        float3 r = g + o - f;
        float d = dot(r, r);
        if (d < f1)      { f4 = f3; f3 = f2; f2 = f1; f1 = d; }
        else if (d < f2) { f4 = f3; f3 = f2; f2 = d; }
        else if (d < f3) { f4 = f3; f3 = d; }
        else if (d < f4) { f4 = d; }
    }
    return float4(sqrt(f1), sqrt(f2), sqrt(f3), sqrt(f4));
}


// ===================================================================
//  Zel'dovich approximation
//
//  Instead of imitating the cosmic web with cell noise, evolve it the way it
//  actually forms. Zel'dovich (1970) maps each parcel of matter from its
//  initial position q to
//
//      x = q + D * psi(q),      psi = -grad(phi)
//
//  with phi the initial gravitational potential and D the growth factor.
//  Conservation of mass then gives the density in CLOSED FORM:
//
//      rho / rho_bar = 1 / |(1 - D*l1)(1 - D*l2)(1 - D*l3)|
//
//  where l1..l3 are eigenvalues of the deformation tensor -- the Hessian of
//  phi. This is the whole morphology for free:
//
//      one eigenvalue collapsing   (1 - D*l -> 0)   ->  a SHEET
//      two collapsing                                ->  a FILAMENT
//      three collapsing                              ->  a CLUSTER
//
//  No particles, no FFT, and the density genuinely diverges at caustics,
//  which is where the enormous dynamic range of the reference comes from.
// ===================================================================

/// Initial gravitational potential. Weighted toward large scales, as a
/// LCDM potential is -- phi has far more power on large scales than the
/// density does, since phi(k) ~ delta(k)/k^2.
inline float zelPotential(float3 p) {
    // Deliberately smooth: only a few octaves, falling fast. A Hessian is
    // dominated by the smallest scale present, so leaving fine octaves in
    // gives a tidal tensor of high-frequency hash with no coherent sheets.
    // Smoothing the initial field before applying Zel'dovich is standard
    // practice ("truncated Zel'dovich") precisely because it sharpens the
    // resulting morphology.
    //
    // Each octave is evaluated in a ROTATED frame. Value noise lives on a
    // cubic lattice and is measurably anisotropic along the axes; second
    // derivatives amplify that until the whole field looks like brickwork.
    // Rotating each octave decorrelates the lattices and the axis alignment
    // washes out.
    const float3x3 R1 = float3x3(float3( 0.804f, 0.527f, 0.276f),
                                 float3(-0.540f, 0.841f, -0.033f),
                                 float3(-0.250f, -0.126f, 0.960f));
    const float3x3 R2 = float3x3(float3( 0.611f, -0.527f, 0.591f),
                                 float3( 0.729f, 0.665f, -0.161f),
                                 float3(-0.308f, 0.529f, 0.791f));
    const float3x3 R3 = float3x3(float3( 0.355f, 0.802f, -0.481f),
                                 float3(-0.916f, 0.229f, -0.328f),
                                 float3(-0.186f, 0.552f, 0.813f));

    float s = 0.0f, amp = 1.0f, norm = 0.0f;
    float3 q = p;
    for (int i = 0; i < 3; ++i) {
        float3 r = (i == 0) ? q : ((i == 1) ? R1 * q : R2 * q);
        s += amp * (vnoise(r) - 0.5f);
        // a second, differently rotated sample at the same frequency
        s += amp * (vnoise(R3 * q * 1.13f + 19.0f) - 0.5f);
        norm += 2.0f * amp;
        q *= 2.03f;
        amp *= 0.45f;
    }
    return s / max(norm, 1e-5f);
}

/// Eigenvalues of a symmetric 3x3 matrix, closed form (Smith 1961).
inline float3 symEigen(float a11, float a22, float a33,
                       float a12, float a13, float a23) {
    float p1 = a12*a12 + a13*a13 + a23*a23;
    float q  = (a11 + a22 + a33) / 3.0f;
    if (p1 < 1e-18f) {
        float3 e = float3(a11, a22, a33);
        return float3(max(max(e.x,e.y),e.z),
                      e.x + e.y + e.z - max(max(e.x,e.y),e.z) - min(min(e.x,e.y),e.z),
                      min(min(e.x,e.y),e.z));
    }
    float p2 = (a11-q)*(a11-q) + (a22-q)*(a22-q) + (a33-q)*(a33-q) + 2.0f*p1;
    float pp = sqrt(max(p2/6.0f, 1e-20f));
    float inv = 1.0f/pp;
    float b11 = inv*(a11-q), b22 = inv*(a22-q), b33 = inv*(a33-q);
    float b12 = inv*a12,     b13 = inv*a13,     b23 = inv*a23;
    float detB = b11*(b22*b33 - b23*b23)
               - b12*(b12*b33 - b23*b13)
               + b13*(b12*b23 - b22*b13);
    float r = clamp(detB * 0.5f, -1.0f, 1.0f);
    float phi = acos(r) / 3.0f;
    float e1 = q + 2.0f*pp*cos(phi);
    float e3 = q + 2.0f*pp*cos(phi + 2.0943951f);
    float e2 = 3.0f*q - e1 - e3;
    return float3(e1, e2, e3);        // e1 >= e2 >= e3
}

/// Zel'dovich density contrast at p, for growth factor D.
inline float zelDensity(float3 p, float D, float h, float softening) {
    // Hessian of the potential by central differences.
    float c   = zelPotential(p);
    float xp  = zelPotential(p + float3(h,0,0)), xm = zelPotential(p - float3(h,0,0));
    float yp  = zelPotential(p + float3(0,h,0)), ym = zelPotential(p - float3(0,h,0));
    float zp  = zelPotential(p + float3(0,0,h)), zm = zelPotential(p - float3(0,0,h));
    float inv2 = 1.0f/(h*h);

    float a11 = (xp - 2.0f*c + xm) * inv2;
    float a22 = (yp - 2.0f*c + ym) * inv2;
    float a33 = (zp - 2.0f*c + zm) * inv2;

    float pxy = zelPotential(p + float3(h,h,0)) - zelPotential(p + float3(h,-h,0))
              - zelPotential(p + float3(-h,h,0)) + zelPotential(p + float3(-h,-h,0));
    float pxz = zelPotential(p + float3(h,0,h)) - zelPotential(p + float3(h,0,-h))
              - zelPotential(p + float3(-h,0,h)) + zelPotential(p + float3(-h,0,-h));
    float pyz = zelPotential(p + float3(0,h,h)) - zelPotential(p + float3(0,h,-h))
              - zelPotential(p + float3(0,-h,h)) + zelPotential(p + float3(0,-h,-h));
    float inv4 = 1.0f/(4.0f*h*h);
    float a12 = pxy * inv4, a13 = pxz * inv4, a23 = pyz * inv4;

    float3 lam = symEigen(a11, a22, a33, a12, a13, a23);

    // Jacobian of the Zel'dovich map. Softened, because at a caustic it is
    // exactly zero and the true density is infinite.
    float j1 = 1.0f - D*lam.x;
    float j2 = 1.0f - D*lam.y;
    float j3 = 1.0f - D*lam.z;
    float jac = abs(j1*j2*j3);
    return 1.0f / (jac + softening);
}

constant int kRampN = 15;
constant float kRampT[15] = {
    0.000f, 0.020f, 0.050f, 0.100f, 0.200f, 0.350f, 0.500f, 0.650f,
    0.800f, 0.900f, 0.950f, 0.980f, 0.995f, 0.9995f, 1.000f
};
constant float3 kRampC[15] = {
    float3(0.063f, 0.014f, 0.117f),   // p0    near-black purple
    float3(0.120f, 0.035f, 0.205f),
    float3(0.152f, 0.049f, 0.245f),
    float3(0.185f, 0.062f, 0.280f),
    float3(0.231f, 0.082f, 0.320f),
    float3(0.290f, 0.108f, 0.359f),
    float3(0.349f, 0.135f, 0.392f),   // p50   violet
    float3(0.420f, 0.170f, 0.426f),
    float3(0.518f, 0.231f, 0.471f),
    float3(0.623f, 0.321f, 0.529f),   // p90   magenta
    float3(0.714f, 0.421f, 0.598f),
    float3(0.829f, 0.552f, 0.695f),
    float3(0.967f, 0.744f, 0.846f),   // p99.5 pink
    float3(0.996f, 0.933f, 0.890f),
    float3(1.000f, 0.988f, 0.855f)    // p100  gold core
};

inline float3 cosmicRamp(float t) {
    t = clamp(t, 0.0f, 1.0f);
    if (t <= kRampT[0]) return kRampC[0];
    for (int i = 1; i < kRampN; ++i) {
        if (t <= kRampT[i]) {
            float f = (t - kRampT[i-1]) / max(kRampT[i] - kRampT[i-1], 1e-6f);
            return mix(kRampC[i-1], kRampC[i], f);
        }
    }
    return kRampC[kRampN-1];
}

constant int kRankN = 20;
constant float kRankD[20] = {0.588235f, 0.784314f, 0.980392f, 0.980402f, 1.372549f, 1.764706f, 2.352941f, 2.941176f, 3.529412f, 4.313725f, 5.098039f, 5.882353f, 7.058824f, 8.431373f, 10.000000f, 11.372549f, 13.529412f, 15.098039f, 17.647059f, 26.470588f};
constant float kRankT[20] = {0.000000f, 0.005000f, 0.010000f, 0.020000f, 0.050000f, 0.100000f, 0.200000f, 0.300000f, 0.400000f, 0.500000f, 0.600000f, 0.700000f, 0.800000f, 0.880000f, 0.940000f, 0.970000f, 0.990000f, 0.996000f, 0.999000f, 1.000000f};

/// Map density to its own percentile rank.
///
/// The colour ramp is indexed by percentile, so feeding it the rank makes the
/// output's luminance histogram match the reference by construction instead of
/// by hand-tuning. The curve is CALIBRATED: the density field is rendered,
/// its CDF measured, and the control points written back in. That avoids
/// assuming a distribution shape -- the field stopped being Gaussian the
/// moment clusters started multiplying their neighbourhoods.
inline float densityRank(float d) {
    if (d <= kRankD[0]) return 0.0f;
    for (int i = 1; i < kRankN; ++i) {
        if (d <= kRankD[i]) {
            float f = (d - kRankD[i-1]) / max(kRankD[i] - kRankD[i-1], 1e-6f);
            return mix(kRankT[i-1], kRankT[i], f);
        }
    }
    return 1.0f;
}


/// Linear HDR radiance of the cosmic web along a world direction.
inline float3 cosmicWebRadiance(float3 dir, constant WebParams &prm)
{
    float scale  = prm.a.x;
    float growth = prm.a.y;
    float soft   = prm.a.z;
    int   steps  = max(int(prm.a.w), 1);
    float depth  = prm.b.x;
    float seed   = prm.b.z;
    float hstep  = prm.c.x;

    // Integrate through a slab of the field: the sky shows a projection of
    // structure at many distances, not an infinitely thin cut.
    float density = 0.0f;
    for (int i = 0; i < steps; ++i) {
        float t = (float(i) + 0.5f) / float(steps);
        float3 p = dir * (scale * (0.35f + t * depth)) + seed;
        density += zelDensity(p, growth, hstep, soft);
    }
    density /= float(steps);

    float3 srgb = cosmicRamp(densityRank(density));
    // The ramp was measured off an sRGB image; the renderer wants linear.
    return pow(max(srgb, 0.0f), 2.2f);
}

fragment float4 cosmicWebBake(FSOut in [[stage_in]],
                              constant WebParams &prm [[buffer(0)]])
{
    float lon = (in.uv.x - 0.5f) * 2.0f * M_PI_F;
    float lat = (0.5f - in.uv.y) * M_PI_F;
    float cl = cos(lat);
    float3 dir = float3(cl * sin(lon), sin(lat), -cl * cos(lon));
    return float4(cosmicWebRadiance(dir, prm), 1.0f);
}

inline float2 webEquirectUV(float3 d)
{
    float lon = atan2(d.x, -d.z);
    float lat = asin(clamp(d.y, -1.0f, 1.0f));
    return float2(lon / (2.0f * M_PI_F) + 0.5f, 0.5f - lat / M_PI_F);
}

inline float3 webRestDirection(float3 apparent, float3 axis, float beta, float strength) {
    return relAberrateScaled(apparent, -axis, beta, strength);
}
// GPU regression checks use the same inverse lookup as the live sky.
kernel void skyInverseCheck(device float4 *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float beta = float(id / 3) * 0.249f;
    float theta = 0.35f + float(id % 3)*1.2f;
    float3 axis=float3(0,0,-1), rest=float3(sin(theta),0,-cos(theta));
    float3 apparent=relAberrate(rest,axis,beta);
    float3 recovered=webRestDirection(apparent,axis,beta,1);
    float D=relDoppler(recovered,axis,beta);
    float expected=relGamma(beta)*(1+beta*cos(theta));
    out[id]=float4(length(recovered-rest),abs(D-expected),
        relDoppler(webRestDirection(axis,axis,beta,1),axis,beta),
        relDoppler(webRestDirection(-axis,axis,beta,1),axis,beta));
}

fragment float4 cosmicWebSky(FSOut in [[stage_in]],
                             texture2d<float> sky [[texture(0)]],
                             constant SkyParams &prm [[buffer(0)]],
                             constant RelativityUniforms &rel [[buffer(1)]])
{
    constexpr sampler s(filter::linear, address::repeat);

    float2 ndc = float2(in.uv.x, 1.0f - in.uv.y) * 2.0f - 1.0f;
    float4 p0 = prm.invViewProj * float4(ndc, 0.0f, 1.0f);
    float4 p1 = prm.invViewProj * float4(ndc, 1.0f, 1.0f);
    float3 dir = normalize(p1.xyz / p1.w - p0.xyz / p0.w);

    float3 rgb;
    if (rel.params.x > 0.5f) {
        // `dir` is where the light APPEARS to come from; aberration maps rest
        // -> apparent, so recovering the rest direction is the same positive-speed map with the boost AXIS reversed.
        // Negative beta is clamped to zero by relClampBeta and silently disables it.
        float3 bdir = rel.boost.xyz;
        float  beta = rel.boost.w;
        float3 restDir = webRestDirection(dir, bdir, beta, rel.params.w);
        float  D = relDoppler(restDir, bdir, beta);
        rgb = sky.sample(s, webEquirectUV(restDir)).rgb;
        rgb = relShiftColourScaled(rgb, D, rel.params.y);
        // extended continuum -> D^4 surface brightness, unlike the star
        // sprites whose per-source flux goes as D^2
        // D^4 is the correct surface-brightness law for an extended continuum,
        // and at beta = 0.9 that is 361x -- enough to turn the faint web into a
        // milky sheet that buries the galaxies. Compress the top of the range
        // with a soft knee: exact below 4x, rolling over above it. This is an
        // ARTISTIC clamp on a physically correct effect, the one place in the
        // relativistic path where that is true.
        // D^4 is the correct surface-brightness law for an extended continuum.
        // Taken literally it is 9x at beta=0.5 and 361x at beta=0.9, which turns
        // a background deliberately tuned to be barely-there into the loudest
        // thing on screen the moment you start moving. Compress hard: exact
        // below 1.6x, then a knee that flattens toward a ceiling.
        float beam = relBeamingScaled(D, rel.params.z, 4.0f);
        const float knee = 1.6f;
        const float ceiling = 5.0f;
        if (beam > knee) {
            float over = beam - knee;
            beam = knee + (ceiling - knee) * (over / (over + 2.2f));
        }
        rgb *= beam;


    } else {
        rgb = sky.sample(s, webEquirectUV(dir)).rgb;
    }
    return float4(rgb * prm.params.x, 1.0f);
}

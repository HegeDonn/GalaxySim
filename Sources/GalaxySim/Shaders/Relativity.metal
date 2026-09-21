// ===================================================================
//  Relativity.metal — special-relativistic optics for the cockpit view.
//
//  Concatenated after Common/Physics/BarnesHut and BEFORE Render.metal,
//  so <metal_stdlib> and `using namespace metal;` are already in scope
//  and everything here is visible to particleVertex.
//
//  Free functions + one uniform struct only. No entry points.
//
// -------------------------------------------------------------------
//  FRAME AND SIGN CONVENTIONS  (read this before touching anything)
// -------------------------------------------------------------------
//
//  S   = the "rest frame": the frame the galaxy/simulation is expressed
//        in. The stars are at rest in it.
//  S'  = the observer frame: the cockpit, moving through S with velocity
//        v = beta * c * bhat.
//
//  n   = restDir : UNIT VECTOR FROM THE OBSERVER TO THE STAR, measured in
//        S. It is the line of sight, i.e. the OPPOSITE of the photon's
//        propagation direction. Every formula below assumes this; using
//        the photon direction instead flips every sign.
//
//  bhat = boostDir : unit vector along the direction of travel.
//  cosTheta = dot(n, bhat).  theta = 0 is dead ahead, theta = pi is astern.
//
//  All functions here map  REST FRAME -> OBSERVER FRAME.  Aberration
//  therefore bunches stars TOWARD bhat (the view compresses ahead and
//  expands astern), and stars ahead are blueshifted.
//
//  1) ABERRATION
//        cos(theta') = (cosTheta + beta) / (1 + beta*cosTheta)
//        sin(theta') = sinTheta / (gamma * (1 + beta*cosTheta))
//     Derivation: transform the photon 4-momentum from S to S'. For the
//     propagation direction k = -n the standard result is
//     cos(k') = (cos(k) - beta)/(1 - beta cos(k)); substituting
//     cos(k) = -cosTheta and negating again gives the form above.
//     beta -> 1 sends every theta < pi to theta' -> 0: the whole sky
//     collapses into a disc dead ahead. Poles (theta = 0, pi) are fixed.
//
//  2) DOPPLER
//        D = nu_obs / nu_rest = gamma * (1 + beta*cosTheta)     [rest angle]
//          = 1 / (gamma * (1 - beta*cos(theta')))               [aberrated angle]
//     We use the FIRST form (rest-frame angle), because that is the angle
//     we are handed. The two are algebraically identical under the
//     aberration relation above -- substitute
//     cosTheta = (cos(theta') - beta)/(1 - beta*cos(theta')) to check.
//
//     NOTE, because this is a classic trap: with n pointing AT the star,
//     D = gamma*(1 + beta*cosTheta) is the blueshift-ahead branch.
//     - theta = 0   : D = gamma(1+beta) = sqrt((1+beta)/(1-beta))  > 1
//     - theta = pi  : D = gamma(1-beta) = sqrt((1-beta)/(1+beta))  < 1
//     - theta = pi/2 in the REST frame      : D = gamma     (blueshift)
//     - theta' = pi/2 in the OBSERVER frame : D = 1/gamma   (the famous
//       transverse redshift -- it happens at APPARENT 90 deg, which
//       corresponds to cosTheta = -beta in the rest frame).
//
//  3) BEAMING -- see the long note above relBeaming(). Short version:
//     surface brightness of the star FIELD goes as D^4, but the flux of
//     one individual star goes as D^2 for a moving observer, because
//     aberration already crowds D^2 more stars into the same solid angle.
//
//  4) COLOUR -- a real spectral shift. The whole Planck spectrum scales,
//     so the observed temperature is T' = D*T (Wien), and the colour is
//     the blackbody colour re-evaluated at T'. See blackbodyRGB().
//
// -------------------------------------------------------------------
//  ARTISTIC STRENGTH DIALS
// -------------------------------------------------------------------
//  The four bare functions required by the API (relAberrate, relDoppler,
//  relShiftColour, relBeaming) are ALWAYS exact physics -- they take no
//  strength argument and never fudge anything.
//
//  The *Scaled variants take a strength in 0..1:
//      strength == 1  ->  bit-identical to the exact function
//      strength == 0  ->  exact identity (effect fully off)
//  and interpolate smoothly and monotonically in between. Nothing is
//  "exaggerated" at any setting; 1.0 is the ceiling and it is the truth.
// ===================================================================

// Simulation units: G = 1, length kpc, time Myr.
//   1 kpc/Myr = 977.79 km/s, c = 299792.458 km/s
//   => c = 299792.458 / 977.79 = 306.6021 kpc/Myr
constant float REL_C_KPC_PER_MYR = 306.6021f;


// gamma = 70.71 at the cap. Past this, float32 loses the plot.
constant float REL_BETA_MAX = 0.9999f;

// D at the cap is gamma(1+beta) = 141.4 ahead, gamma(1-beta) = 0.00707 astern.
constant float REL_D_MIN = 1.0e-3f;
constant float REL_D_MAX = 2.0e2f;

// Beaming is clamped so an HDR target cannot overflow. D^4 at beta = 0.99 is
// 3.96e4, so 1e5 keeps everything up to beta ~ 0.995 exact and only clips
// beyond that. Lower it if the scene colour target is float16 (max 65504).
constant float REL_BEAM_MAX = 1.0e5f;

constant float3 REL_LUMA = float3(0.2126f, 0.7152f, 0.0722f);

// Returned when restDir has no length at all. Arbitrary, but it must match
// `Relativity.safeNormalize`'s fallback in Relativity.swift so the CPU and
// GPU paths stay comparable.
constant float3 REL_FALLBACK_DIR = float3(0.0f, 0.0f, -1.0f);

// ---- blackbody / colour-science constants (see the note on blackbodyRGB) ----
// Planckian locus, parameterised by w = 1000 K / T so that w = 0 is T = inf.
// Degree-6 polynomial fits to CIE 1931 xy, highest power of w first.
constant float REL_LOCUS_X[7] = {
     0.132082865f, -1.89386094f,  5.44445801f, -6.24501181f,
     2.7959342f,    0.167333841f, 0.241708621f
};
constant float REL_LOCUS_Y[7] = {
     4.45352125f, -16.6438656f,  23.750536f,  -15.456974f,
     3.72725964f,   0.288324267f, 0.235529765f
};
// The locus fit's ground-truth data stops at 900 K (w = 1.111); clamp w
// inside that so the degree-6 polynomial is never extrapolated. Past the end
// it turns over and produces nonsense (a 700 K "blackbody" came out green).
constant float REL_W_MAX = 1.0f;              // clamp of w  => T >= 1000 K
constant float REL_T_MIN = 1000.0f;
constant float REL_T_MAX = 1.0e6f;

// Inverse fit: w = NUM(n)/DEN(n) where n is the reciprocal-temperature
// (McCamy-style) chromaticity coordinate. Highest power of n first.
constant float REL_INV_NUM[5] = {
     0.0255964436f, -0.0972754434f, 0.0464995727f,
    -0.0166741982f,  0.180966571f
};
constant float REL_INV_DEN[5] = {
    -0.159533799f, -0.195696369f, 0.7680673f, 1.15803206f, 1.0f
};
// Outside this the rational fit leaves its fitted interval and diverges.
constant float REL_N_MIN = -1.82f;
constant float REL_N_MAX =  1.79f;

// Luminous-efficiency model: a = hc / (k * 555 nm), the Wien argument at the
// peak of the photopic response V(lambda).
constant float REL_WIEN_A   = 25923.0f;
constant float REL_BB_PEAK_T = 6611.8f;   // where the model peaks: a / 3.92069
constant float REL_BB_PEAK_L = 3.9004f;   // log(exp(3.92069) - 1)

// -------------------------------------------------------------------
//  Uniform block. MUST match `RelativityUniforms` in Relativity.swift.
//  32 bytes, 16-byte aligned.
// -------------------------------------------------------------------
struct RelativityUniforms {
    float4 boost;      // xyz = normalised direction of motion, w = beta (0..0.9999)
    float4 params;     // x = enabled (0/1), y = dopplerStrength,
                       // z = beamingStrength, w = aberrationStrength
};

// -------------------------------------------------------------------
//  Kinematics
// -------------------------------------------------------------------

inline float relClampBeta(float beta) {
    return clamp(beta, 0.0f, REL_BETA_MAX);
}

/// Speed in simulation units (kpc/Myr) for a given beta.
inline float relSpeedKpcPerMyr(float beta) {
    return relClampBeta(beta) * REL_C_KPC_PER_MYR;
}

inline float relGamma(float beta) {
    float b = relClampBeta(beta);
    return rsqrt(max(1.0f - b * b, 1.0e-9f));
}

/// Everything the aberration needs, computed once.
/// `valid` is false when the geometry is degenerate (beta ~ 0, or the star
/// sits exactly on the forward/backward pole) -- in that case the apparent
/// direction is just the rest direction and there is nothing to rotate.
struct RelAberrationFrame {
    float3 axis;     // normalised boost direction
    float3 perp;     // unit vector perpendicular to axis, in the (n, axis) plane
    float  cosT;     // cos(theta)  in the rest frame
    float  sinT;     // sin(theta)  in the rest frame, >= 0
    float  cosTp;    // cos(theta') in the observer frame
    float  sinTp;    // sin(theta') in the observer frame, >= 0
    bool   valid;
};

inline RelAberrationFrame relAberrationFrame(float3 restDir, float3 boostDir, float beta)
{
    RelAberrationFrame f;
    f.axis = float3(0.0f, 0.0f, 1.0f);
    f.perp = float3(1.0f, 0.0f, 0.0f);
    f.cosT = 1.0f; f.sinT = 0.0f;
    f.cosTp = 1.0f; f.sinTp = 0.0f;
    f.valid = false;

    float b  = relClampBeta(beta);
    float lb = length(boostDir);
    // Fast math means a 0/0 here would be silent garbage, not a NaN we could
    // spot. Bail out explicitly instead.
    if (b < 1.0e-7f || lb < 1.0e-7f) return f;

    f.axis = boostDir / lb;

    float ln = length(restDir);
    if (ln < 1.0e-12f) return f;
    float3 n = restDir / ln;

    float c = clamp(dot(n, f.axis), -1.0f, 1.0f);
    float3 p = n - c * f.axis;
    float s = length(p);

    // theta == 0 or theta == pi: the poles map to themselves under a boost
    // along their own axis. No rotation plane exists, so there is nothing to
    // do -- and normalising `p` here is exactly the NaN we must avoid.
    if (s < 1.0e-6f) return f;

    float denom = 1.0f + b * c;            // >= 1 - beta > 0, never zero
    f.perp  = p / s;
    f.cosT  = c;
    f.sinT  = s;
    f.cosTp = (c + b) / denom;
    // Exact form. Using sqrt(1 - cosTp^2) instead would lose all precision
    // near the forward pole, which is precisely where everything ends up.
    f.sinTp = s / (relGamma(b) * denom);
    f.valid = true;
    return f;
}

/// Apparent direction of a star seen by the moving observer.
/// `restDir` points FROM the observer TO the star, in the rest frame.
/// Exact physics, no dials. Returns a unit vector.
inline float3 relAberrate(float3 restDir, float3 boostDir, float beta)
{
    RelAberrationFrame f = relAberrationFrame(restDir, boostDir, beta);
    if (!f.valid) {
        float l = length(restDir);
        return (l > 1.0e-12f) ? restDir / l : REL_FALLBACK_DIR;
    }
    return normalize(f.cosTp * f.axis + f.sinTp * f.perp);
}

/// Aberration dialled by `strength` in 0..1. The angle is interpolated,
/// theta_out = mix(theta, theta', strength), which keeps the mapping
/// monotone and keeps the poles fixed at every setting.
/// strength == 1 returns the exact result bit-for-bit.
inline float3 relAberrateScaled(float3 restDir, float3 boostDir,
                                float beta, float strength)
{
    float a = clamp(strength, 0.0f, 1.0f);
    RelAberrationFrame f = relAberrationFrame(restDir, boostDir, beta);
    if (!f.valid || a <= 0.0f) {
        float l = length(restDir);
        return (l > 1.0e-12f) ? restDir / l : REL_FALLBACK_DIR;
    }
    if (a >= 1.0f) {
        return normalize(f.cosTp * f.axis + f.sinTp * f.perp);
    }
    float th  = atan2(f.sinT,  f.cosT);
    float thp = atan2(f.sinTp, f.cosTp);
    float t   = mix(th, thp, a);
    return normalize(cos(t) * f.axis + sin(t) * f.perp);
}

/// Doppler factor D = nu_observed / nu_rest for that star.
///   D = gamma * (1 + beta * dot(restDir, boostDir))
/// > 1 ahead (blueshift), < 1 astern (redshift). Exact physics, no dials.
inline float relDoppler(float3 restDir, float3 boostDir, float beta)
{
    float b  = relClampBeta(beta);
    float lb = length(boostDir);
    float ln = length(restDir);
    if (b < 1.0e-7f || lb < 1.0e-7f || ln < 1.0e-12f) return 1.0f;

    float c = clamp(dot(restDir / ln, boostDir / lb), -1.0f, 1.0f);
    return clamp(relGamma(b) * (1.0f + b * c), REL_D_MIN, REL_D_MAX);
}

/// Doppler dialled by `strength`: D^strength, so 0 -> 1 (off) and 1 -> exact.
/// Exponentiating is the right dial here because the effect is multiplicative
/// on frequency; it keeps ahead/astern symmetric on a log scale.
inline float relDopplerScaled(float3 restDir, float3 boostDir,
                              float beta, float strength)
{
    float s = clamp(strength, 0.0f, 1.0f);
    if (s <= 0.0f) return 1.0f;
    float D = relDoppler(restDir, boostDir, beta);
    if (s >= 1.0f) return D;
    return clamp(pow(max(D, REL_D_MIN), s), REL_D_MIN, REL_D_MAX);
}

// -------------------------------------------------------------------
//  Beaming / searchlight
//
//  WHICH POWER OF D? This matters and it is easy to double-count.
//
//  I_nu / nu^3 is a Lorentz invariant, so the bolometric SPECIFIC INTENSITY
//  (surface brightness) transforms as I' = D^4 I. That is the correct law
//  for the star FIELD as a whole, and it is what relBeaming() returns.
//
//  But an individual star rendered as a point sprite carries FLUX, not
//  surface brightness, and for a MOVING OBSERVER in a field of STATIC stars
//  the per-source flux goes as D^2, not D^4:
//
//    - photon arrival rate at the moving detector  : x D
//    - energy per photon                           : x D
//    - the source's own emission pattern           : x 1  (it is not moving,
//                                                    so nothing is beamed)
//                                                 -> F' = D^2 F
//
//  Equivalently: aberration squeezes solid angle by dOmega' = dOmega / D^2,
//  so the D^4 surface brightness is recovered automatically as
//  (D^2 flux per star) x (D^2 stars per steradian). The D^2 crowding is
//  already in the geometry the moment you aberrate the star positions --
//  applying D^4 per sprite on top of that yields D^6 on the sky.
//
//  (The familiar D^4 per-source law is the blazar case: there the SOURCE
//  moves and the observer is at rest, so its emission really is beamed
//  forward, contributing the two extra powers. That is not our geometry.)
//
//  So: relBeaming() is D^4 as the API specifies, relBeamingPointSource()
//  is D^2, and REL_BEAMING_EXPONENT below selects what relTransformStar()
//  actually uses. It defaults to 2 because that is the physically correct
//  per-sprite law once the positions are aberrated. Set it to 4 if the
//  integration does NOT aberrate positions and you want the sky-brightness
//  law applied per sprite as a stand-in.
// -------------------------------------------------------------------

constant float REL_BEAMING_EXPONENT = 2.0f;

/// Bolometric beaming factor, D^4, clamped to something renderable.
/// This is the surface-brightness law (see the note above).
inline float relBeaming(float D)
{
    float d  = clamp(D, REL_D_MIN, REL_D_MAX);
    float d2 = d * d;
    return clamp(d2 * d2, 0.0f, REL_BEAM_MAX);
}

/// Per-point-source flux law for a moving observer in a static star field: D^2.
inline float relBeamingPointSource(float D)
{
    float d = clamp(D, REL_D_MIN, REL_D_MAX);
    return clamp(d * d, 0.0f, REL_BEAM_MAX);
}

/// Beaming dialled by `strength` in 0..1 with an explicit exponent.
/// The dial scales the exponent, so strength == 0 gives exactly 1.0 and
/// strength == 1 gives exactly D^exponent.
inline float relBeamingScaled(float D, float strength, float exponent)
{
    float s = clamp(strength, 0.0f, 1.0f);
    if (s <= 0.0f) return 1.0f;
    float d = clamp(D, REL_D_MIN, REL_D_MAX);
    return clamp(pow(d, exponent * s), 0.0f, REL_BEAM_MAX);
}

// -------------------------------------------------------------------
//  Blackbody colour
//
//  blackbodyRGB(T) walks the CIE 1931 Planckian locus and converts to
//  linear sRGB (D65), normalised to unit luminance.
//
//  Accuracy: the locus is a degree-6 polynomial in w = 1000 K / T, fitted
//  against Kim et al. (2002) over 1667-25000 K, against numerically
//  integrated Planck x CIE-1931 outside that, and anchored at w = 0 on the
//  exact Rayleigh-Jeans chromaticity (0.24005, 0.23396). Worst |dx|,|dy|
//  is 0.0005 over 1700-25000 K and 0.003 over the whole 700 K .. infinity
//  range. Parameterising in 1/T rather than T is what makes the whole
//  range, including the T -> infinity limit, a single smooth polynomial --
//  and it is what makes the inverse below invertible.
//
//  FAR ENDS. Both limits are real fixed points of the locus, not clamps:
//    T -> infinity : the spectrum tends to Rayleigh-Jeans (lambda^-4) and
//                    the chromaticity converges on a fixed blue-white.
//                    It does NOT keep getting bluer, because there is no
//                    bluer blackbody chromaticity to reach; what happens
//                    instead is that the visible band moves into the UV
//                    and the star goes DIM. That dimming is carried by
//                    relVisibleFraction() and applied in relShiftColour().
//    T -> 0        : converges on the deep-red end of the spectral locus.
//                    Below ~1900 K sRGB's blue primary cannot represent it
//                    and the blue channel clips to 0; below ~1250 K green
//                    clips too and the colour is a pure clipped red. The
//                    fade to invisibility is again carried by the visible
//                    fraction, not by the chromaticity.
// -------------------------------------------------------------------

inline float relPoly6(constant float c[7], float t) {
    return ((((((c[0] * t + c[1]) * t + c[2]) * t + c[3]) * t + c[4]) * t + c[5]) * t + c[6]);
}
inline float relPoly4(constant float c[5], float t) {
    return ((((c[0] * t + c[1]) * t + c[2]) * t + c[3]) * t + c[4]);
}

/// Blackbody colour in LINEAR sRGB, normalised to unit luminance.
/// Brightness is deliberately NOT encoded here -- beaming owns brightness.
/// Out-of-gamut channels are clipped to 0 (rather than desaturated), which
/// is what keeps a 1500 K star a saturated red instead of a washed-out pink.
inline float3 blackbodyRGB(float T)
{
    float w = clamp(1000.0f / max(T, 1.0f), 0.0f, REL_W_MAX);
    float x = relPoly6(REL_LOCUS_X, w);
    float y = max(relPoly6(REL_LOCUS_Y, w), 1.0e-4f);

    // xyY (Y = 1) -> XYZ
    float X = x / y;
    float Y = 1.0f;
    float Z = (1.0f - x - y) / y;

    // XYZ -> linear sRGB (sRGB D65 primaries)
    float3 rgb = float3( 3.2404542f * X - 1.5371385f * Y - 0.4985314f * Z,
                        -0.9692660f * X + 1.8760108f * Y + 0.0415560f * Z,
                         0.0556434f * X - 0.2040259f * Y + 1.0572252f * Z);
    rgb = max(rgb, 0.0f);

    float l = max(dot(rgb, REL_LUMA), 1.0e-6f);
    return rgb / l;
}

/// Approximate inverse of blackbodyRGB: the blackbody temperature whose
/// colour best matches `rgb`.
///
/// Method: linear sRGB -> XYZ -> CIE xy, then the reciprocal-temperature
/// coordinate  n = (x - 0.3320) / (0.1858 - y)  (the McCamy isotemperature
/// pencil; the constants are the point where the locus's normals converge,
/// which is what makes n very nearly linear in 1/T). Then
/// 1000/T = NUM(n)/DEN(n), a 4/4 rational fit. Two dot products, a divide
/// and nine multiply-adds -- cheap enough for a per-vertex call.
///
/// ACCURACY: round-tripping bbTemperatureFromRGB(blackbodyRGB(T)) is within
/// 2.2e-4 relative over 2000-20000 K and 2.4e-3 over 1600-200000 K, with
/// float32 coefficients. Outside roughly 1600 K it degrades and saturates
/// toward 1000 K: below that the sRGB blue channel has clipped to zero and
/// the temperature genuinely is not recoverable from the colour any more.
///
/// Inputs far off the Planckian locus (a green or magenta gas particle, say)
/// have no meaningful temperature. They are mapped to the nearest
/// isotemperature line, which is the least-wrong thing available, and the
/// y clamp below keeps the result on the correct side (bluish -> hot,
/// reddish -> cold) instead of wrapping through the convergence point.
inline float bbTemperatureFromRGB(float3 rgb)
{
    float3 c = max(rgb, 0.0f);

    // linear sRGB -> XYZ
    float X = 0.4124564f * c.r + 0.3575761f * c.g + 0.1804375f * c.b;
    float Y = 0.2126729f * c.r + 0.7151522f * c.g + 0.0721750f * c.b;
    float Z = 0.0193339f * c.r + 0.1191920f * c.g + 0.9503041f * c.b;

    float s = X + Y + Z;
    if (s < 1.0e-9f) return REL_BB_PEAK_T;      // black: no information

    float x = X / s;
    float y = Y / s;

    // On the locus y runs 0.234 .. 0.41, always above 0.1858, so this
    // denominator is always negative. Forcing it negative keeps n's sign
    // meaningful for inputs that stray below the convergence point.
    float den = min(0.1858f - y, -1.0e-4f);
    float n   = clamp((x - 0.3320f) / den, REL_N_MIN, REL_N_MAX);

    float num = relPoly4(REL_INV_NUM, n);
    float dnm = relPoly4(REL_INV_DEN, n);
    float w   = num / ((abs(dnm) < 1.0e-6f) ? 1.0e-6f : dnm);

    return clamp(1000.0f / max(w, 1.0e-6f), REL_T_MIN, REL_T_MAX);
}

/// log of the relative luminous efficiency of a blackbody: the fraction of
/// its BOLOMETRIC power that lands inside the photopic band, normalised to
/// 1 at the peak (6612 K).
///
/// Model: approximate V(lambda) as a narrow spike at 555 nm, so
///     eta(T)  ~  B(555nm, T) / (sigma T^4)  ~  1 / (T^4 (exp(a/T) - 1))
/// with a = hc/(k * 555nm) = 25923 K. Maximising gives 4(1 - e^-z) = z,
/// z = 3.92069, hence a peak at 6612 K -- which is the textbook value for
/// the maximum luminous efficacy of blackbody radiation (~95 lm/W), so the
/// one-parameter model lands on the right place by itself.
///
/// Both asymptotes are right: T -> infinity gives eta ~ T^-3 (Rayleigh-
/// Jeans), T -> 0 gives the exponential Wien collapse. Checked against
/// numerical integration of Planck against the CIE ybar: within 3% over
/// 3000-300000 K, 18% at 2000 K, and progressively optimistic below 1500 K
/// where eta is under 1e-3 and the star is invisible anyway (the spike
/// approximation ignores V's red tail, which is the only thing still
/// collecting light down there).
///
/// This is what makes extreme shifts FADE rather than merely change hue:
/// beaming gives the bolometric flux, this gives the fraction of it you
/// can actually see.
inline float relLogVisibleFraction(float T)
{
    float t = clamp(T, 1.0f, 1.0e9f);
    float xx = REL_WIEN_A / t;

    // log(exp(x) - 1), evaluated without losing the ends
    float lem1;
    if (xx > 20.0f) {
        lem1 = xx;                                        // exp dominates
    } else if (xx < 0.05f) {
        lem1 = log(xx * (1.0f + xx * (0.5f + xx * (1.0f / 6.0f))));
    } else {
        lem1 = log(exp(xx) - 1.0f);
    }
    return REL_BB_PEAK_L + 4.0f * log(REL_BB_PEAK_T / t) - lem1;
}

/// Relative luminous efficiency, 0..1, peaking at 6612 K.
inline float relVisibleFraction(float T)
{
    return exp(clamp(relLogVisibleFraction(T), -60.0f, 0.0f));
}

/// Spectrally shifted colour: a genuine blackbody re-evaluation, not a hue
/// rotation.
///
///   T  = bbTemperatureFromRGB(rgb)      the star's implied temperature
///   T' = D * T                          Wien: the whole spectrum scales
///   colour = blackbody colour at T', times the change in the fraction of
///            the spectrum that is still visible, eta(T')/eta(T).
///
/// Brightness handling: the returned colour carries the input's luminance
/// times eta(T')/eta(T) and NOTHING ELSE. The D^2 / D^4 beaming factor is
/// deliberately not included -- call relBeaming*() for that -- so the two
/// cannot double-count. The eta ratio is a separate, real effect that
/// beaming cannot express: it is why a star boosted into the UV gets dim
/// and blue-violet instead of merely blue, and why a redshifted star fades
/// out into the IR instead of just going dark red.
///
/// Two ways of applying the shift are blended, because neither alone is
/// good everywhere:
///   - a per-channel RATIO  rgb * bb(T')/bb(T). Exactly the identity at
///     D = 1 for ANY input, blackbody or not, so nothing drifts when the
///     effect is idle, and non-stellar hues keep their character.
///   - a full REPLACEMENT  luminance(rgb) * bb(T'). Correct for large
///     shifts, and the only option once a source channel has clipped to
///     zero (a red star has no blue to scale up).
/// The blend reaches pure replacement by D = 3 or D = 1/3.
inline float3 relShiftColour(float3 rgb, float D)
{
    float d = clamp(D, REL_D_MIN, REL_D_MAX);

    float T  = bbTemperatureFromRGB(rgb);
    float Tp = clamp(d * T, 1.0f, 1.0e9f);

    float3 c0 = blackbodyRGB(T);
    float3 c1 = blackbodyRGB(Tp);

    // Same floor on both, so the ratio is exactly 1 when d == 1.
    const float3 floorC = float3(0.02f);
    float3 ratio = clamp(max(c1, floorC) / max(c0, floorC), 0.0f, 50.0f);

    float3 viaRatio = rgb * ratio;
    float3 viaBB    = c1 * max(dot(rgb, REL_LUMA), 0.0f);

    // log(3) = 1.0986
    float wgt = clamp(abs(log(d)) * (1.0f / 1.0986123f), 0.0f, 1.0f);
    float3 outc = mix(viaRatio, viaBB, wgt);

    // The visible-band fraction, as a ratio so it is exactly 1 at D = 1.
    float band = exp(clamp(relLogVisibleFraction(Tp) - relLogVisibleFraction(T),
                           -18.0f, 9.0f));

    return max(outc * band, 0.0f);
}

/// Colour shift dialled by `strength` in 0..1.
/// strength == 0 returns `rgb` untouched; strength == 1 is the exact shift.
inline float3 relShiftColourScaled(float3 rgb, float D, float strength)
{
    float s = clamp(strength, 0.0f, 1.0f);
    if (s <= 0.0f) return rgb;
    if (s >= 1.0f) return relShiftColour(rgb, D);
    float de = pow(clamp(D, REL_D_MIN, REL_D_MAX), s);
    return mix(rgb, relShiftColour(rgb, de), s);
}

// -------------------------------------------------------------------
//  One-call convenience for the vertex shader
// -------------------------------------------------------------------

/// Everything the renderer needs for one star.
struct RelStar {
    float3 direction;    // apparent unit direction from the observer (observer frame)
    float3 colour;       // spectrally shifted linear rgb
    float  brightness;   // multiply the sprite's intensity by this
    float  doppler;      // D, for debugging / HUD
};

/// Transform one star from the rest frame into the cockpit's view.
///
/// `restDir` is the rest-frame vector from the camera to the star; it does
/// not need to be normalised, and its length is NOT used (aberration is a
/// pure direction map -- the distance to the star is unchanged in the
/// simultaneity slice we are rendering). Rebuild the world position as
///     aberratedPos = cameraPos + out.direction * length(restDir)
/// so the existing perspective/point-size maths keeps working unmodified.
inline RelStar relTransformStar(float3 restDir, float3 rgb, RelativityUniforms u)
{
    RelStar o;
    float len = length(restDir);
    o.direction  = (len > 1.0e-12f) ? restDir / len : REL_FALLBACK_DIR;
    o.colour     = rgb;
    o.brightness = 1.0f;
    o.doppler    = 1.0f;

    if (u.params.x < 0.5f) return o;

    float3 bdir = u.boost.xyz;
    float  beta = u.boost.w;

    o.direction = relAberrateScaled(restDir, bdir, beta, u.params.w);

    // Doppler always uses the REST-frame direction, which is what we were
    // handed -- do not feed the aberrated one back in here.
    float D = relDoppler(restDir, bdir, beta);
    o.doppler = D;

    o.colour     = relShiftColourScaled(rgb, D, u.params.y);
    o.brightness = relBeamingScaled(D, u.params.z, REL_BEAMING_EXPONENT);
    return o;
}

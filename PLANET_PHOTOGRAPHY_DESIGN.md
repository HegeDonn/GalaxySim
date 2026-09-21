# A photographic universe from inside the galaxy

Design proposal · 17 September 2026

**Recommendation:** give landed mode its own progressive renderer. Freeze a snapshot
of the actual galaxy, reconstruct a three-dimensional distribution of stars, gas
and dust, and let the image improve while the observer holds still. Spend the extra
time on light transport and fine structure, then finish with photographic processing.

The desired image has dark, branching dust lanes cutting through a dense stellar
background; faint glowing gas around young stars; blue reflection clouds; a few
brilliant stars; and a huge population of dim stars merging into the Milky Way's
soft light. Large portions of the sky should remain genuinely dark.

This file is a plan, **not a claim that these effects are already implemented**.
It extends the star explorer and planet view documented in
[STAR_EXPLORER_HANDOFF.md](STAR_EXPLORER_HANDOFF.md).

## 1. Use the galaxy as the source of structure

The existing simulation is already the best source of large-scale shape. Its disk,
spiral arms, bridge between interacting galaxies and tidal tails should determine
where the material lives. Do not put an unrelated nebula wallpaper behind it.

At landing, capture a versioned, immutable `PhotographyScene` containing:

- Selected particle identity, observer position and planet/horizon orientation.
- Particle positions, population kinds, colours, galaxy membership and weights.
- Gas tracers and their existing starburst values.
- Stable procedural seed, stellar-population assumptions and luminosity budget.
- A spatial index and progressively constructed volume/lighting caches.

The current snapshot supplied to `PlanetObservatoryView` is only a capped list of
star directions, colours and brightness proxies. **That is insufficient for depth-
correct dust or reconstructing local stars.** Preserve world positions and gas in
this new scene before reducing anything to a sky map.

Build separate smoothed fields for stellar population density, young luminous
stars and gas. For example:

```text
baseDensity(x) = sum over nearby tracers i [weight_i × kernel(x - position_i, h_i)]
```

Choose smoothing lengths from local neighbour spacing rather than using one fixed
radius everywhere. Estimate local orientation from the neighbourhood so kernels
can follow a thin disk or stretched tidal filament instead of making spherical
clouds around every particle. Do not bridge two unrelated overlapping streams
simply because they are close in projection; retain galaxy/population information.

These fields reconstruct a plausible distribution between coarse tracers. They
are not a new hydrodynamics simulation or a measurement of real interstellar gas.

## 2. Build gas and dust as related, distinct volumes

Start with the reconstructed gas density, then add nested procedural structure:

| Scale | Structure | Source |
| --- | --- | --- |
| Galactic | Disks, arms, tidal bridges and tails | Actual simulation snapshot |
| Cloud | Uneven complexes, cavities and dense ridges | Smoothed gas plus young-star locations |
| Filament | Branching dust lanes and cloud edges | Domain-warped, anisotropic 3D noise |
| Fine | Knots, wisps and irregular boundaries | Band-limited fractal detail |

Use several frequencies of coherent 3D noise, with stronger small-scale structure
where the coarse density is already high. Domain warping can bend the filaments;
local disk/flow orientation can stretch them. A broad cloud should contain fine
features, not look like several disconnected noise textures layered together.

A useful starting construction is a positive, lognormal-like density multiplier:

```text
rhoGas(x) = baseGas(x) × normalized(exp(amplitude × detailNoise(x)))
rhoDust(x) = rhoGas(x) × dustFraction(x) × dustSurvival(x)
```

Normalize over a region or brick to keep added detail from silently adding mass.
The dust fraction and destruction near hot stars are artistic/model parameters
until the scene has a calibrated gas and metallicity model. Do not present them
as quantities calculated by the existing solver.

Carve irregular cavities around young luminous associations and leave denser
ridges at their boundaries. These are plausible illustrations of feedback, not
simulated shock fronts. Older populations need much less bright emission nebulosity.

Use sparse, multiresolution bricks so empty space is cheap and nearby clouds can
carry more detail. Filter noise to the ray footprint: unresolved high-frequency
noise otherwise sparkles or aliases during rotation. Even when speed is secondary,
bounded memory and a responsive Back button remain important.

## 3. Illuminate the material, rather than painting it bright

There are three different visible effects:

1. **Reflection:** dust scatters nearby starlight into the camera. Its colour depends
   on the illuminating stars and wavelength-dependent scattering.
2. **Emission:** sufficiently energetic radiation can ionize gas; recombination and
   atomic transitions produce nebular light. A young hot association should excite
   its surroundings much more effectively than an old cool population.
3. **Extinction:** dust removes direct light through absorption and scattering out
   of the viewing direction. It can make dark lanes and redden transmitted stars.

NASA's [nebula overview](https://science.nasa.gov/universe/stories/quick-reads/decoding-nebulae/)
illustrates these categories. Dust does not only block light, and ordinary gas
should not glow uniformly just because there is a star somewhere nearby.

For the first renderer, use RGB extinction/scattering coefficients and a small
set of emission colours. More careful spectral integration can follow later.
Hydrogen emission can contribute red structure; other lines can add different
colours under suitable conditions. Keep broad-band visible colour distinct from
an optional, explicitly labelled astronomical false-colour treatment.

For lighting, evaluate important nearby stars/associations individually and group
the much larger distant population into a spatial light hierarchy or directional
radiance cache. Rank sources by estimated contribution, not just distance: a
luminous distant association may matter more than a nearby dim red dwarf.

For an isotropic point source, start with incident irradiance proportional to
`luminosity / (4 * pi * distanceSquared)`, multiplied by transmittance from the
source to the cloud. Scattered light then depends on the local scattering
coefficient and angle. Finite source size or a documented small-distance treatment
prevents singular lighting inside a coarse stellar association.

Crucially, **trace extinction between the light source and the cloud as well as
between the cloud and the observer**. Otherwise a star lights straight through an
opaque dust wall. Offscreen stars can still illuminate visible gas.

Start with single scattering and a directional phase function, such as a tunable
Henyey–Greenstein model. Its parameters are an approximation, not a universal law
for all dust. Add multiple scattering only after the simpler renderer looks good
and passes basic energy tests. See PBRT's
[phase functions](https://www.pbr-book.org/4ed/Volume_Scattering/Phase_Functions)
for the underlying rendering model.

Cold dust's thermal emission is primarily an infrared subject. Do not make every
dark lane glow orange in a normal visible-light view.

## 4. Make dust depth-correct

For a ray segment, optical depth and transmittance are:

```text
tau(lambda, d) = integral from observer to distance d of sigmaExtinction(lambda, x) dx
T(lambda, d)   = exp(-tau(lambda, d))
```

A foreground star uses transmittance only to that star. A star behind the cloud
uses the longer path. This is why a single dark overlay on the finished sky image
is insufficient: it would dim foreground and background stars indiscriminately.
PBRT's [transmittance chapter](https://pbr-book.org/4ed/Volume_Scattering/Transmittance)
provides the mathematical basis.

March through the volume front to back, accumulating attenuated emission and
scattered light. Within a segment of approximately constant coefficients:

```text
segmentT = exp(-sigmaT * stepLength)
segmentContribution = sourcePerLength * (1 - segmentT) / sigmaT
radiance += transmittanceSoFar * segmentContribution
transmittanceSoFar *= segmentT
```

Use the `sourcePerLength * stepLength` limit when sigmaT approaches zero. This
avoids changing cloud brightness merely by changing the ray-march step count.

For each star, attenuate its light by the optical depth at its actual distance.
A depth-aware cumulative-transmittance cache or distance bins along sky directions
can accelerate this, but a single total-opacity sky map cannot do the whole job.

Let extinction be stronger at blue wavelengths in an ordinary visible-light dust
model, so transmitted stars become redder as well as fainter. Keep this separate
from the relativistic redshift in flight mode: landed mode is a different camera.

An early diagnostic scene should contain an opaque cloud, one star in front and
one behind. The foreground star must remain visible while the background one
fades. That simple check is more useful than starting with a beautiful but
physically ambiguous full galaxy.

## 5. Generate additional stars from populations, not pixel gaps

The simulation's dots are coarse stellar-population tracers. I would treat them
as constraints on a stellar distribution, rather than put smaller dots halfway
between pairs. Midpoint insertion makes beads, rows and repeating constellations.

Create a hierarchy of fixed world-space cells. Each cell has a deterministic seed
based on scene identity, cell coordinates and population. Sample stars from the
reconstructed density inside it. Turning the camera must not regenerate the sky.
Do not reseed from frame number, camera direction or current visible particle count.

Use a population model to choose stellar masses and evolutionary stages:

- Many low-mass, intrinsically dim stars.
- Fewer Sun-like stars, and much rarer massive luminous stars.
- Young hot stars concentrated in young populations and associations.
- Older giants and remnants where the underlying population permits them.

An initial mass function is a starting point; it is **not** the present-day visible
star distribution. Massive stars in an old population should already have evolved.
Apply age/survival and luminosity models before deciding what the camera sees.
Kroupa's [local stellar IMF paper](https://arxiv.org/abs/astro-ph/0011328)
is a useful source for a population sampler, not a complete stellar-evolution model.

Initially use documented approximate population templates. Later, licensed stellar
isochrone tables could improve mass, temperature, radius, luminosity and age
consistency. Do not infer all of these from the current particles' decorative RGB.

Generate nearby stars individually, with stable positions and luminosities. The
observer must be placed in a plausible local stellar neighbourhood, not surrounded
by an identical little cluster centred on each original tracer. An observer-relative
coordinate origin avoids precision problems when adding parsec-scale detail to
kiloparsec galaxy coordinates; use higher precision for global cell bookkeeping.

For distant stars, split the light into three components:

1. Explicit bright/resolved stars.
2. A deterministic sample of fainter point sources when useful.
3. The remaining unresolved stellar luminosity as a smooth, structured background.

This gives the Milky Way its glow without allocating every star in the galaxy.
Small stars usually do not need tiny 3D spheres: from a planet they are unresolved
sources whose apparent shape is set by optics and atmosphere.

### Preserve the light budget

Adding a million decorative stars must not make the galaxy a million stars brighter
unless that is an intentional change to the model.

Assign a luminosity budget to each population/cell, normalized independently of the
number of simulation tracers. Allocate it between resolved stars and the unresolved
component. When a star becomes explicit, subtract its contribution from the latter.
When replacing a tracer with a synthetic population, do not keep the tracer's old
full brightness underneath that population.

There are two separate goals: reconstructing an assumed galaxy's actual star count,
and obtaining an unbiased rendered estimate with a manageable sample. Document
which is being done. Importance-sampling weights belong to the rendering estimate;
they are not literal luminosities for stars shown in the educational inspector.

## 6. Progressive rendering is the main advantage of landed mode

I would build this as a separate Metal photography renderer, leaving the interactive
galaxy simulation and flight shaders intact.

```text
Frozen galaxy snapshot
    -> population density + gas/dust volume + spatial light hierarchy
    -> stable local stars + unresolved distant light
    -> per-ray extinction, emission and scattering
    -> atmosphere + horizon/terrain visibility
    -> linear HDR image / progressive sampling
    -> camera exposure, sensor response and photographic finishing
```

While dragging, render a reduced-resolution preview with fewer volume samples and
a modest softening/motion treatment. Once the view settles, progressively increase
sample count and detail. Cache the geometry, procedural population and lighting;
only discard accumulation that became invalid.

**Keep exposure duration and rendering quality as separate internal quantities.**
More Monte Carlo samples reduce rendering noise; they should not make the scene
brighter. Exposure duration changes collected light and, in a sensor model, the
noise and possible star trails. A longer render of the same exposure should
converge toward the same image.

The current playful blur-then-reveal interaction can remain as the presentation.
Underneath, accumulate in linear HDR and normalize sampling correctly. Camera
movement resets or carefully reprojects history; never retain old-view stars as
accidental ghosts. Changing exposure alone can reuse an already converged radiance
image, although the gathering-light animation may restart for the experience.

The quality ladder could be immediate preview, a richer result after a few seconds,
and an optional longer **Develop photo** action. Exact timings need measurement.
Use tiled high-resolution export and cancellation so even a long render remains
usable on the MacBook Air. No Blender connection is required for this architecture.

## 7. What I would do in photographic finishing

Good post-processing helps after the depth and lighting are correct:

- A physically motivated point-spread function: sharp stellar cores, restrained
  wings, and modest bloom applied to linear light before tone mapping.
- Gentle local contrast to reveal faint dust structure without crushing the sky
  to black or lifting all empty space to grey.
- Exposure, colour balance and a filmic highlight shoulder; preserve coloured
  halos around clipped stellar cores rather than turning every star into a blob.
- Optional restrained shot/read noise and stacking. Noise is part of a camera
  model, not a substitute for missing scene detail.
- Mild vignetting and optional lens diffraction appropriate to the chosen optics.
  Avoid identical dramatic spikes on every star.

An Earth-like atmosphere adds horizon extinction/reddening and subtle airglow.
Light pollution, if present at all, should be a separate optional layer. Keep an
initial night-side orientation so the host star does not simultaneously imply
bright daylight while the sky is rendered as a dark exposure.

For a future physically motivated long exposure, distinguish a fixed tripod from
sky tracking: planetary rotation can make trails in the first case. Human dark
adaptation, camera exposure and computational accumulation are different effects.
The interface can remain simple while the implementation keeps them separate.

My artistic priority is **contrast and depth**: a dark lane should feel like material
in front of luminous space, not a smoky grey texture pasted over everything.

## 8. Implementation sequence for this repository

| Stage | Work | Evidence needed before continuing |
| --- | --- | --- |
| 1 | Freeze a complete photography snapshot and define light budgets | Repeatable scene; changing tracer count does not arbitrarily change total light |
| 2 | Generate stable local stars and unresolved far light | No repeated bead clusters, camera-dependent reseeding or double-counted luminosity |
| 3 | Add a single depth-aware dust volume | Foreground/background test, wavelength-dependent dimming, step-size convergence |
| 4 | Add stellar illumination and limited gas emission | Move a light and illumination follows; occluding dust casts a volumetric shadow |
| 5 | Add multiscale cloud detail and lighting caches | Detail follows galaxy arms/tails and remains stable during rotation |
| 6 | Add progressive HDR sampling and photographic finishing | Exposure changes brightness; quality changes noise; movement cleanly resets history |
| 7 | Add optional spectral/sensor refinements and tiled export | Compare images across resolutions, seeds and long render durations |

Suggested new components, rather than growing the existing view into one huge file:

- `PhotographyScene.swift`: snapshot, scene identity, observer and units.
- `StellarPopulationField.swift`: deterministic synthesis and luminosity allocation.
- `InterstellarMedium.swift`: sparse gas/dust density, coefficients and caches.
- `PhotographyRenderer.swift` and dedicated Metal shaders: transport and accumulation.
- `PhotoDevelopment.swift`: exposure, optics, noise and tone mapping.

`PlanetObservatoryView` should remain the simple control surface. Its current
20,000-direction snapshot and brightness-proxy point rendering can be the fast
fallback, but not the foundation of a depth-correct photographic renderer.

## 9. Acceptance tests and limits

The finished direction should pass these checks:

- Rotating away and back reveals the same stars and clouds.
- A dust lane changes foreground/background visibility correctly.
- Increasing ray steps improves convergence rather than inflating brightness.
- Increasing synthetic star count preserves the prescribed population light budget.
- A cloud can be illuminated by a bright star outside the camera's view.
- A hot young association produces a different environment from an old population.
- Dust dims/reddens direct starlight while also contributing scattered light.
- No light source means no reflected light; any remaining emission has an explicit cause.
- Longer exposure and more rendering samples are independently testable.
- The scene stays recognizably the selected location in the actual simulated galaxy.

Even a gorgeous result remains a reconstruction from coarse galaxy tracers. Real
molecular-cloud dynamics, accurate stellar ages, chemical abundances, ionization,
planet orbits and an Earth catalogue would require additional models/data. Label
approximations honestly, but spend the visual effort on coherent geometry,
illumination, darkness and stable fine detail.

**The first visual milestone I would build is a dense, softly luminous stellar band
with one convincing, depth-correct branching dust lane.** Once that works, luminous
cloud rims and pockets of excited gas will have a believable place to live.

# Galaxy Collision Simulator

Real-time 3D galaxy-collision simulator for Apple Silicon. Swift + Metal, no
dependencies.

    swift build -c release
    ./.build/release/GalaxySim

## Two interfaces

**Kids mode** (default) — big icon buttons, three speeds (turtle / walk /
rabbit), and **Creation** for adding galaxies. Click Creation to reveal the
galaxy templates, choose one, **Shift-drag** to rotate its preview, then click
to place it. Click Creation again to hide the templates; **Play** runs the
simulation. Regular drag still orbits the camera. Opens paused
so you see two intact galaxies rather than a merger that already finished.
The hamburger switches to:

**90s Engineer Mode** — the dense panel: solver choice, particle budget,
pause/restart, exposure/glow/star-size, numeric readouts. Rewind has been removed
to avoid retaining full copies of large simulations.

## Relativistic flight

Press **F** or the rocket button to follow **LUMEN**, an oval city ship.
Drag to orbit around it, scroll to zoom, and press **C** or **Follow ship**
to return to the chase view. Looking around never changes the ship's heading.
**A/D** steer; **W/S** change speed. The top-right **Pause / Resume** button
or **Space** freezes/resumes the journey while preserving its optical effects;
**Esc** or **Back to galaxy** leaves flight. **Tab** hides the controls.
Large buttons provide Cruise, Warp and Extreme presets, turning and pause.
Flight hides the encounter's engineering panels regardless of interface mode.

The ship has seven recessed horizontal decks with tiny illuminated windows,
open central bays, antennae, outriggers and recessed engines. There are no
exposed city buildings. Dark reflective metal catches localized blue/red hull
lamps and cyan engine spill, leaving large areas in deep shadow. Lighting and
reflection highlights are economical approximations, with baked local AO.
The ship and its lights render before the existing optical glow. The local
ship remains rigid while relativity affects the surrounding sky. The journey
accelerates galactic time; the displayed percentage controls the light effects.

Regenerate editable Blender source with this authoring sequence:
`build_cityship.py`, `refine_cityship.py`, **`darken_ship.py`**, then
`export_cityship.py`, all under `Tools/Blender/`. The old Geometry Nodes
buildings are preserved hidden for history and excluded from the export.
Blender is only needed for authoring. See [PUBLICATION.md](PUBLICATION.md) for
authoring setup and release preparation. Historical Blender files and review
captures are omitted from the public source distribution.

Check background inverse aberration on the GPU and capture isolated sky views:
`./.build/release/GalaxySim --skytest --out /tmp/sky-review`

Render eight orbit/speed views and benchmark ship overhead:
`./.build/release/GalaxySim --shiptest --size 1440x900 --out /tmp/ship-review`

Launch directly into flight with `./.build/release/GalaxySim --flight`.
Run native input/button/slider regression checks and capture two window sizes with
`./.build/release/GalaxySim --uitest --out /tmp/galaxy-ui-review`
(requires a graphical session, Metal access, and screen capture permission).

The optics are exact special relativity, not a stylised effect:

- **Aberration** `cosθ′ = (cosθ + β)/(1 + β cosθ)`, applied as a vector
  rotation using the exact sine form (`sinθ′ = sinθ/(γ(1+βcosθ))`), which
  keeps precision at the forward pole where everything ends up. The forward
  hemisphere compresses into an 8.1° cone at β = 0.99.
- **Doppler** `D = γ(1 + β cosθ)` on the rest-frame angle. Note the transverse
  redshift `D = 1/γ` lives at the *apparent* 90°, not the rest-frame one —
  at rest-frame 90° the factor is γ, a blueshift.
- **Beaming** `D²` per sprite, *not* `D⁴`. `I_ν/ν³` invariance gives D⁴ for
  surface brightness, but a point source seen by a moving observer in a static
  star field gets D² in flux; aberration already squeezes solid angle by D²,
  so sky brightness recovers D⁴ on its own. Applying D⁴ per sprite on top of
  aberrated positions would give D⁶. (D⁴ per source is the blazar case —
  moving source, stationary observer.)
- **Colour** is a real spectral shift: the star's blackbody temperature is
  estimated from its RGB, scaled `T′ = D·T` (Wien), and re-evaluated on the
  Planckian locus — not a hue rotation. A separate luminous-efficiency term
  carries the fade as the peak leaves the visible band; it peaks at 6612 K,
  which is the textbook maximum luminous efficacy of blackbody radiation.

Verified: aberration matches the closed form to 7e-7 (float32-limited above
β=0.99), Doppler hits `√((1+β)/(1−β))` forward and its reciprocal aft exactly,
beaming ratios match `((1+β)/(1−β))²` squared, and the blackbody colour round
trip is within 2.2e-4 over 2000–20000 K. Measured in-engine, the blue fraction
of chroma rises 0.3768 → 0.3912 → 0.3987 for β = 0 → 0.5 → 0.9.

Flight speed is decoupled from the optics: `flightTimeScale` maps wall-clock
to coordinate time so a 30 kpc disk takes ~20 s to cross at β=0.99, while the
optics stay exact for whatever β is set.

## Controls

| Input | Action |
|---|---|
| drag | orbit camera |
| scroll / pinch | zoom (disables auto-framing) |
| space | play / pause in orbit; pause / resume journey in flight |
| R | restart |
| S | screenshot to ~/Pictures in orbit; throttle down in flight |
| O | toggle camera auto-orbit |
| F | enter/leave relativistic flight |
| esc | leave flight |

## Physics

Simulation units are chosen so **G = 1**: length kpc, time Myr, mass
2.2229e11 Msun, speed 977.79 km/s. A Milky Way analogue is 4.3 mass units
with a 215 km/s rotation curve at R = 8 kpc.

Integration is drift-kick-drift leapfrog (2nd-order symplectic), split into
three GPU dispatches so every solver shares one code path.

### Solvers

- **Restricted (O(N))** — each galaxy is a smooth three-component potential
  (Hernquist halo + Miyamoto-Nagai disk + Hernquist bulge); stars are test
  particles. This is the Toomre & Toomre (1972) approach that first explained
  tidal tails. Scales to millions of particles. Does not model self-gravity
  of the tails.
- **Barnes-Hut (self-gravity)** — the box approximation. A Karras linear BVH
  built entirely on the GPU: atomic bounding box → Morton codes → GPU radix
  sort → hierarchy → bottom-up mass/CoM merge → stackless rope traversal with
  an opening angle θ. Verified against an exact double-precision direct sum:
  median relative error 0.20–0.32% at θ=0.5 for 100k–500k, converging to
  4.6e-7 at θ=0 (i.e. the tree is exact when it stops approximating).
- **Direct N²** — exact, tiled through threadgroup memory. The reference.

Self-gravitating modes use a **live baryonic disk in a rigid dark halo**:
particles trace the visible galaxy, so they carry only disk+bulge mass, and
the halo stays analytic. Giving the particles the total mass would force a
~4:1 dark-matter overweight into a disk-shaped distribution.

Softening scales as N^(-1/3). These initial conditions are built for a rigid
potential (σ_R ≈ 10% v_c), which sits below the Toomre threshold once
self-gravity is live — at 0.25 kpc softening a 60k disk fragments and r90 goes
10.6 → 15.6 kpc in 300 Myr; at 0.8 kpc it holds at 9.9–11.0 kpc.

### Galaxy centres

Integrated on the CPU (there are only a few) with:

- **Symmetrised mutual gravity.** Each galaxy is a point when it *feels* the
  other's potential but an extended, disk-flattened mass when it *generates*
  one, so `m_i a_ij` and `-m_j a_ji` disagree once the disks are tilted
  differently. The pair force is averaged, which restores Newton's third law
  exactly (measured centre-of-mass drift: 0.000 kpc over 1200 Myr).
- **Chandrasekhar dynamical friction**, applied as an action/reaction pair,
  evaluated at a softened radius and capped at 50% of the mutual gravity.
  Without the cap the 1/r density divergence blows up when cores overlap.

### Encounter setup

Pericentre is solved numerically against the real potentials, not the
point-mass formula. With extended haloes only a fraction of the mass is
enclosed at close separation, so the textbook formula aiming for 18 kpc
actually yields 31 kpc. Bisection on the tangential velocity hits the
requested value to <0.1 kpc.

### Star formation

Gas particles that feel a strong pull from the *other* galaxy are flagged as
shocked and ramp a temperature the renderer turns into a blue-white starburst,
cooling over ~100 Myr. Tuned so ~4% of gas ignites at pericentre, spreading to
~40%.

## Rendering

HDR point sprites, additive (order-independent), into rgba16Float, then a
**sensor/film model** rather than a conventional bloom:

1. **Optical point spread, applied in linear light before exposure.** Four
   octaves of downsample+blur, weighted toward the narrow scales, approximate
   the sharp core and fast-falling wings of a real PSF. There is deliberately
   no brightness threshold: a lens scatters all the light it receives, and a
   threshold throws away exactly the faint chromatic halo we want.
2. **Halation** — a warm ring on the narrow octaves, reproducing light that
   penetrates the emulsion, scatters off the film base and re-exposes from
   behind, filtered warm on the way back.
3. **Per-channel film response**, a Naka-Rushton curve `R = E^n/(E^n + K^n)`.
   K is the exposure that renders mid-grey (film speed), n < 1 compresses the
   several decades between a galactic nucleus and a tidal tail.

The per-channel part is the point. An over-exposed star drives all three
channels past saturation and renders white, while the halo the PSF put around
it is orders of magnitude dimmer, stays on the responsive part of the curve,
and keeps the star's true colour. Applying a curve to *luminance* and carrying
chroma through unchanged — the obvious approach, and what this did before —
mathematically forbids that.

Measured on three over-exposed test stars (`--sensortest`), chromaticity r:g:b
at the core versus a 14px halo:

| star (emitted) | core | halo |
|---|---|---|
| blue 0.55:0.72:1.00 | 0.333:0.333:0.334 (white) | 0.317:0.327:0.356 |
| yellow 1.00:0.92:0.72 | 0.333:0.333:0.333 (white) | 0.360:0.334:0.306 |
| red 1.00:0.50:0.28 | 0.335:0.334:0.331 (white) | 0.418:0.321:0.261 |

Per-channel compression desaturates midtones, which is also true of real film;
a chroma gain compensates, as dye couplers do in a real stock.

Per-particle brightness is divided by N so total emitted light is independent
of particle count: 50k and 2M expose identically.

The pyramid costs *less* than the bloom it replaced — 7.8 ms vs 8.8 ms at
3400x2100 with 600k particles — because each octave works on a quarter of the
previous one's pixels.

## Background: the cosmic web, actually evolved

Not cell noise dressed up to look like large-scale structure — the real thing,
via the **Zel'dovich approximation** (1970). Each parcel of matter moves from
its initial position q to x = q + D·ψ(q) with ψ = −∇φ, and mass conservation
then gives the density in closed form:

    rho / rho_bar = 1 / |(1 - D*l1)(1 - D*l2)(1 - D*l3)|

where l1..l3 are eigenvalues of the deformation tensor, i.e. the Hessian of the
initial potential. The entire morphology falls out of that one expression:

  * one eigenvalue collapsing  -> a SHEET
  * two collapsing             -> a FILAMENT
  * three collapsing           -> a CLUSTER

No FFT, no particles, and the density genuinely diverges at caustics, which is
where the huge dynamic range comes from.

Three things had to be right for it to work at all:

1. **Quintic interpolation in the value noise.** The density needs the Hessian
   of the potential, and the usual cubic smoothstep `f²(3−2f)` is only C1 — its
   second derivative jumps at every lattice boundary, so the Hessian is noise
   and the structure collapses to speckle.
2. **Rotated octaves.** Value noise is measurably anisotropic along its cubic
   lattice, and second derivatives amplify that until the field looks like
   brickwork. Each octave is evaluated in a different rotated frame.
3. **A smoothed initial field** ("truncated Zel'dovich"). A Hessian is dominated
   by the smallest scale present, so a full fbm gives a tidal tensor of
   high-frequency hash with no coherent sheets.

Colour comes from the reference image itself: its density→colour ramp and
luminance distribution were measured, and the field is remapped through its own
CDF so the ramp — which is indexed by percentile — reproduces the distribution
by construction. Filament colour matches the reference to about 0.3 RGB units.

It emits **linear HDR radiance** into the scene buffer before the PSF and the
film curve, so exposure reaches it. Default strength is deliberately tiny
(0.0035): enough that the sky is not flat black, with the web only really
emerging as you wind exposure up. There is a "Cosmic web" slider in the
engineer panel.

Baked once at launch into a 2048x1024 equirectangular map (~0.7 s); per-frame
cost is 0.99 ms. In flight mode it aberrates with everything else and takes the
D⁴ surface-brightness law.

## Performance upgrade (2026-09-16)

See [PERFORMANCE_HANDOFF.md](PERFORMANCE_HANDOFF.md) for measured results,
implementation details and the continuation plan. The restricted solver now
fuses its three integration passes. Initial conditions stream into GPU memory;
there are no rewind snapshots. Above 1M particles, adaptive GPU selection draws
stable, brightness-weighted samples of distant stars while retaining nearby
stars. This is approximate rendering; every particle still undergoes physics.

The engineering panel offers up to 20M stars. This is experimental capacity,
not a 60 fps promise. Under load, physics catch-up is bounded to keep interaction
responsive; the timestep is unchanged and galaxy time advances more slowly.

Run numerical/visibility checks and combined-frame measurements:

```sh
swift build -c release
./.build/release/GalaxySim --perftest --budget 1000000 --size 1440x900 --out Review/Performance/1M
```

A/B controls: `--look fullstars=1` disables adaptive rendering;
`--look starbudget=500000` changes its expected distant sample count;
`--look splitphysics=1` uses the old three-pass restricted integrator.

### Historical baseline (before the performance upgrade)



| Particles | Step time | Physics-limited fps @ 2 steps/frame |
|---|---|---|
| 150k | 0.99 ms | 507 |
| 300k | 1.84 ms | 271 |
| 600k | 3.47 ms | 144 |
| 1M | 5.76 ms | 87 |
| 2M | 11.09 ms | 45 |

Direct N²: 16k = 7.6 ms, 32k = 27.3 ms.

Barnes-Hut on a real galaxy pair: 30k = 4.1 ms, 60k = 9.7 ms, 120k = 22.3 ms,
250k = 60.6 ms. Traversal dominates (~86–96% of the step); build is the cheap
part.

## Audio

Procedural ambient synthesis (AVAudioEngine, no samples). Drone bed plus
portamento pad voices that glide continuously between scale degrees over
0.8–2.5 s. Encounter proximity raises synth level and opens the filter;
dispersal (r90/r50 of the particle cloud, free from the camera's extent
sample) swells a brown-noise bed underneath.

## Headless modes

    --headless --scene N --shots "t1,t2" --out DIR --size WxH
    --bench          step-time benchmark
    --info           structural + orbital diagnostics
    --gallery        render all 11 galaxy types
    --camtest        camera smoothness / COM drift
    --buildtest      exercise the click-to-place path
    --look k=v,...   override look parameters (bright, white, beta, sat, ...)

## Known limitations

- Restricted mode has no self-gravity in the tails, so they do not clump into
  tidal dwarf galaxies.
- Bars in SBb/SBc shear out: the potential is axisymmetric, so there is no bar
  pattern to sustain the x1 orbits.
- Merged cores sit at exactly zero separation rather than forming a
  self-consistent remnant.
- Merger completes ~300 Myr after first pericentre, on the fast side.
- Barnes-Hut is limited to ~60k particles for 60 fps, so its disks are visibly
  noisier than the restricted solver's at 600k. It is the mode to use when you
  want self-gravity, not the one to use for the best-looking picture.

## Star explorer and planet sky

Click a star outside Creation mode (also works in flight). A cyan reticle follows
that particle as the simulation moves. Its card shows a procedural 3D portrait,
a schematic H–R diagram, Sun comparisons and an illustrative life story. These
are representative stars for the tracer population; their ages are not measured
or evolved by the galaxy solver. Gas particles are not selectable as stars.

Choose **Watch its night sky** to visit an imagined Earth-like observing site.
Drag or scroll to look around. Choose an exposure from 0.2 to 30 seconds; motion
resets the gathering-light effect, and stillness makes stars brighter/sharper.
The directions come from the current galaxy around your selected particle, not
an Earth star catalogue. Brightness/exposure are artistic approximations.
**Back to the stars** or Escape returns to your previous selection and pause state.

See [STAR_EXPLORER_HANDOFF.md](STAR_EXPLORER_HANDOFF.md) for sources, implementation
and review results. Diagnostics: `--explorertest` (GPU picking/models) and
`--uitest --explorerreview` (native workflow and screenshots).

## License

MIT — see [LICENSE](LICENSE).

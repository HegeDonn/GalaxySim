# Star explorer and planet sky — active, 2026-09-17

## User intent
Click a star; keep a clear marker attached as it moves. Show an animated 3D star,
a schematic Hertzsprung–Russell diagram, typical properties, lifespan, example
time left, fate, and comparisons with the Sun. Then visit a planet-side dark sky,
drag to look around, and choose exposure duration: moving blurs/resets the view,
stillness gradually reveals it. Keep this playful and accessible.

## Design and scientific boundaries
The simulation particles are stellar-population tracers (and gas), not individually
aged stellar evolution models. The inspector must visibly identify its star as a
representative educational model. Ages are examples, not measurements. Do not use
particle gravitational mass as a star's solar mass. Ignore gas particles in picking.
Model values obey L/Lsun = (R/Rsun)^2 (T/5772K)^4. Spectral/evolution categories
follow NASA and ESA, with approximate representative lifetimes, not predictions.

Sources:
- https://science.nasa.gov/universe/stars/types/
- https://science.nasa.gov/exoplanets/stars/
- https://www.esa.int/ESA_Multimedia/Images/2018/04/Gaia_s_Hertzsprung-Russell_diagram

Planet landing is an imagined Earth-like observing site, not a claimed simulated
planet or catalog-accurate Earth sky. The background star directions are sampled
from the actual current galaxy relative to the selected tracer. Brightness and
exposure are illustrative. State this in the interface.

## In progress
- Root: StellarProfile.swift, GPU picking, persistent selection identity/marker,
  App integration, diagnostic tests, packaging.
- star_portrait agent: StarInspector.swift (written; integration/build pending).
- adaptive_rendering agent: PlanetObservatory.swift (in progress).

Existing performance changes remain uncommitted; preserve them and the externally
modified Blender .blend/.blend1 files. No Blender needed for this task.

## Validation to complete
Build Swift AND execute runtime Metal; select real visible stars, drag vs click,
marker follows motion, identity clears on scene reload but survives insertion,
selection under extreme aberration, portrait/card at small window sizes,
planet enter/exit restores pause/UI, drag resets exposure, exposure slider works,
cleanup stops both secondary render loops, save screenshots and update this memo.

## Latest requested extension: photography design

The user subsequently requested a FILE describing procedural illuminated gas,
absorbing/dimming dust, additional smaller stars between tracers, and expensive
post-production specifically for landed photography mode. That design is now in
[PLANET_PHOTOGRAPHY_DESIGN.md](PLANET_PHOTOGRAPHY_DESIGN.md). It is a proposal, not
implemented volumetric rendering. It preserves galaxy structure, includes depth-
correct extinction/scattering, stable population synthesis and light budgeting,
and separates physical exposure from progressive rendering convergence.

## Validation so far

`--explorertest` passed gas rejection, partial GPU workgroup, blank-sky miss,
rearward source aberrated into view at .99c, moving/insertion identity, restart
invalidation and 800 self-consistent stellar profiles. Native workflow review
passed opening the card, retaining selection on drag, planet entry/exit and pause
restoration, exposure resets and short/long accumulation, with explicit GPU draw
completion. Evidence: Review/Explorer/UI and Review/Explorer/PortraitFix.

Visual review found and fixed a shader issue not caught by functional tests:
SceneKit Metal modifiers use `scn_frame.time`, not `u_time`; a failed shader showed
a magenta portrait. Final surface/limb/corona polish and packaging are being verified.
Night-sky capture initially stayed black because synchronous UI review did not run
MTK display callbacks; reviewDraw() now forces, waits for and checks a real frame.
The actual photograph view currently remains a point-star snapshot with an
illustrated horizon, NOT the proposed volumetric gas/dust renderer.

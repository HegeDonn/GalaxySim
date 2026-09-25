# Planet exploration — current implementation

This document describes the shipped observatory navigation, not the original
separate landing minigame. The filename is retained for existing links.

## What the player sees

Choosing **Land on the planet** opens the photographic sky directly. A small
procedural planet and a round flight pad appear beside the exposure dial.
There is no separate landing preview, Land confirmation, or descent animation
in this flow.

The pad moves the observer across the planet; its outer ring turns the heading.
Movement has a little momentum and stops quickly on release. The globe itself
has no mouse navigation. While the navigator has keyboard focus:

- **WASD / arrows:** move.
- **Q / R:** turn.
- **Space:** brake.
- **E:** open or close the planet material workshop.
- **Enter / Escape:** close the navigator, keeping the current location.

The actual photographic sky updates during navigation. The horizon responds to
both travel and turns. Moving to a new location cancels an exposure; ordinary
camera dragging can still produce star trails during an exposure.

After six idle seconds, only the globe hides and the pad dims. Keyboard or pad
input restores it; using the workshop keeps it awake. The location icon toggles
the whole navigator without resetting the view. Pressing the shutter or the
day/night button closes it. With the navigator closed, Escape leaves the
observatory.

## Daylight and photography

Day/night gently moves the sun while leaving the camera, galaxy and ground
orientation fixed. A second press stops the transition. This is a photography
convenience, not a literal simulation of a planet rotating through a day.

When the sun is above the horizon, Auto exposure uses a sunlight-based estimate:
0.25 seconds for dim daylight, faster shutter speeds for brighter host stars.
Looking down or away from the sun does not change the daylight exposure.
The manual dial remains available for night photography. The star's properties
and the atmosphere still affect the appearance of the scene.

## Planet rendering and workshop

`PlanetGlobeView` draws an analytic sphere and procedural materials directly in
Metal at native drawable resolution. There is no CPU texture baking. Pipeline
compilation runs on a background queue and the pipeline is shared. Command
submission is bounded to two in-flight buffers; navigation updates run at 30 Hz.
Removing the navigator stops its timer.

The terrain seed comes from the selected tracer's index and population, so
revisiting the same star preserves its terrain pattern. Weather animation clocks
restart when a new navigator is created.

Cloud-bearing planets use a raised shell with animated noise coordinates,
vector warping and cloud shadows. Water has ripple normals, approximate shallow
refraction and filtered sun glints. The atmosphere uses an exponential shell
with a palette selected by the atmosphere preset. These are illustrative
materials, not fluid simulations or spectral chemistry predictions.

Hydrogen-helium and methane ice giants animate their gas bands directly, with
rotation, latitude-dependent shear and vector evolution. They do **not** add the
separate cloud shell or its shadows.

The **E** workshop switches between cloud/water controls and gas controls.
Planet-type switching previews a material; it does not change the actual
observatory planet or sky. **Save** persists shared material settings locally;
**Copy JSON / Paste JSON** exchange settings. **Reset** previews current defaults;
Save is needed to persist that reset. Existing saved values override defaults.
`PlanetTuning.swift` is the authoritative list of defaults and slider ranges.

## Implementation map

- `LandingGame.swift`: transported surface navigation, embedded planet/pad,
  keyboard input, idle behavior, workshop and synthesized movement sound.
- `PlanetGlobe.swift` and `Shaders/PlanetGlobe.metal`: GPU planet materials,
  animation clocks, atmosphere, clouds, water and ship glyph.
- `PlanetTuning.swift`: material settings, persistence and workshop controls.
- `PlanetObservatory.swift`: navigator lifecycle, live sky/terrain changes,
  sun-only transitions and daylight exposure.
- `PlanetSky.swift`: surface frames and host-star properties.
- `StellarProfile.swift`: stable planet seed.
- `FlightHUD.swift`: the shared round flight pad.
- `App.swift`: native interface and exposure regression review.

## Limits and remaining cleanup

The photographic horizon is a lightweight procedural skyline. Its world
orientation and position-dependent phases give movement cues, but its hills
are **not** sampled from the small globe's terrain.

The old full-screen preview and descent code still exists in `LandingGameView`.
The observatory uses embedded mode exclusively; those older paths should not
be mistaken for the current user experience. Removing unused presentation code
is a possible future cleanup.

## Verification

The published implementation passed a release build and the native explorer
review, covering navigation, first-turn response, layout at two window sizes,
workshop JSON, idle globe hiding, shutter closure, reopening without camera
rotation, stable day/night orientation and stable daylight exposure when
looking away. Existing star-card and photographic exposure checks also passed.

Run from a graphical macOS session with Metal access:

```sh
swift build -c release
./.build/release/GalaxySim --uitest --explorerreview --out /tmp/planet-review
```

Screen capture permission may be needed for review screenshots. Timing varies
with hardware and scene; historical development timings are not performance
guarantees. No Blender installation is required to render the planets.

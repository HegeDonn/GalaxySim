# Planet landing — implementation and handoff

## Current implementation

The landing game uses a centred ship, a rotating planet, and the same round
ShipStick control as flight. Centre pad translates; ring rotates. Release stops
quickly. WASD/arrows translate, Q/R rotate, Space brakes, Enter lands, Escape
cancels. Pointer navigation on the globe itself is disabled.

The horizon inset samples the actual simulation sky. Land applies its chosen
surface frame with a short descent. Cancel preserves the previous site/photo.
Planet axis, host-star direction and day length persist when changing locations.
The inset simplifies brightness and terrain; the final observatory retains its
existing atmosphere, exposure dial, star portraits and camera controls.

## Direct Metal planet renderer

The CPU texture generator, bitmap shading, background baking queues and texture
cache have been removed. `PlanetGlobeView` is a transparent MTKView which draws
a fullscreen triangle at native drawable resolution. The fragment shader
intersects a sphere and evaluates procedural materials directly on the GPU.
There is no planet texture bake, CPU pixel loop, readback or fixed texture size.
Shader compilation occurs once on a background queue; its pipeline is shared.
At most two command buffers may be in flight. The existing 30 Hz landing timer
drives drawing; leaving the picker stops submissions.

A stable 32-bit seed is derived from particle index/population in StellarProfile
and passed as two exactly representable 16-bit values. Different stars can have
different terrain/cloud patterns within the same atmosphere class. Revisiting
preserves the terrain seed. Weather time restarts when reopening the picker.

Clouds occupy a radius-1.018 sphere and rotate slowly independently of terrain.
Continuous translation through a fixed noise volume plus low-frequency vector
warping changes their shapes. No crossfade between independent noise fields is
used. Gas-planet bands share vector evolution and latitude-dependent rotation. Sun rays intersect the same animated cloud field to cast
subtle shadows. Cloud relief uses a short directional density difference.

Earth-like water refracts the view through animated ripple normals toward a
procedural shallow seabed, with small Fresnel reflections and sun glints. This
is a thin-water approximation, not a fluid simulation or detailed ocean mesh.
Atmosphere scattering/extinction uses an eight-sample exponential shell and
planetary shadow; its palette and density track the existing atmosphere preset.
Chemistry palettes are artistic interpretations, not spectral predictions.
Near-vacuum has no air/clouds; thin CO2 has faint air and no dense clouds.

## Files

- `LandingGame.swift`: drone navigation, preview, Metal view integration, sound,
  descent and diagnostic hooks.
- `PlanetGlobe.swift`: GPU device/pipeline, uniforms, native drawable, bounded
  command submission and GPU timing. No CPU material generation.
- `Shaders/PlanetGlobe.metal`: terrain, seas, cloud evolution, shadows, atmosphere
  and the small ship glyph.
- `StellarProfile.swift`: stable planet seed from tracer identity.
- `FlightHUD.swift`: shared ShipStick; flight behaviour unchanged.
- `PlanetSky.swift`: relocated frames retaining planet identity.
- `PlanetObservatory.swift`: picker lifecycle, seed handoff and arrival.
- `App.swift`: native landing/control/exposure checks and weather-time captures.

## Validation

First Metal review passed, with approximately 33 ms screen entry and an 11 ms
GPU planet frame on the test machine. These are observed samples, not a device
independent performance guarantee. Inspected atmosphere variants and cloud
captures at 0/45 seconds: weather changes while land remains fixed.
Final water/seed revision passed the release build and full native explorer
review. Screen entry: 29 ms; first GPU planet frame visible: 131 ms; first
measured GPU frame: 17 ms. Captures: `/tmp/galaxy-metal-planets-final`.
Local app bundle updated. One-time shader compilation is
separate from frame time and stays off the UI thread.

No Blender, generated bitmap assets, extra engine or network dependency is
needed. Quiet retro sound cues remain locally synthesized. Changes remain local;
this feature has not been committed or pushed.

## Planet workshop

Press E in the landing picker for live material controls. Q/R now rotate.
Cloud drift/evolution sliders integrate their rates, avoiding jumps when adjusted.
Zero pauses each component; values up to 20 make motion easier to inspect.
Coverage, height, shadows, atmospheric density, water ripples, reflection strength
and roughness are tunable. Planet-type selection previews materials only; Land
restores the real planet type. Settings are shared across planet types.
Save persists locally in UserDefaults; Copy/Paste JSON exchanges validated,
clamped settings; Reset previews defaults (Save commits the reset).
Water highlights use a broader roughness-controlled lobe and derivative-based
filtering. Noise interpolation has continuous second derivatives.

Workshop release build and full native review passed. Verified panel layout and
JSON round-trip; existing landing/control/exposure checks passed. Screenshots:
`/tmp/galaxy-planet-workshop`. Local app updated.

Cloud evolution revision: use continuous moving/warped noise coordinates. Both
gas types now animate their main bands as well as the outer clouds. User-supplied
air density 2.3326585, coverage 1.2022648, evolution 0.90074086, shadow 0.4294935
and drift 4.15492 are the new defaults. Existing saved workshop settings remain
respected; Reset previews these new defaults. Release build and full native review passed. Cloud and both gas-planet
captures at 0/45 seconds are in `/tmp/galaxy-vector-weather`. Local app updated.

## Independent gas controls

Hydrogen-helium and methane ice giants render their animated gas bands without
the additional cloud shell or cloud shadows. E automatically shows gas rotation,
vector evolution, vector distortion, pattern scale, band frequency, differential
wind and atmosphere controls for these types. Other types retain cloud/water
controls. Gas rate clocks are independent of cloud clocks and integrate changes
without position jumps. Rotation supports reversal. Save/Copy/Paste includes
both control groups. Missing fields in older JSON/configs receive defaults.
Release build and full native review passed, including legacy JSON loading,
configuration round-trip, gas workshop layout and both animated gas types.
Captures: `/tmp/galaxy-gas-workshop`. Local app updated.

## Live observatory navigation — current patch

Checkpoint: `fc53f94` preserves the separate landing screen. The new flow embeds
the Metal planet and drone pad beside the exposure dial, moving the real sky.
The surface frame is transported with the ship; terrain phases respond to the
location so the horizon changes too. The navigator hides after six idle seconds
or when taking a photograph, and the location button reopens it in place.
Day/night now animates only the sun: this is a photography convenience, not a
simulation of planetary rotation. Camera bearing and the galaxy stay fixed.
The supplied material configuration is the new default; saved workshop values
remain available. Release build and full native explorer review passed, including
first-turn response, live location changes, stable camera through day/night,
idle hiding, shutter hiding, reopen stability, both window sizes, JSON settings,
and existing exposure/daylight checks. Screenshots: `/tmp/live-planet-verified`.
Planet entry took 0.21 seconds and the first GPU planet frame 25 ms in the final
review run. Local app updated. Checkpoint remains local; this patch is uncommitted.

Terrain is a lightweight procedural skyline, not sampled geography from the globe.
Its world-anchored directions and smooth position phases make it respond to both
travel and turns. Future terrain work can replace this with globe-derived relief.
The separate full-screen renderer remains in LandingGameView for now, but the
observatory uses its embedded mode exclusively.

## Keyboard and daylight follow-up

Idle navigation now hides only the globe and dims its pad. Keyboard/pad input
restores it; using the E workshop refreshes activity. Explicit close and shutter
still remove the navigator. This prevents the six-second idle cleanup from
stranding keyboard users after workshop interaction.
Daylight always selects Auto, capped at 0.25 s, with faster stops for brighter
host sunlight. An incident-light estimate replaces view-dependent metering in
daylight, so looking down or away does not change exposure. Night retains the
manual dial. Release build and full native explorer review passed, including
stable daylight exposure after turning away and readable daylight photographs.
Local app updated; screenshots in `/tmp/planet-input-exposure-review`.

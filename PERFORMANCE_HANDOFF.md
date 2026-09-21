# Million-star performance upgrade — implementation checkpoint, 2026-09-16

## Intent and scope

The user authorizes an ambitious performance upgrade for an M1 MacBook Air:
make 1M stars comfortable and work toward 20M visible stars. Distant stars do
not all need individual sprites. Rewind may be removed. Preserve the actual
galaxy structures, collision behavior, nearby flight detail, and relativistic
optics; do not substitute invented background galaxies. Keep the kids UI simple.

This document is the current continuation entry point for further development.
See HANDOFF.md for ship assets, Blender TCP MCP on localhost:9876, and prior UI
work. Blender is not needed for this performance task.

## Plan and current status

1. IMPLEMENTED: removed full-particle rewind snapshots and scrub UI;
   retained pause/restart. Generated particles stream directly into Metal buffers.
2. IMPLEMENTED: fused restricted drift/kick/drift into one GPU pass; preserved
   split reference implementation for numerical A/B diagnostics. Self-gravity
   must retain separate global passes.
3. IMPLEMENTED: adaptive rendering derived from real particles using
   stable weighted sampling of distant stars, full retention within 10 kpc,
   and conservative aberration-aware visibility. Benchmarked against full draw.
4. VALIDATED: numerical/rendering regression diagnostics and 1M/5M/20M
   benchmarks. Close/warp image checks and native UI review passed.
   Release app bundle has been rebuilt and binary/resources verified.
5. FUTURE: spatial flux aggregation, physics/render interpolation,
   particle-mesh self-gravity. Do not claim these are implemented.

## Baseline measured before edits

Release build on this machine, Antennae restricted solver, 2026-09-16:
- 1M: 5.597 ms/step; 2M: 11.308 ms/step.
- 1M overview render only, 1440x900: 5.33 ms.
- These are separate short benchmarks, not sustained end-to-end frame rates.
- Normal GUI requests 120 physics steps/s. Flight evolves much more slowly
  in coordinate time. Physics dt remains 0.5 Myr.
- GPUParticle = 48 bytes; aux = 4 bytes/star. 20M live = 1.04 GB decimal.
- Old rewind minimum-six rule adds 5.76 GB at 20M, despite its 1GB comment.
- CPU seeds and concatenation create additional large temporary arrays.

## Validation / commands

`swift build -c release` builds Swift and copies shaders. Metal compiles at
runtime, so a successful build alone does not validate GPU changes.

`./.build/release/GalaxySim --bench --budget 1000000`

`./.build/release/GalaxySim --renderbench --budget 1000000 --size 1440x900 --shots 0`

GPU execution needs unsandboxed Metal access in this agent environment; the
executable prefix is already approved. Run GPU benchmarks sequentially, not
concurrently. Keep generated evidence under Review/. Do not blindly run full
collision trajectories at 20M until small runs and memory checks pass.

## Ownership during current turn

Root: Simulation.swift, Physics.metal, UI rewind removal, CLI diagnostics,
integration, final measurements and packaging.
adaptive_rendering agent: Renderer.swift / Render.metal.
stream_generation agent: GalaxyModels.swift streaming API.

## Measured results after implementation

Apple M1, 16GB RAM, 1440x900, initial Antennae view. Short sequential offscreen
measurements, not sustained GUI FPS. Combined means TWO fixed physics steps
plus render in one command buffer. Production GUI now limits catch-up using
measured physics GPU duration and an 8ms work allowance (minimum one step).
It slows galaxy time under load; it does not enlarge dt or interpolate physics.

| Simulated stars | Full render median | Adaptive render median | Combined median / p95 |
| --- | --- | --- | --- |
| 1M | 5.05 ms | 4.96 ms (original path) | 9.56 / 10.04 ms |
| 5M | 23.40 ms | 11.07 ms (~1,000,776 selected) | 31.34 / 33.63 ms |
| 20M | 114.69 ms | 23.80 ms (~1,000,315 selected) | 95.06 / 103.61 ms |

20M allocation and stepping succeeded. Live particle + auxiliary buffers:
991 MiB. Adaptive scratch: another 153 MiB (8 bytes/star); renderer resources,
textures and reload/insertion peaks are additional. This is NOT a claim of
20M at 60 fps or an 8GB-machine measurement. Runtime reported max buffer 9093 MiB.
20M setup 8.34s included generating the initial scene twice; final headless path
now skips that redundant second generation when using scene 0.

Fused vs original split solver: EXACT field agreement at 1 and 128 steps for
4097 particles, including position/velocity/starburst, finite state and unchanged
mass/appearance. Streaming generator separately matched pre-edit source across
11 types, boundary counts and seeds: 135,795 particle field values/checksum.

`--perftest` (PerformanceDiagnostics.swift) runs these numerical checks,
near/warp image A/B tests, full/adaptive render timings and combined timings.
`--look fullstars=1`, `starbudget=N`, `splitphysics=1` allow manual A/B.

## Honest rendering limitations

This is stable statistical sampling, NOT spatial aggregation. Particle IDs are
hashed deterministically. Within 10 kpc all stars survive, transition to sampling
by 30 kpc. Expected linear flux is analytically corrected including threshold
fade. Individual pixels/outliers and tonemapped output differ: distant fields
are grainier. Selection scans ALL positions each frame; scratch can hold all N
so flying inside a galaxy cannot overflow. Culling occurs AFTER aberration.
The sample budget is expected distant count BEFORE culling, not a strict draw
cap. Close-up dense regions can still be expensive. Physics still evolves all N.

Default adaptive sample budget 1M; <=1M uses original renderer. UI selectable
restricted counts now include 5M/10M/20M. Default user quality not changed.

## Working tree caution

During this task Assets/Blender/LumenCityShip.blend and .blend1 changed externally.
No performance agent edited them. Preserve those changes; do not stage/revert
as part of the performance work without understanding their source.


## Additional validation

- Nearby full-vs-selected images at beta 0, 0.99 and 0.9999: maximum channel
  error 1/255. Selection counts 399, 3902, 4091 out of 4097 respectively.
  Test forces the adaptive path with budget=1 but all test stars within 8 kpc,
  so it checks exact near retention and stars bent into view from behind.
- Native `--uitest` passed flight pause/resume, orbit/steering, throttle, focus,
  UI mode transitions and captures at 1440x900 and 1000x650.
- Evolved 1.5M collision at t=450 Myr rendered successfully; visual inspection
  shows tails, encounter bridge and bright starburst structure preserved.
- A later 5M test measured 13.76ms adaptive render and 35.63ms combined (p95
  40.59ms), versus the earlier 11.07/31.34ms. Timings vary with system load and
  heat. Do not cherry-pick the fastest short run as a sustained FPS guarantee.
- Evidence: Review/Performance/{1M,5M,20M,Collision,UI}/.

## Concrete next steps for continuation

1. Profile sustained GUI orbit, collision and close/warp views at Retina
   resolution. The current benchmark is short and does not include display
   synchronization, ship drawing, or long thermal throttling.
2. Replace far-field sampling with a spatial hierarchy and brightness/colour
   aggregates. Keep deterministic transitions, tidal-tail detail and
   aberration-aware bounds. This should reduce grain AND avoid the remaining
   O(N) position scan each rendered frame. Weighted sampling is a baseline.
3. Decouple physics states from presentation with interpolation. Catch-up is
   bounded now, but an individual 20M physics step still stalls the GPU for
   tens of ms. Investigate chunked stepping or a smaller dynamic carrier set
   with a denser tracer/aggregate representation; validate encounter evolution.
4. Consider a multi-resolution particle-mesh gravity path for actual large-N
   self-gravity. Existing restricted mode still uses analytic galaxy potentials;
   do not describe its 20M particles as mutually self-gravitating.
5. Profile hot/cold data separation (position/velocity versus appearance),
   async generation and Metal buffer residency. All coordinates remain float32.
   Loading still runs on the main thread. Live insertion temporarily retains
   both old and new buffers; it is not a constant-memory operation.

No assembly, timestep enlargement, invented galaxies, particle-mesh solver or
exact spatial aggregation was added. Current performance changes are uncommitted.

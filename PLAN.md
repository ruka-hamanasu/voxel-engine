# Voxel Engine Plan

A voxel game engine with a CPU software renderer. Small untextured voxels
(~10 cm), yaw-only camera (no pitch/roll) enabling fast 2.5D column-based
rendering, emissive voxels, sky light, directional sun shadows, fog, and fake AO.

## Tech stack

- **Language:** Zig 0.16
- **Platform layer:** SDL2 (`libsdl2-dev` via apt), used only for window,
  input, and displaying the framebuffer.
- **UI:** Nuklear
- **CLI:** zig-clap (0.12.0) for option parsing and `--help` text. Lighting
  and animation are on by default; `--no-light`/`--no-anim` disable them.
  `--world-w`/`--world-d` are optional XZ test bounds (both or neither;
  neither = the unbounded streamed world); `--world-h` sets the height
  (h <= 65535; total volume must stay under 2^32 voxels for the flood's
  u32 cell keys).
- **Headless mode:** `--headless` flag renders frames to PPM files so the
  renderer is verifiable without a display.

## Scale and world dimensions

- Voxel size: ~10cm (the milestone-23 walking player is 6x16x6 voxels
  = 0.6x1.6x0.6 m, eye at 14)
- World height: Configurable
- Demo world extent: unbounded, chunk-streamed (milestone 28;
  status and plan tracked in STREAMING.md). Bounded test worlds via
  --world-w/--world-d (default for the regression gates: 384x128x384).
  Tested to 768x1024x768 (~50 MB
  resident columns across all LOD levels; the flood's scratch is
  sparse, milestone 17).
- Internal render resolution: Configurable

## Storage

The algorithm drives storage: the renderer's inner loop works per (x,z)
column, so **the column is the fundamental storage unit**. No Y-chunking.
Random access to individual voxels is never needed — the renderer, shadow
rays, and sky-light defaults all work on vertical intervals — so each column
is a pair of top-to-bottom sorted **RLE streams** (merged at render time per
SINGLE-PASS-LIGHTING.md). Each column owns separately allocated arrays so an
edit never touches other columns' memory:

| Data | Representation | Purpose |
|------|----------------|---------|
| Material runs | Array of `{count: u8, palette_id: u8}` runs (2 B), top-to-bottom | Geometry; interval-overlap scan answers "solid voxels in height interval [a,b]?" — used by renderer, shadow rays, and picking |
| Light runs | Lazy `?[]` of `{count: u8, color_id: u8, intensity: u8, dir: u8}` runs (4 B) + `light_base_y`, top-to-bottom | Null = no colored light (identity tint); sky light is analytic, not stored. Allocated/grown where the flood writes values, freed when empty. `dir` is the flood's arrival direction (`lighting.Dir`), used to weight face light by normal alignment (milestone 9b) |

Runs longer than 255 voxels are split into consecutive identical runs — a
full-height 512-voxel column is 2–3 runs either way, and `u8` counts keep
runs tiny for cache density. All fields are `u8`, so the structs have
alignment 1 and zero padding; keep them packed and order any future fields
largest-to-smallest to preserve that.

Columns are 64 B (one cache line) and 64-aligned: material run streams of
<= 8 runs live inline in the column (`inline_runs`), so the far-field
march — which touches mostly cold columns — never chases a runs pointer.
`light_lo` caches the light stream's coverage bottom (written by
`encodeColumns`), and `solid_mask` (h <= 64 worlds) answers solidity
queries as a bit test for AO neighbor sampling; taller worlds fall
back to run scans there. The 8x8 `macro_max` grid is u16 (milestone
16), so the skip works at any height.

Columns are the *logical* unit; they may be grouped (e.g. 8x8) purely as an
allocation/container detail for cache locality if profiling warrants it. The same groups can later host a per-macro-cell `[min_solid_y, max_solid_y]`
summary enabling **hierarchical DDA**: the XZ march skips a macro-cell in one
step when the ray's height interval at that distance misses the summary
interval (a plain "cell empty" flag is not sufficient — a cell containing a
low floor is skippable only when the free spans are entirely above it).
Profiling-gated; the bounded world and fog cutoff already cap march length.

Palette: `palette_id -> RGB + emissive flag/intensity`. Untextured flat colors.

## Renderer (`column DDA`, the 2.5D core)

- Camera: position + yaw only, no pitch/roll. Framebuffer `u32`, uploaded to
  an SDL2 texture each frame. The framebuffer is **column-major** (rotated
  90°): vertical span fills become sequential `*dest++` sweeps (SIMD/
  memset-friendly), and rotation happens once per frame at presentation —
  either a single transposition pass over the small buffer or
  `SDL_RenderCopyEx` with 90°.
- Per screen column: a single **2D Amanatides–Woo DDA in the XZ plane**.
  Because pitch is fixed, every pixel row is a ray with a fixed vertical
  slope, and every hit projects to one contiguous vertical screen span.
- Unresolved pixels are tracked per screen column as a small **list of free
  vertical spans** (starts as `[0, height)`; 2–4 entries in practice). A
  single contiguous band is *not* sufficient: an arch wall resolving the top
  and bottom rows leaves the middle open, and a farther bridge behind it
  then splits the remainder. Each projected span clips against the free-span
  list; the ray stops the moment the list is empty (no overdraw, precise
  early-out).
- Per DDA cell: the free spans cross the cell over horizontal distance
  `[d0,d1]`, mapping to a world-height interval. Test that interval against
  the cell's material runs (interval-overlap scan; runs per column are few):
  - Ray heights inside a solid voxel at entry distance -> **side-face hit**,
    shade, subtract those rows from the free-span list.
  - Ray crosses a voxel's top/bottom plane *within* the cell -> **top/bottom
    face hit** at sub-cell distance.
  - Remaining free spans continue to the next cell; early-out when the list
    is empty or the fog cutoff is reached.
- Shading per hit:
  `palette_color x sky x face_factor x AO + glow(light run) -> fog`.
  The material stream and light stream are merged in a **single-pass
  zipper** (see SINGLE-PASS-LIGHTING.md): both are sorted top-to-bottom, so
  segment generation, shading, and blitting fuse into one loop whose inner
  blit is a branch-free fill per uniform segment. Per-segment shading is
  **table-driven, not arithmetic**: a comptime-built shade LUT
  (`[mat][face][ao][sky]`, ~1.5 KB) and distance-bucketed 2D fog LUTs
  collapse the formula into lookups; colored glow composes arithmetically
  on top (a quantized ~32 KB light LUT stays deferred, profiling-gated).
  - `face_factor`: top > X-side > Z-side for fake directional contrast.
  - **Fake AO:** Minecraft-style per-vertex AO from 3 neighbors
    (side1, side2, corner). Faces project to vertical screen spans, so AO is
    a cheap vertical 2-stop gradient per span.
  - **Fog:** exponential distance fog applied last, via the 2D fog LUT;
    doubles as darkness falloff at range. The LUT distance is the true
    radial 3D distance per segment stop — `SegmentSink.emit` rescales
    the XZ view-plane march parameter by `sqrt(dxz2 + s(row)^2)`
    (`FogRay`, LOD-invariant since t is march-scale invariant), so fog
    is stable under pure rotation. Lookups interpolate between the
    bucket-center entries (no quantization bands). Two variants ride
    the same LUT:
    - **Emissive fog curve:** emissive voxels fade slower toward a
      saturated version of their own color (volumetric neon haze),
      which then converges to the fog color on the full-density
      curve so distant emissives don't stay bright through fog.
    - **Low-pass palette fog:** distant colors pre-collapse toward a
      shared macro-color, killing sub-pixel shimmer at 480x270 for free.
  - **Fog glow (rejected, milestone 13):** a per-column fog-glow color
    from a precomputed 2D XZ blurred-light map, distance-weighted into
    the fog destination, was planned and cut. A 2D column blur only
    tints distant haze — it cannot read as glow around a source (e.g.
    a neon sign) without tracking each air cell volumetrically, which
    is a different feature at a much higher cost. The fake-bloom
    palette convention plus the emissive fog curve cover the look at
    zero code cost.

## Lighting

One **colored light channel** per column (per the Gemini discussion): an RLE
stream of `{color_id, intensity}` values, propagated by **BFS flood-fill**
with attenuation per step, face-adjacency only (no corner leaks). Intensity
is `u8`; attenuation step ~4–8 gives a 3–6 m radius at 10 cm scale
(Minecraft's 15 steps = 1.5 m is too short at this scale). `color_id`
indexes a small light-color palette (neon pink, amber, sky blue, ...).

**Emissive seeds:** emissive voxels (rendered full-bright) seed the flood
with their palette color at full intensity.

**Arrival direction (milestone 9b):** each lit cell also stores the
direction the brightest flood wave flowed in from (`lighting.Dir`;
runs split when it changes). Render-time face light is the adjacent
air cell's sample scaled by the `dir_weight` LUT: flow heading into
the face = full, perpendicular (grazing, e.g. light bending around a
45-degree stair-step corner) = half, opposed = none. This is the fix
for faces showing light from a source they face away from; the
alternative of storing per-face light on the solid voxels was
considered and rejected (breaks column-local flood writes and the
sky-default derivation; fog glow needs the air field anyway). Deferred
lever if corner-bend leaks still read too bright: a bend penalty —
extra attenuation when the propagation direction changes between
predecessor and cell.

**Emissive animation:** palette indirection makes whole-scene animation
free — blink/cycle emissive materials by rewriting palette entries once per
frame, or give materials a time bitmask (`anim_mask`, phase) evaluated at
run level. Rewriting an emissive material's rgb animates both the surface
and its cast light for free (the glow tint is looked up from the palette
at render time); toggling the emissive flag changes the flood's seed set
and requires the incremental relight below. Fake bloom is a content
convention: surround emissive cores with rings of semi-emissive palette
materials.

**Sky light (milestone 11, revised from the original sky-BFS design):**
the sky field is ANALYTIC per column — an air cell at y is sky-lit iff
`y > top_solid_y` of its column (cached per column, maintained by
`setRange`/`setColumnRuns`). Sky-lit = full shading, below = `sky_ambient`
floor (0.30, tuned in m13). Faces sample the sky bit in the air cell they are
exposed to (side faces: the neighbor column; top/bottom: one voxel
out), so Model A shadows (dark caves/overhangs, shadowed recesses)
fall out with zero flood work, and edits update sky for free. The
originally planned sky BFS storing side-leak deviations as explicit
runs was deferred: a single `{color_id, intensity}` channel cannot hold
both the sky level and a colored light at one cell, and the max-merge
would hide all colored pooling on sky-lit surfaces (sky 255 white
always wins). If cave mouths read too binary, side-leak can still be
added later as a second sky-only flood.

**Colored light composes ADDITIVELY** (milestone 11): `applyGlow` adds
`light_rgb x intensity/255 x glow_gain` on top of the shaded base
(saturating). The milestone-9 multiplicative lerp-to-white was
replaced because any channel whose light color was below white was
scaled BELOW the unlit base — weak colored light read as darkening.
The additive form never dims and reads in both regimes: the added
term dominates over the dark cave ambient (neon pooling), and is a
bounded tint over sky-lit surfaces.

**Incremental edits** (`lighting.relight`, consuming the `World.dirty`
extents expanded by the maximum light reach; the full flood never
re-runs):
- Add source / remove blocker: additive BFS, overwriting only where brighter.
- Remove source / add blocker: *clear-then-reflood* — BFS clearing dependent
  cells (`light == old - atten`), collecting boundary cells lit from
  elsewhere, then re-flooding from them.

Render-time face light comes from the light run overlapping the shaded
segment, merged with the material stream in the single-pass zipper.

## Shadows

**Model A — occlusion shadows (adopted):** caves, interiors, and the
unlit sides of geometry fall out of flood-fill / the analytic sky
light for free. Soft gradient falloff, zero render cost.

**Model B — directional sun shadows (skipped, milestone 12):** a
per-hit shadow ray march toward the sun, reusing the column-DDA
machinery (fixed azimuth + elevation => 2D XZ march, height interval
tested against each crossed column's material runs; arches/overhangs
correct, shadowed regions fall back to ambient) plus an animated sun.
Cut because Model A reads well enough; the design is recorded here in
case it is ever revisited.

## Interaction

Three movement states (`src/player.zig`): **walk** (gravity, Space
jump, auto-step up to 4 voxels, ground snap on descents), **fly**
(Space/Ctrl vertical, same AABB collision, no auto-step), and
**noclip** (no collision; the milestone-4 fly camera). `G` toggles
walk/fly, `N` toggles noclip; default is walk. The body is a 6x16x6
AABB (eye at 14) with axis-separated collision against
`World.solidAt`; edits refuse placement into the body. Yaw-only mouse
look; Tab toggles mouse capture. Left/right click removes/places a
cycling crystal: captured clicks pick through the center crosshair,
uncaptured clicks through the cursor pixel. Picking maps any screen
pixel to its fixed-vertical-slope ray (`pickPixel` in main.zig), so
ground below the horizon and ceilings are clickable. Edits trigger
`lighting.relight` on the next frame; `L` toggles lighting (the
identity regression path).

## File layout

```
build.zig            # link system SDL2 via pkg-config
src/main.zig         # SDL init, frame loop, --headless mode, edit picking
src/world.zig        # chunk map, columns, material + light RLE streams, edit API, palette
src/chunk.zig        # chunk load/unload lifecycle + coarse-LOD synthesis (dense pyramid)
src/stream.zig       # chunk streamer: per-level discs, budgeted gen, edits/unloads
src/lighting.zig     # colored flood-fill BFS + incremental relight
src/render.zig       # march core: render/renderColumn, DdaIterator, CellCtx/genSegments/processCell, segmentColor
src/render/spans.zig # free-span list + fillSpans/claim/claimGrad, the single pixel-write path
src/render/ao.zig    # fake-AO math: aoLevel, side/face stops, neighbor-cursor helpers
src/render/shade.zig # shading tables: shade LUT, fog LUTs, dir_weight, applyGlow/fogStop, sky
src/camera.zig       # yaw-only camera, noclip move math, Input
src/player.zig       # walk/fly/noclip player, AABB collision + auto-step
src/anim.zig         # emissive palette pulse (time-driven, identity at t=0)
src/gen.zig          # generator facade: Options/Result/Landmark, Generator enum dispatch
src/gen/noise.zig    # seeded value noise + fBm (shared by generators)
src/gen/builder.zig  # dense-column scratch + run encoding (shared by generators)
src/gen/terrain.zig  # demo world: heightmap terrain, caves, arches, crystals
```

## Milestones

Verification conventions for every milestone: `zig build test` green;
headless PPM regression sweep over 37 camera views + 4 cave views in
both flag modes (`--light 0 --fog 0` is the identity path and must stay
byte-identical); `--bench 1000` A/B against the previous build.
Mechanisms live in the code's doc comments and the sections above;
entries here record scope and outcome only.

1. COMPLETED - Zig + SDL2 + Nuklear skeleton, framebuffer to screen.
2. COMPLETED - Column DDA, flat shading, face-factor contrast.
3. COMPLETED - RLE column storage + edit API, demo world.
4. COMPLETED - Fly camera (noclip clamped to world bounds).
5. COMPLETED - Procedural demo world (terrain, caves, arches);
   `--gen`/`--seed`/`--cam` args.
6. COMPLETED - Fake AO: inner-loop optimizations (~2.6-3.4x faster;
   `--bench N`), then Minecraft 3-neighbor per-vertex AO with
   fractional stops (1.08 -> 1.65 ms at spawn). A projection strength
   reduction was tried and reverted (see `rowAt`). Deferred: baked
   side-exposure nibble mask if neighbor culling profiles hot.
7. COMPLETED - Pre-fog refactor: `RenderParams` threading, CellCtx /
   genSegments / `segmentColor` composition point, `DdaIterator`,
   runtime palette, light-run storage, `World.dirty` extents, single
   pixel-write path.
7.5. COMPLETED - render.zig split into render/{spans,ao,shade}.zig.
8. COMPLETED - Distance fog (exponential + low-pass palette variant)
   in `segmentColor` + the sky fill; `--fog`; `max_dist` 48 -> 96 after
   tuning; +9% frame cost.
9. COMPLETED - Colored flood-fill lighting + emissive voxels
   (`--light`); face light sampled from the air cell in front of the
   face so light never leaks through geometry.
9b. COMPLETED - Directional flood: per-cell arrival `Dir`, `dir_weight`
    face scaling. Deferred: bend penalty for corner-bend leaks.
10. COMPLETED - Incremental relight on edits (single edit ~9-13 ms,
    inside the vsync budget), interactive place/remove picking,
    emissive palette pulse (`--anim`/`--time`).
11. COMPLETED - Analytic sky light (Model A shadows) + additive glow
    (revised design; see the Lighting section). Default-mode baselines
    re-generated. Deferred: sky-BFS side-leak.
12. SKIPPED - Directional sun march (Model B; reuses 7c's `DdaIterator` +
    `firstSolidInColumn`) + animated sun.
13. COMPLETED - Fog glow CUT (a 2D XZ haze tint can't read as source
    glow without volumetric air-cell tracking). `--width`/`--height`
    render-resolution CLI (runtime framebuffer) + `--scale` window
    scale factor (window = render x scale, default 2) +
    `--fogcut`/`--atten` tuning flags. Tuning outcomes: fog_density 0.025 / cutoff 96 kept
    (variants near-identical in the bounded world), attenuation 8 kept
    (4 washed the whole cave, 16 lost the glow), glow_gain 0.5 kept
    (0.65 clipped hot), sky_ambient 0.25 -> 0.30 for cave readability.
    Identity path byte-identical; bench neutral.
14. COMPLETED - Single-threaded performance (960x540, ReleaseSafe).
    Profiled via gdb stack sampling (perf blocked by
    perf_event_paranoid=3). Key finding: the frame is per-CELL bound,
    not per-pixel — at the default fog cutoff 96 the 48->96 march
    range is ~80% of the worst view (10.7 ms vs 2.1 ms at cutoff 48),
    so per-voxel flat shading would buy little (fills ~5%); draw-
    distance headroom needs the far march to get cheaper (LOD or
    macro-cell skip), not faster fills. Exact-output optimizations
    applied (all verified byte-identical over the 37+37+4-view sweep,
    now at /tmp/opencode/views.sh adapted to the --no-light CLI):
    sky-cell early-out in processCell via top_solid_y; cached light
    coverage (Column.light_lo) replacing per-cell count sums; single
    prev-column fetch; per-column solid_mask bit tests for face AO;
    s_max hoisted per frame; vectorized (f32x4, bit-identical op
    order) shade LUT math with pre-unpacked V4 LUTs; one cursor reuse
    in genSegments (down-walk inherits the up-walk's final cursor);
    fillSpans sliced writes (ReleaseSafe bounds-check elision) +
    memcpy sky/constant fills; inline short material runs in 64 B
    aligned Columns. A lazy-diagonal-cursor variant REGRESSED and was
    reverted (most surviving cells render side faces; laziness was
    pure overhead). Bench (this machine, 960x540, ms/frame,
    baseline -> current): spawn 7.59 -> 6.41, worst view
    (96.5,40,96.5,yaw pi) 13.36 -> 10.69, aerial 7.20 -> 3.83,
    caves 0.30 -> 0.12. Deferred levers: ReleaseFast for the render
    module only.
    Follow-up (macro skip + LOD, adopted): 8x8-column macro_max grid
    (maintained by setRange/setColumnRuns) lets the march skip cells
    whose window is provably above everything solid in the group
    without loading a Column — exact, sweep-verified. Far-field LOD:
    a half-resolution World (2x2x2 conservative-solid blocks, material
    = highest solid fine voxel; src/lod.zig) marched past lod_dist
    (default 48, --lod flag; 0 disables). The coarse march reuses
    processCell via a 1/2-scaled coordinate frame (cam/2, dir/2, f*2)
    — MarchCfg/marchRange; with t_begin = 0 the march is bit-identical
    to the pre-LOD single march, and --lod 0 keeps the whole frame
    byte-identical (regression gate: /tmp/opencode/views_lod0.sh).
    The LOD world gets its own light flood and is rebuilt from dirty
    regions on edits (rebuildRegion + coarse relight). max_dist
    raised to 256 (default fog_cutoff stays 96); the historical
    t1-clamp-at-96 semantics are preserved by marchRange's t_clamp.
    Transpose is now 16x16 tiled (0.75 -> 0.37 ms at 960x540
    standalone). Visual A/B (PPM screenshots): LOD differences are
    confined to fogged distant silhouettes. Final benches (960x540,
    ms/frame, baseline -> LOD): spawn 7.59 -> 5.97, worst view
    13.36 -> 6.05, aerial 7.20 -> 2.27, caves 0.30 -> 0.13; worst
     view at fogcut 160: 6.24 — longer draw distance than before at
     half the original frame time.
     LOD boundary fix: the handoff no longer splits the coarse voxel
     straddling lod_dist — lodBoundary snaps it to the entry of the
     first coarse cell whose center is past lod_dist, so each coarse
     voxel renders whole, chosen by center distance. The coarse
     march's first cell emits its back faces uncullled (span claiming
     resolves occlusion against the fine render in front; culling
     against the coarse neighbor's union-solidity would punch holes)
     and shades them from the FINE world: the single fronting fine
     column the entry point backs onto (side_u selects between the
     face's two) supplies the sky bit, side-AO occluders, and light
     sample. Coarse-folded shading was tried first and left a dark
     seam: union-raised neighbor tops read open-sky faces as
     cave-dark, and unioning both fronting columns striped AO on
     voxels whose visible fragment fronted fine air. Regression
     gates: --lod 0 byte-identical over the 37+37+4 sweep; default
     mode differences confined to the fogged boundary silhouettes
     (dark seam band gone at fogcut 160); bench neutral.
15. COMPLETED - Distance-gated shading detail (`--detail`, default 32;
    0 disables). Cells past detail_dist drop per-voxel AO (neighbor/
    diagonal cursor setup, sideAoStops/faceAoStops) and the colored
    light zipper + glow, shading max-AO unlit so each material run
    collapses to one constant segment per sky half; the analytic sky
    bit and fog stay. The mode flips at most once per ray (t0 is
    monotonic), so the branch is hoisted out of the march: renderColumn
    snaps the split to a cell entry (detailBoundary) and marches a
    detailed and a simple range, each comptime-specialized through
    marchRange/processCell/genSegments (the coarse LOD march is simple
    too); mid-ray starts seed the upstream cell exactly like the LOD
    handoff. Isolated per-voxel savings (--lod 0, 960x540, ms/frame):
    worst 10.94 -> 6.31 (-42%), aerial 3.96 -> 2.45, spawn 6.83 ->
    6.12. The seam is invisible: <=0.3% of pixels differ vs full
    detail (max delta 24/255), all on heavily fogged terrain; cave/
    emissive views byte-identical; detail 24 bought nothing and
    diffed 3x more area. lod_dist default raised 48 -> 64 (the freed
    budget): final benches vs the milestone-14 baseline (spawn /
    worst / aerial / worst@fogcut160) 6.29/6.44/2.37/6.39 ->
    6.01/4.62/1.72/4.57. Regression gates: --detail 0 --lod 48 and
    --detail 0 --lod 0 byte-identical over the 37+37+4 sweep;
     default-mode baselines regenerated.
16. COMPLETED - Large-world plumbing. `--world-w`/`--world-h`/`--world-d`
     CLI (h <= 65535
     via the u16 y caches; volume < 2^32 for the flood's u32 cell keys,
     asserted in World.init). macro_max u8 -> u16 lifts the skip grid's
     h <= 256 gate; solid_mask keeps its h <= 64 gate (tall worlds take
     the run-scan AO path). Terrain scales with h (base 0.30h, amp
     0.16h), so 768x1024x768 mountains reach ~470. Regression: both
     view sweeps byte-identical to pre-change.
17. COMPLETED - Sparse lighting scratch. The flood's working memory was
     3 B/voxel dense over the box (1.8 GB at 768x1024x768); it is now
     an AutoHashMap(u32 -> packed intensity|color|dir) over lit cells
     only, so floodAll memory tracks the lit volume, not the world.
     encodeColumns derives per-column y-extents from the map instead of
     scanning full height. Default-world output byte-identical;
     768x1024x768 gen + LOD build + three floods ~51 s (Debug-speed
     hash ops; parallel gen/flood is a deferred lever).
18. COMPLETED - LOD cascade + long draw distance. renderColumn
     generalizes the single fine->coarse handoff to a chain: fine ->
     1/2-res (--lod) -> 1/4-res (--lod2, default 0 = off), each coarse
     march's boundary cell shading from the world one level finer (the
     existing 2x boundary math composes unchanged). lodBoundary takes
     the level scale. max_dist 256 -> 512. Fog kept at density 0.025
     (the curve normalizes to the cutoff, so the mid-range barely moves)
     and 64 buckets (no banding observed at 448). At 768x1024x768 with
     --fogcut 448 --lod 96 --lod2 192: vista 1.83 ms vs 3.65 ms
     single-LOD (480x270); LOD2 diffs vs single LOD confined to fogged
     ridgeline silhouettes (1.3% of pixels). Both regression sweeps
     byte-identical with --lod2 off; default-world bench neutral.
     Deferred levers: f64 DDA t_max past ~1000 steps; per-macro min_y
     for long shallow rays; fog_buckets 128 if banding appears.
19. COMPLETED - Fog fixes (the three TODO known issues). True radial
     fog distance: SegmentSink.emit rescales the XZ view-plane t per
     stop by sqrt(dxz2 + s(row)^2) (FogRay threaded through MarchCfg;
     valid for the coarse marches unchanged since t is march-scale
     invariant) — fog bands no longer shift under pure rotation. Fog
     LUT lookups interpolate between adjacent bucket-center entries
     (fogStopV -> fogStopsV, supersedes the fog_buckets 128 lever),
     killing the banding while moving. Emissive fog destination now
     lerps the half-density haze toward the fog color on the
     full-density curve, so emissives converge at the cutoff instead
     of staying bright through fog. Regression: identity path
     byte-identical over both 37+37+4 sweeps; default-mode baselines
     regenerated (views_m19[/tmp/opencode]). Bench A/B (this machine,
     960x540, ms/frame, before -> after): spawn 3.25 -> 3.35, worst
     view 2.64 -> 2.96, aerial 0.83 -> 0.90, worst@fogcut160
     2.70 -> 3.10 — the cost is the per-stop LUT interpolation,
     concentrated in march-bound synthetic views. Deferred lever if
     it needs reclaiming: per-column planar-only scale (drops the
     s(row) term, up to ~8% distance error on high rows of distant
     tall geometry).
20. LOD value benchmark (see TODO.md DONE); not a code change.
21. COMPLETED - Cache-efficiency investigation (both TODO items).
     perf hardware counters (perf_event_paranoid lowered to 1) on
     --bench loops across spawn/worst/aerial/cave at the default world
     plus 768x1024x768 vista @ fogcut 448 (perf --delay skips the
     ~51 s gen+flood): L1d miss rate <=0.3%, LLC traffic ~1-3k
     loads/frame at both scales — the marched working set is
     cache-resident (the LOD cascade keeps large-world marches inside
     the small coarse worlds). IPC 3.3-4.35: the march is
     ALU/branch-bound; branch misses (~112-147k/frame) cost more than
     all cache traffic combined. Axis asymmetry confirmed (strided
     X-march at yaw 0: 5.5x the L1 misses of the contiguous Z-march)
     but <=5% of frame cycles even if fully serialized. A
     software-prefetch probe (column two cells ahead) regressed 3-5%
     — miss latency is not the bottleneck, so the deferred 8x8-tiled
     column-storage lever is ruled out at these scales. Neighbor
     access per detail cell (the TODO question): pcol is L1-hot from
     the previous march iteration; X-side AO diagonals sit +/-64 B
     from pcol in the columns[x*d+z] layout, Z-side diagonals are
     row-pitch strided; light streams are per-column heap allocations
     (pointer chase) but too cold to measure. Gbuffer analysis:
     shading is already per-segment, so a per-pixel gbuffer is a
     strict regression (more bytes/px, a second full-res pass,
     per-pixel instead of per-segment shading; AO/light/sky only
     exist during the march). Full span-record fusion needs a
     row-sorted 16-cursor merge duplicating GradSrc's fixed-point
     math to save an L1-local write+read. The viable remnant —
     16-column strip rendering into a 34 KB L1 scratch with the
     existing fillSpans + a strip-local transpose (eliminates the
     2 MB fb L2 round-trip; est. 4-7% at 960x540, 1-2% at default
     480x270) — was evaluated and deferred: not worth the complexity
     while the frame is compute-bound.

22. COMPLETED - World rescale for a 16-voxel player (walking prep).
     Default world 192x64x192 -> 384x128x384 so caves with 16+
     headroom fit under the 0.30h terrain base. Caves: noise /13,/9 ->
     /24,/36 plus an 8-voxel solid skin under the surface (per-column
     skin, so sloped terrain still gets skylit slot-canyon breaches —
     kept, they read as cave entrances); tunnels ~10 wide x 14-28
     headroom (3056 columns with 20+ in the default world). Crystals
     2 -> 4 tall. Arches ~3x (27w x 33h x 6 thick, 17x18 opening),
     density /8192 -> /16384, lenient flatness span (12), lintel
     world-top clip guard. Spawn eye ground+15, pick_dist 16 -> 32.
     Consequence: the default world now exceeds the solid_mask h <= 64
     gate, so AO neighbor sampling takes the run-scan path. Bench
     (960x540, ms/frame): spawn 6.49, mid-terrain worst 7.17, aerial
     2.33, cave 2.99 — ~2x the m19 numbers (taller columns, run-scan
     AO, bigger caverns); 480x270 spawn 3.16. View sweep re-tuned
     (grid 48/192/336 x y 16/44/80, aerial y 75, cave cams at verified
     interiors); views_m22[/]_lod0 baselines regenerated, rerun
     byte-identical. Deferred lever: widen the solid_mask gate (u128
     or 2 x u64) to restore bit-test AO at h <= 128.
23. COMPLETED - Walking (src/player.zig). Three movement states: walk
     (gravity 98 vox/s^2, Space jump apex ~12 vox, auto-step 4, ground
     snap on descents), fly (collides, no auto-step), noclip
     (Camera.update unchanged). G toggles walk/fly, N noclip; default
     walk. Axis-separated AABB collision scans the body's overlapped
     voxels via solidAt (a few hundred bit tests/frame, unmeasurable
     vs the render); an embedded body escapes forward rather than
     clamping backward. Fly/noclip speed 4 -> 30 vox/s for the 384^2
     world. The place-guard tests the full body box (overlapsVoxel)
     instead of the camera column. Headless rendering untouched: both
     m22 sweeps byte-identical. Tests: wall stop, 4-vs-5 auto-step,
     jump apex, ceiling clamp, fly collision, noclip passthrough,
     unstick, place-guard.
24. COMPLETED - Long default draw distance (the fog half of the TODO
     "player seems gigantic" item; 10 cm voxels made the old 96 cutoff
     ~6 body heights of visibility). RenderParams defaults -> fog_cutoff
     96 -> 448, lod_dist 64 -> 96, lod2_dist 0 -> 192 (the milestone-18
     tested vista config); fog_density 0.025 kept (the curve normalizes
     to the cutoff, so the near/mid look barely moves: 91% fogged at the
     old cutoff distance instead of 100%). In the 384-wide default world
     terrain past ~190 is already >99% fogged, so the world edge stays
     hidden. The emissive fog test pins fog_cutoff 96 (its mid-bucket
     expectations assume it). Regression: views.sh l0f0 mode and all of
     views_lod0.sh pin the old values (fogcut 96 / lod 64 / lod2 0), both
     byte-identical to views_m22[/]_lod0; def baselines regenerated
     (views_m24[/tmp/opencode]). Bench (960x540, ms/frame, old defaults
     -> new on the same binary — the only shipped change is the default
     constants): spawn 6.41 -> 10.65, aerial 2.35 -> 7.38 (the aerial
     now sees the whole world), cave 1.72 -> 1.84; 480x270 spawn 3.16
     -> 5.43. Deferred (agreed order): N-level LOD cascade + max_dist
     raise for 100-200m+ draws, then terrain feature scale; chunked
     streaming only if still needed after those — streaming alone
     doesn't extend draw distance (the LOD cascade is the prerequisite).
26. COMPLETED - Chunked-streaming phase 0 (status and detail tracked
     in STREAMING.md): byte-identical refactors (World.columnAtMut,
     box-local flood scratch keys, optional XZ clamp bounds), then
     position-deterministic worldgen (pure heightAt/genColumn, hash-
     rolled crystals, per-128x128-region hashed arches stamped into a
     dense 64x64 Builder tile, ring-search spawn near origin). World
     layout changed: baselines regenerated as views_m26[/]_lod0, rerun
     byte-identical; tile-independence pinned by test; startup and
     frame costs neutral.
27. COMPLETED - Chunked storage (STREAMING.md phase 1; detail tracked
     there). World.columns -> HashMap(u64, *Chunk) of 64x64-column
     chunks (256 KB 64-aligned block + per-chunk 8x8 macro_max grid);
     w/d are ?usize (null = unbounded), bounded worlds eagerly resident.
     set/fillBox no-op on unloaded columns; lighting decode/seed/encode
     skip them too. src/chunk.zig: loadChunk (ensureChunk + the staged
     tile pipeline, i32 tile origins threaded through genTile/emit),
     unloadChunk (blank materials preserving light runs -> relight ->
     free). Perf: the per-cell hash lookup regressed the bench ~20%
     with Wyhash; multiplicative-mix hash + a last-chunk memo behind
     force-inlined accessors brought it back to parity (spawn 6.79 ->
     6.72 ms, aerial 3.87 -> 3.93, cave neutral; startup 0.52 -> 0.51).
     Regression: zig build test green (new chunk residency / load==gen
     / unload==reflood tests), both m26 view sweeps byte-identical.

28. COMPLETED - Chunked streaming (STREAMING.md phase 2; detail and
     the flood-confinement design change tracked there). The default
     world is now unbounded and streamed: src/stream.zig keeps per-level
     Chebyshev chunk discs around the camera (radii from lod_dists /
     fog_cutoff, one chunk of unload hysteresis), generates under a
     per-frame column budget (--load-budget, default 1200) with the
     dense fill sliced across frames, force-generates the player's AABB
     chunks before physics, and warms up synchronously around the
     camera in all modes (~1.3 s after the relight fast paths:
     multiplicative-hash CellMap, map-based stale scan, shell border
     enqueue, empty-scratch skip). Coarse tiers synthesize from
     generation through a dense pyramid (== iterated lod.build), with
     the approx sub-skin-cave skip by default (--exact-coarse opts
     out). --world-w/--world-d are now optional test bounds; the
     bounded eager path is unchanged. Regression: pinned bounded
     sweeps byte-identical to views_m26[/]_lod0 (scripts now pin
     --world-w 384 --world-d 384); new unbounded sweeps
     (views_stream[/]_lod0.sh) baselined as views_m28[/]_lod0, rerun
     byte-identical. Bench (960x540, bounded, m27 -> m28): spawn
     13.39 -> 13.29, aerial 9.56 -> 9.49, cave neutral; unbounded
     spawn 14.56 (the march sees terrain past the old 384 edge).
     MaxRSS unbounded 34 MB vs bounded 38 MB (fine tier ~7 MB).

25. COMPLETED - N-level LOD cascade. renderColumn's hardcoded
     fine->lod1->lod2 chain generalizes to a chain of up to max_lods (8)
     coarse levels, each at 1/2^i resolution: lod_dists[] replaces
     lod_dist/lod2_dist (defaults {96, 192} — the default chain is
     unchanged), lodChain lays out a ray's handoffs (first non-
     increasing distance or a missing world ends the chain), and the
     march loops over levels with per-range scale/fine/detail selection
     — the same math the 3-march chain unrolled, so default output is
     bit-identical (def views byte-identical to views_m24 with no flag
     pinning; l0f0/lod0 gates unchanged). main builds/floods/rebuilds
     the world chain in loops; --lod/--lod2 keep their meaning, new
     --lods N extends the chain by doubling the last handoff. max_dist
     512 -> 16384 (per-range DDA steps stay bounded at any depth, so
     f32 t suffices; f64 t_max remains the deferred lever). Bench
     (480x270, ms/frame): default world neutral (spawn 5.43 -> 5.43).
     768x1024x768 vista: fogcut 448 -> 4096 costs ~nothing at ground
     level (1.41 -> 1.39; rays exit the 768-wide world or hit terrain
     long before the cutoff). 2048x512x2048 at fogcut 2048, where
     geometry fills the far field: --lods 1 (single coarse level) 30.1,
     --lods 2 17.8, --lods 5 9.7 — the deep cascade pays 3.1x over
     single-LOD. lods-5 vs lods-1 diffs: 4% of pixels, all in fogged
     silhouettes. Note: at density 0.025 everything past ~400 is
     silhouette-only regardless of cutoff; a lower --fog carries color
     farther on big worlds (tuning lever, not changed). Deferred:
     terrain feature scale (hill height & flat areas); chunked
     streaming only if km-scale is still wanted after that.

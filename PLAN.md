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
  `--world-w`/`--world-h`/`--world-d` set the world size (h <= 65535;
  total volume must stay under 2^32 voxels for the flood's u32 cell
  keys).
- **Headless mode:** `--headless` flag renders frames to PPM files so the
  renderer is verifiable without a display.

## Scale and world dimensions

- Voxel size: Configurable, probably ~10cm
- World height: Configurable
- Demo world extent: bounded, fully resident (streaming deferred).
  Tested to 768x1024x768 (~50 MB resident columns across all LOD
  levels; the flood's scratch is sparse, milestone 17).
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

Fly camera (WASD + Space/Ctrl, Shift boost) with yaw-only mouse look;
Tab toggles mouse capture. Left/right click removes/places a cycling
crystal: captured clicks pick through the center crosshair, uncaptured
clicks through the cursor pixel. Picking maps any screen pixel to its
fixed-vertical-slope ray (`pickPixel` in main.zig), so ground below the
horizon and ceilings are clickable. Edits trigger `lighting.relight` on
the next frame; `L` toggles lighting (the identity regression path).

## File layout

```
build.zig            # link system SDL2 via pkg-config
src/main.zig         # SDL init, frame loop, --headless mode, edit picking
src/world.zig        # columns, material + light RLE streams, edit API, palette
src/lighting.zig     # colored flood-fill BFS + incremental relight
src/render.zig       # march core: render/renderColumn, DdaIterator, CellCtx/genSegments/processCell, segmentColor
src/render/spans.zig # free-span list + fillSpans/claim/claimGrad, the single pixel-write path
src/render/ao.zig    # fake-AO math: aoLevel, side/face stops, neighbor-cursor helpers
src/render/shade.zig # shading tables: shade LUT, fog LUTs, dir_weight, applyGlow/fogStop, sky
src/camera.zig       # yaw-only camera, WASD + mouse input
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

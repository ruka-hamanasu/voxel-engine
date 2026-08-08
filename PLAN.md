# Voxel Engine Plan

A voxel game engine with a CPU software renderer. Small untextured voxels
(~10 cm), yaw-only camera (no pitch/roll) enabling fast 2.5D column-based
rendering, emissive voxels, sky light, directional sun shadows, fog, and fake AO.

## Tech stack

- **Language:** Zig 0.16
- **Platform layer:** SDL2 (`libsdl2-dev` via apt), used only for window,
  input, and displaying the framebuffer.
- **UI:** Nuklear
- **Headless mode:** `--headless` flag renders frames to PPM files so the
  renderer is verifiable without a display.

## Scale and world dimensions

- Voxel size: Configurable, probably ~10cm
- World height: Configurable
- Demo world extent: bounded, fully resident (streaming deferred).
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
| Material runs | Array of `{count: u8, palette_id: u8}` runs (2 B), top-to-bottom | Geometry; interval-overlap scan answers "solid voxels in height interval [a,b]?" — used by renderer, shadow rays, and sky-light defaults |
| Light runs | Lazy `?[]` of `{count: u8, color_id: u8, intensity: u8, dir: u8}` runs (4 B) + `base_y`, top-to-bottom | Null = default derived from the material runs (full sky light above the topmost solid run, dark below); allocated/grown where values deviate, freed when empty. `dir` is the flood's arrival direction (lighting.Dir), used to weight face light by normal alignment (milestone 9b) |

Runs longer than 255 voxels are split into consecutive identical runs — a
full-height 512-voxel column is 2–3 runs either way, and `u8` counts keep
runs tiny for cache density. All fields are `u8`, so the structs have
alignment 1 and zero padding; keep them packed and order any future fields
largest-to-smallest to preserve that.

Columns are the *logical* unit; they may be grouped (e.g. 8x8) purely as an
allocation/container detail for cache locality if profiling warrants it. The
same groups can later host a per-macro-cell `[min_solid_y, max_solid_y]`
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
  `palette_color x light(matching light run) x face_factor x AO -> fog`.
  The material stream and light stream are merged in a **single-pass
  zipper** (see SINGLE-PASS-LIGHTING.md): both are sorted top-to-bottom, so
  segment generation, shading, and blitting fuse into one loop whose inner
  blit is a branch-free fill per uniform segment. Per-segment shading is
  **table-driven, not arithmetic**: a light LUT
  (`lut[palette_id][quantized_intensity]`, ~32 KB, L1-resident) and a
  distance-bucketed 2D fog LUT collapse the formula into lookups.
  - `face_factor`: top > X-side > Z-side for fake directional contrast.
  - **Fake AO:** Minecraft-style per-vertex AO from 3 neighbors
    (side1, side2, corner). Faces project to vertical screen spans, so AO is
    a cheap vertical 2-stop gradient per span.
  - **Fog:** exponential distance fog applied last, via the 2D fog LUT;
    doubles as darkness falloff at range. Two variants ride the same LUT:
    - **Emissive fog curve:** emissive voxels fade slower and toward a
      saturated version of their own color instead of the fog color,
      faking volumetric neon haze (separate LUT row; distance + material
      only, never view-dependent).
    - **Low-pass palette fog:** distant colors pre-collapse toward a
      shared macro-color, killing sub-pixel shimmer at 480x270 for free.
  - **Fog glow:** a per-column ambient fog-glow color from a precomputed
    2D XZ map (blurred light overlay, see SINGLE-PASS-LIGHTING.md) is
    looked up once per hit and distance-weighted into the fog destination,
    so distant geometry fades toward the local haze rather than a single
    global color.

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
run level. This animates the emissive *surface* only; blinking the light it
casts still requires the incremental clear-then-reflood below (usually
unnecessary — cast light can stay constant). Fake bloom is a content
convention: surround emissive cores with rings of semi-emissive palette
materials.

**Sky seeds:** the default light field is derived from the material runs —
full sky light above the topmost solid run, dark below. BFS stores
deviations (overhangs, caves, side-leak) as explicit runs, with a **free
downward fast-path** (no attenuation straight down, Minecraft-style).

**Incremental edits** (never re-run the full flood):
- Add source / remove blocker: additive BFS, overwriting only where brighter.
- Remove source / add blocker: *clear-then-reflood* — BFS clearing dependent
  cells (`light == old - atten`), collecting boundary cells lit from
  elsewhere, then re-flooding from them.

Render-time face light comes from the light run overlapping the shaded
segment, merged with the material stream in the single-pass zipper.

## Shadows

- **Model A — occlusion shadows:** fall out of flood-fill for free; caves,
  interiors, and the unlit sides of geometry are dark. Soft gradient falloff,
  zero render cost.
- **Model B — directional sun shadows:** per sun-facing hit, march a shadow
  ray toward the sun. Reuses the column-DDA machinery: fixed sun azimuth +
  elevation => 2D XZ march, and in each crossed column the ray spans a fixed
  height interval tested against the column's material runs
  (interval-overlap scan).
  First solid run overlapping the interval = shadowed; exiting world top =
  sunlit. Early-out; typical
  cost a few columns, worst case `H / tan(elevation)`.
  - **Arches/overhangs work** because the march tests real geometry, not a
    heightmap.
  - Shadowed regions fall back to the column's ambient light, not black.
- **Sun is animated:** the march makes changing sun angle nearly free; the
  sky flood-fill ambient stays fixed.

## File layout

```
build.zig            # link system SDL2 via pkg-config
src/main.zig         # SDL init, fixed-timestep loop, --headless mode
src/world.zig        # columns, material + light RLE streams, edit API, palette
src/lighting.zig     # colored flood-fill BFS, incremental updates, sky defaults
src/render.zig       # march core: render/renderColumn, DdaIterator, CellCtx/genSegments/processCell, segmentColor
src/render/spans.zig # free-span list + fillSpans/claim/claimGrad, the single pixel-write path
src/render/ao.zig    # fake-AO math: aoLevel, side/face stops, neighbor-cursor helpers
src/render/shade.zig # shading tables: shade LUT, fog LUTs, dir_weight, applyLight/fogStop, sky
src/camera.zig       # yaw-only camera, WASD + mouse input
src/gen.zig          # generator facade: Options/Result/Landmark, Generator enum dispatch
src/gen/noise.zig    # seeded value noise + fBm (shared by generators)
src/gen/builder.zig  # dense-column scratch + run encoding (shared by generators)
src/gen/terrain.zig  # demo world: heightmap terrain, caves, arches, crystals
```

## Milestones

1. COMPLETED - Zig + SDL2 + Nuklear skeleton, framebuffer to screen (verify: color gradient).
2. COMPLETED - Column DDA, flat shading, face-factor contrast (verify: headless PPM of a
   hand-built room).
3. COMPLETED - RLE column storage + edit API, port initial demo world, verify render matches milestone 2.
4. COMPLETED - Fly camera (mouse-captured yaw look, WASD + Space/Ctrl, Shift
   boost, noclip clamped to world bounds; headless render unchanged).
5. COMPLETED - Procedural demo world (terrain, caves, arches). Modular
   generator facade (`--gen`, `--seed` args; `--cam` headless camera override).
6. COMPLETED - Fake AO, split into two passes:
   a. COMPLETED - Inner-loop optimizations (verified: headless PPMs
      byte-identical to pre-change output across 37 camera views; ~2.6-3.4x
      faster via `--bench`): sky color LUT, comptime shade LUT (extended
      to [mat][face][ao] in 6b), run-coalesced claims, exact face culling
      via a lockstep RunCursor on the previous column; `--bench N` flag.
      A reciprocal strength reduction of the projection was tried and
      REVERTED — rationale lives in rowAt's comment.
   b. COMPLETED - Per-vertex fake AO: Minecraft 3-neighbor model,
      fractional stops lerped between shade-LUT entries. Mechanism
      documented in render.zig (aoLevel, sideAoStops, faceAoStops,
      shadeAt, claimGrad, spanOverlap) and world.zig (RunCursor.peek).
      Verify: headless PPMs show darkening localized to
      edges/crevices/corners, sky and open faces byte-identical; frame
      time 1.08 -> 1.65 ms at the spawn view.
      Deferred (profiling-gated): baked per-column side-exposure nibble
      mask (4 bits/voxel, recompute the 5 affected columns on edit) if
      neighbor-cursor culling still shows up hot.
7. COMPLETED - Pre-fog refactor pass — structural groundwork for milestones
   8-13: RenderParams threaded render -> renderColumn -> processCell;
   processCell split into CellCtx + genSegments/SegmentSink with
   segmentColor as the single composition point; DdaIterator +
   firstSolidInColumn; runtime palette + rebuildShadeLut; column
   light-run storage (CursorFor/LightCursor, topSolidY); World.dirty
   edit extents; fillSpans as the single pixel-write path; accumulated
   time in RenderParams. Details live in the respective types' doc
   comments. Verified: headless PPMs byte-identical across the 37 camera
   views after every sub-part; `--bench 1000` flat (1.55 -> 1.64 ms,
   within machine drift; A/B stash checks showed no regression from any
   part).
8. COMPLETED - Distance fog (exponential + low-pass palette variant; lives
   entirely in `segmentColor` + the sky fill; fog glow deferred to
   milestone 13 since it needs the light map). Mechanism documented in
   buildFogLuts, fogCurve, fogStop, and the sky fill. `--fog <density>`
   CLI override; 0 disables. Verified: `--fog 0` headless PPMs
   byte-identical to the milestone-7 base across the 37 camera views;
   default-fog views show distance-graded haze with a seamless horizon;
   `--fog 0 --bench 1000` 1.58 ms (drift-level vs the 1.63 ms pre-change
   baseline), default fog 1.77 ms (+9%, the actual fog work). Draw
   distance doubled after tuning feedback: `max_dist` 48 -> 96 with
   default density 0.025 (0.05 at cutoff 48 read as claustrophobic; 0.08
   was pea soup). At 96 the fog hides the cutoff completely while terrain
   reads to ~60 units; spawn view 2.20 ms, `--fog 0` 2.07 ms (the extra
   march draws real geometry). NOTE: the max_dist bump invalidates the
   m7-base byte-identical comparison — geometry in (48, 96] now renders
   where sky used to be; that's the intended change, and the `--fog 0`
   regression check now only covers the fog code path itself. Final
   tuning is milestone 13's pass.
9. COMPLETED - Colored flood-fill lighting + emissive voxels (full flood
   only; new `src/lighting.zig`). Crystals 9-11 flipped to `emissive =
   255`. Face light is sampled from the air cell in front of the face
   (solids store nothing) so light never leaks through geometry.
   Mechanism documented in lighting.zig (floodAll, lightColor,
   sampleLight) and render.zig (applyLight, segmentColor,
   CellCtx.lightAt/nLightAt, genSegments); the 32 KB light LUT stays
   deferred (profiling-gated). `--light <0|1>` CLI flag; 0 skips the flood so the
   renderer takes the identity path (regression-check escape hatch).
   Default world flood: 17535 lit columns, 99279 runs, ~400 ms in a
   Debug build (one-time, at load). Verified: `--light 0 --fog 0`
   headless PPMs byte-identical across the 37 camera views against a
   RE-BASELINED m8-final set (the stored m8/nofog baselines were
   pre-tuning max_dist=48 renders — HEAD draws terrain in (48, 96] where
   they had sky — so m9 re-baselined at HEAD before any changes); spawn
   view with light ON also byte-identical to base (no lit columns
   visible). Cave views at crystals show full-bright emissive cores with
   colored pooling on cave walls fading over ~31 voxels and
   brighter-wins two-color regions. Bench (ReleaseFast): spawn `--fog 0`
   2.05 -> 2.15-2.20 ms at `--light 0` (+5% code-shape cost in the AO
   loop, accepted; the comptime specialization in genSegments recovered
   the initial +20%), 2.46-2.55 ms light on (lit cave entrances visible
   from spawn); crystal cave view 0.54 -> 0.58 ms (+7%).
   KNOWN BUG (fixed in 9b): faces show their adjacent air cell's full
   light even when facing away from the source at a 45-degree angle.
9b. COMPLETED - Directional flood light. The flood records per cell the
   direction the brightest wave flowed in from (`lighting.Dir`;
   `LightRun` 3 -> 4 B; runs split on direction changes), and
   `segmentColor` scales each face's light intensity by the
   `dir_weight` LUT indexed [arrival dir][oriented face]: into the
   face = full, perpendicular = half, opposed = none (unreachable for
   solid-backed faces). Segments carry an oriented face (`OFace`, the
   four shade classes split by normal sign; `shadeAt` maps back via
   `faceClass`). Storing per-face light on solid voxels was considered
   and rejected (see the Lighting section). Verified: `zig build test`
   green (dir expectations added to the flood tests, a run-split test,
   and a directional-weight renderer test); `--light 0 --fog 0` headless
   PPMs byte-identical across the 37 camera views; spawn light-on
   byte-identical (no lit columns visible); crystal-cave views show
   grazing faces at half light with downstream faces and emissive cores
   unchanged. Flood runs 73462 -> 74233 (+1%, direction splits), flood
   time flat. Bench (ReleaseFast): spawn `--fog 0 --light 0` 2.25 ->
   2.23 ms, spawn light-on 2.56 -> 2.51 ms, crystal cave 0.89 -> 0.87
   ms (all noise-level). Deferred: the bend penalty (extra attenuation
   when propagation changes direction) for corner-bend leaks whose flow
   still arrives face-on after bending — evaluate from renders whether
   it is needed.
7.5. COMPLETED - render.zig split (1176 -> ~640 lines core) ahead of the
    milestone 10-13 growth: pure code motion into src/render/spans.zig
    (span list + pixel-write path), src/render/ao.zig (AO level math),
    and src/render/shade.zig (all color/LUT tables; imports render.zig
    for RenderParams — Zig tolerates the cycle). render.rebuildShadeLut
    re-exported so main.zig is untouched. Verified: `zig build test`
    green; headless PPMs byte-identical across the 37 camera views in
    both flag modes (`--light 0 --fog 0` and default light+fog, 78
    renders) plus a light-tint-visible crystal view; bench (ReleaseFast,
    spawn, light on) 2.58-2.65 ms base vs 2.59-2.60 ms new (drift-level,
    A/B against a git-archive HEAD build).
10. Incremental relight on edits (clear-then-reflood, consuming 7f's
    dirty extents) + emissive palette animation (7d's runtime palette +
    7h's accumulated time).
11. Sky light seeding/defaults + Model A shadows (uses 7e's light
    storage + `topSolidY`).
12. Directional sun march (Model B; reuses 7c's `DdaIterator` +
    `firstSolidInColumn`) + animated sun.
13. Fog glow from light map (single injection point from 7g) + tuning
    pass (resolution, fog cutoff, light radius).

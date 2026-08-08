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
| Light runs | Lazy `?[]` of `{count: u8, color_id: u8, intensity: u8}` runs (3 B) + `base_y`, top-to-bottom | Null = default derived from the material runs (full sky light above the topmost solid run, dark below); allocated/grown where values deviate, freed when empty |

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
src/render.zig       # column DDA rasterizer, single-pass stream merge, AO, fog, shadow march
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
      faster via `--bench`):
      - Sky color LUT: one `height`-entry `u32` table per frame, replacing
        per-sky-pixel float lerps.
      - Shade LUT: comptime `[mat][face] -> u32` table, collapsing shading
        arithmetic to one lookup (extended to `[mat][face][ao]` in 6b).
      - NOTE: per-cell reciprocal strength reduction of `proj()` was tried
        and REVERTED — the distributed form `c - y*k` rounds differently
        than `(y - cam_y) * f / t` and flips tie-break rows when the camera
        sits at an exact integer height. Projection keeps the original op
        sequence; the claim-count reduction below makes it cheap.
      - Run-coalesced claims: side spans claimed per run segment (zippered
        against the previous cell's runs), top/bottom claimed only at run
        boundaries where the adjacent voxel is air — interior planes are
        provably never visible (a ray reaching them would already have been
        claimed by the occluding voxel at a strictly nearer distance).
      - Exact face culling: a side face is skipped where the same-y voxel in
        the previous DDA cell is solid, via a lockstep `RunCursor` on the
        previous column (amortized O(1) per segment, no per-query run scans).
        6b's AO neighbor queries reuse the same occupancy walk.
      - `--bench N` flag: N headless renders, prints ms/frame.
   b. COMPLETED - Per-vertex fake AO: Minecraft 3-neighbor (side1, side2,
      corner), factors {0.45, 0.65, 0.82, 1.0}; 2-stop vertical gradient
      per span, stops sampled at the ray's hit u. Stops are fractional
      AO levels (lerpLevel/bilerpLevel); shadeAt lerps between adjacent
      shade-LUT entries — rounding stops to the 4 discrete levels bands
      adjacent screen columns. Fixed-point lerp fill with a
      constant-fill fast path when both stops are max. See doc
      comments in render.zig (aoLevel, sideAoStops, faceAoStops,
      shadeAt, claimGrad, spanOverlap) and world.zig (RunCursor.peek).
      Verify: headless PPMs show darkening localized to
      edges/crevices/corners, sky and open faces byte-identical; frame
      time 1.08 -> 1.65 ms at the spawn view. Key perf note:
      the band/free-span overlap pre-check must gate all AO neighbor
      queries (without it AO costs 3.8x; with it +40%).
      Deferred (profiling-gated): baked per-column side-exposure nibble
      mask (4 bits/voxel, recompute the 5 affected columns on edit) if
      neighbor-cursor culling still shows up hot.
7. Pre-fog refactor pass — structural groundwork for milestones 8-13. No
   behavior change (verify: headless PPMs byte-identical across the 37
   camera views; `--bench` shows no regression — investigate >~5%).
   Order: a-c reshape render.zig, d-f reshape world.zig data, g-h are
   small cleanups that ride along.
   a. `RenderParams` struct (fog density/cutoff, sun az/el, time,
      fog-glow light-map slot) threaded `render -> renderColumn ->
      processCell`; update the 3 call sites in main.zig (bench,
      headless, interactive).
   b. Split `processCell` (render.zig:367, 138 lines, 20 params — the
      god function every remaining milestone lands in) into: segment
      generation (geometry/visibility -> segment records
      `{mat, face, t, r0, r1, ao_stops}`), `segmentColor(seg, params)`
      (the single LUT/light/fog composition point for 8-13), and
      `claimGrad`.
   c. Extract the XZ DDA stepper from `renderColumn` (render.zig:237-280,
      pure ray math written inline) into a reusable
      `DdaIterator{init, next()}` plus a pure
      `firstSolidInColumn(world, ix, iz, y_lo, y_hi)` interval helper;
      `renderColumn` consumes both. Milestone 12's sun march reuses them
      verbatim (elevation => height interval affine in t).
   d. Palette becomes runtime-mutable: entries `{rgb: u32, emissive: u8}`
      (0 = not emissive; crystals 9-11 become emissive); `shade_lut`
      moves from comptime to runtime, rebuilt on palette change (per
      frame during animation); emissive materials bypass face/AO
      shading (unshaded LUT path). Required by 9-10.
   e. Column light stream storage (no behavior yet): lazy
      `?[]LightRun{count: u8, color_id: u8, intensity: u8}` + `base_y`
      per the Storage table above; alloc/free in `init`/`deinit`/
      `setColumnRuns`; `LightCursor` mirroring `RunCursor` (or a cursor
      generic over both run types); `topSolidY(col)` helper for 11's sky
      defaults. Extend the `expectCoverage`/`worldsEqual` test
      invariants to cover light runs.
   f. Edit API reports dirty extents: `set`/`fillBox` return (or record
      in `World`) the touched columns + y-ranges, consumed by 10's
      incremental relight. Also make OOB handling consistent — `set`
      silently no-ops while `fillBox` clamps; clamp both.
   g. Unify the three pixel-write sites (`claim`, `claimGrad`, sky fill)
      behind one span-fill helper so 13's fog glow has a single
      injection point.
   h. Accumulated time (`time_s: f64 += dt`) in the main loop, carried
      in `RenderParams` — drives 10's palette animation and 12's
      animated sun.
8. Distance fog (exponential + low-pass palette variant; after 7b/7g it
   lives entirely in `segmentColor` + the sky fill; fog glow deferred to
   milestone 13 since it needs the light map).
9. Colored flood-fill lighting + emissive voxels (full flood only). New
   `src/lighting.zig`; renderer merges material+light streams in the
   single-pass zipper inside segment shading.
10. Incremental relight on edits (clear-then-reflood, consuming 7f's
    dirty extents) + emissive palette animation (7d's runtime palette +
    7h's accumulated time).
11. Sky light seeding/defaults + Model A shadows (uses 7e's light
    storage + `topSolidY`).
12. Directional sun march (Model B; reuses 7c's `DdaIterator` +
    `firstSolidInColumn`) + animated sun.
13. Fog glow from light map (single injection point from 7g) + tuning
    pass (resolution, fog cutoff, light radius).

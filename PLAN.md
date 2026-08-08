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
| Material runs | Array of `{count: u8, palette_id: u8}` runs (2 B), top-to-bottom | Geometry; interval-overlap scan answers "solid voxels in height interval [a,b]?" — used by renderer, shadow rays, and picking |
| Light runs | Lazy `?[]` of `{count: u8, color_id: u8, intensity: u8, dir: u8}` runs (4 B) + `light_base_y`, top-to-bottom | Null = no colored light (identity tint); sky light is analytic, not stored. Allocated/grown where the flood writes values, freed when empty. `dir` is the flood's arrival direction (`lighting.Dir`), used to weight face light by normal alignment (milestone 9b) |

Runs longer than 255 voxels are split into consecutive identical runs — a
full-height 512-voxel column is 2–3 runs either way, and `u8` counts keep
runs tiny for cache density. All fields are `u8`, so the structs have
alignment 1 and zero padding; keep them packed and order any future fields
largest-to-smallest to preserve that.

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
floor (~0.25). Faces sample the sky bit in the air cell they are
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
    re-generated. Deferred: sky-BFS side-leak; `sky_ambient` /
    `glow_gain` / attenuation tuning to m13.
12. Directional sun march (Model B; reuses 7c's `DdaIterator` +
    `firstSolidInColumn`) + animated sun.
13. Fog glow from light map (single injection point from 7g) + tuning
    pass (resolution, fog cutoff, light radius).

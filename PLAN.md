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
6. Per-vertex fake AO (3-neighbor, vertical 2-stop gradient per span;
   implemented against the current simple shading loop, re-integrated into
   the single-pass zipper in milestone 8). Verify: headless PPM showing
   crevice/corner darkening.
7. Distance fog (exponential + low-pass palette variant; fog glow deferred
   to milestone 12 since it needs the light map).
8. Colored flood-fill lighting + emissive voxels (full flood only).
9. Incremental relight on edits (clear-then-reflood) + emissive palette
   animation.
10. Sky light seeding/defaults + Model A shadows.
11. Directional sun march (Model B) + animated sun.
12. Fog glow from light map + tuning pass (resolution, fog cutoff, light
    radius).

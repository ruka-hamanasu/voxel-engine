# Multi-kilometer draw distance (milestones D1-D5)

Goal: 10 km+ draw distance (D >= 100,000 voxels) at 960x540, 60 fps,
with the far field *visibly colored* (not the current fog_k=11.2 haze
that silhouettes everything past ~D/2). Target hardware: **4 cores or
fewer**, which caps render threading at ~3x and makes the far-impostor
tier (D3) the centerpiece rather than an optional lever.

## Why this shape

- The frame is per-cell ALU/branch-bound (m21: IPC 3.3-4.35, L1 miss
  <=0.3%); pixel fills are ~5%. Distance scaling is gentle by
  construction: geometric LOD handoffs keep each cascade range at a
  ~constant cell count, so cells/column grow like `levels * handoff0`,
  not like D.
- Screen columns are embarrassingly parallel: disjoint fb strips, all
  march state stack-local, no loop-carried state. The only hazards are
  the `World` chunk-lookup memo (`@constCast`, world.zig) and the
  module-global LUTs, which are already rebuilt pre-render.
- The yaw-only camera confines the far field to a thin row band near
  the horizon, and terrain is a pure heightfield (caves/arches/
  crystals are all sub-skin). A 2D heightmap impostor reproduces
  exactly what the coarse cascade would show past ~1-2 km, at one
  interval test per cell. Terrain max relief ~150 vox subtends <1 px
  beyond a few km at 960x540.
- At 10 km the deep-cascade alternative needs ~10 levels and ~20-40 MB
  of far worlds plus their gen/flood; the impostor is one ~2.4 MB
  grid synthesized from `terrain.heightAt` (pure function of seed).

## Milestones (implement and measure in this order)

### D1. Threaded render pool

Persistent `std.Thread` pool (3 workers + main participates, created at
startup). `render` dispatches strips of screen columns; `transpose` is
tiled-parallel too. Deterministic static partitioning, disjoint fb
writes => output stays byte-identical.

- Fix the `World.last_key/last_chunk` memo: per-thread shard or
  thread-local; the single-threaded assumption is documented at
  world.zig.
- `buildFogLuts`, palette anim, and `rebuildShadeLut` stay on the main
  thread before dispatch (they already run pre-render).
- Gates: `zig build test`; all four PPM sweeps byte-identical
  (current baselines views_m31*); bench A/B vs m31 numbers. Expect ~3x on the
  render portion at 960x540.

### D2. Clear-far fog curve + km plumbing

The fog_k=11.2 invariant normalizes the curve to the cutoff, forcing
>=91% fog at every LOD handoff and full haze past ~D/2 — incompatible
with a readable far field. New curve family (selected under `--fog`,
old curve kept for the regression gates and the fog_cutoff=96 tests):
low density through the midrange, converging to *exactly* 1.0 at the
cutoff. The hard convergence is non-negotiable: it hides the world
edge and the sky-horizon seam. Expect a few headless A/B tuning
rounds on the curve shape; check fog LUT interpolation error under it.

Also: `max_dist` 16384 -> 128k+; handoff schedule restructure so
near/mid stay fixed ({144, 288} then doubling) instead of tracking
fractions of D; verify per-range f32 DDA step bounds (cascade keeps
ranges short; f64 t_max remains the fallback); `--dist` accepts km
values.

Gates: pinned-config sweeps byte-identical (old curve pinned); new km
vista benches.

### D3. Heightfield impostor far tier (centerpiece)

Beyond the near/mid cascade (which ends at ~1-2 km), replace all
deeper LOD levels with a streamed 2D heightmap grid: `{top_y,
top_mat}` per cell (~128-256 vox/cell), synthesized directly from
`terrain.heightAt` + strata coloring — no fine data, no flood, no
edits. The far march is the existing column-DDA restricted to one
solid interval `[0, top_y]` per cell: one interval test, no neighbor
fetches, no light zipper, strata color pre-low-passed per cell at
synthesis (kills sub-pixel shimmer, the #1 visual risk of a clear far
field; reuses the m8 low-pass palette idea).

Cascade->impostor handoff sits where impostor cell size ~= coarsest
cascade voxel size, so both sides render the same heightfield — but
under the new fog it is in the *visible* band, unlike today's 91%-
fogged handoffs. A/B the seam via the established PPM diff-budget
pattern (diffs confined to distant silhouettes, % pixel threshold).

Validation: diff budget vs a deep-cascade reference at D=20k; new
10 km vista benches. Target: far band <= ~2-3 ms of frame.

### D4. Threaded streaming + impostor gen

Move fine-chunk gen/pyramid/encode onto the D1 pool; impostor ring
synthesis rides the same pool (cheap: ~1 us/cell, incremental ~ms).
Keeps the walk bench flat at km scale. Gates: stream determinism
tests unchanged (budgeted == completion, snapshot round-trip) — the
impostor is render-only, never lit or edited.

### D5. Budget reclamation levers (profiling-gated)

- Impostor-as-oracle early-out: per screen column, if every free row
  clears the far silhouette at all distances, skip the far march.
- Per-macro-cell `min_solid_y` (the PLAN.md hierarchical-DDA summary)
  for long shallow rays.
- ReleaseFast for the render module only.
- Last resorts if still >16.6 ms: lower internal res with upscale,
  strip-local fb (m21 remnant, est. 4-7%).

## Risks

1. **Shimmer** in the clear far field — mitigated by per-cell
   low-passed color and cells large enough that sub-voxel geometry
   never resolves.
2. **Fog curve look** — believable aerial perspective + readable
   2-10 km terrain is a tuning problem; budget headless A/B rounds.
3. **Impostor seam** in the visible band — mitigated by matching cell
   size to the coarsest cascade voxel at the handoff.
4. **4 cores is tight** — if D1+D3 land at ~20 ms, the honest levers
   are D5, not heroics.

## Verification conventions (unchanged)

`zig build test` green; the four PPM sweeps byte-identical under their
pinned configs; `--bench 1000` A/B per milestone; walk bench + mem.sh
for the streaming milestones. New km-scale benches/baselines added at
D2 and extended at D3.

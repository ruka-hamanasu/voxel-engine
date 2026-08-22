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
  the horizon, and terrain is a pure heightfield (caves/
  crystals are all sub-skin). A 2D heightmap impostor reproduces
  exactly what the coarse cascade would show past ~1-2 km, at one
  interval test per cell. Terrain max relief ~150 vox subtends <1 px
  beyond a few km at 960x540.
- At 10 km the deep-cascade alternative needs ~10 levels and ~20-40 MB
  of far worlds plus their gen/flood; the impostor is one ~2.4 MB
  grid synthesized from `terrain.heightAt` (pure function of seed).

## Milestones (implement and measure in this order)

### D1. Threaded render pool

The renderer becomes a `Renderer` struct (render.zig) owning a
persistent pool (pool.zig: 3 `std.Thread` workers + main participates,
created at startup). `render` dispatches contiguous strips of screen
columns grabbed via an atomic strip counter (better load balance than
static 4-way splits on sky/terrain-split views); `transpose` is
tiled-parallel the same way. Writes are column/tile-disjoint with no
cross-strip state, so output stays byte-identical. A zero-worker
`Renderer` runs inline (test path).

- Fix the `World.last_key/last_chunk` memo: shard it to one slot per
  pool participant, indexed by a `threadlocal` slot id the pool sets
  (world.zig). No accessor call-site changes.
- `buildFogLuts`, palette anim, and `rebuildShadeLut` stay on the main
  thread before dispatch (they already run pre-render).
- Gates: `zig build test`; all four PPM sweeps byte-identical
  (current baselines views_m31*); bench A/B vs m31 numbers. Expect ~3x on the
  render portion at 960x540.

### D2. Clear-far fog curve + km plumbing — COMPLETED (milestone 33)

Outcome: clear curve is the default (clear_k = 4 after A/B), fog LUTs
endpoint-anchored so the last bucket is exactly 1.0, schedule fixed at
{144, 288} doubling, max_dist 131072, all gates green. One finding
that shapes D3/D4: coarse-chunk synthesis regenerates 4^level fine
tiles per chunk, so streamer warmup is quadratic in chain depth (8 km
spawn ~15 min) — the impostor tier eliminates the deep levels rather
than speeding them up. Details and numbers: PLAN.md milestone 33.

Retained design notes:

The fog_k=11.2 invariant normalizes the curve to the cutoff, forcing
>=91% fog at every LOD handoff and full haze past ~D/2 — incompatible
with a readable far field. New curve family (decisions locked with the
user): `(exp(k*x) - 1) / (exp(k) - 1)` over fractional x = t/cutoff
with k = density*cutoff (default clear_k ~4, tuned via headless A/B):
low density through the midrange, converging to *exactly* 1.0 at the
cutoff. The hard convergence is non-negotiable: it hides the world
edge and the sky-horizon seam. The new curve is the RenderParams
default; `--fogcurve <old|clear>` selects, `--fog` keeps its density
override (k = density*cutoff in both families). The old curve stays
for the fog_cutoff=96 unit tests (their mid-bucket expectations assume
it); the l0f0 sweep halves run with fog off, so only the def halves
regenerate (views_m32*). Check fog LUT interpolation error under the
steep terminal rise; bump fog_buckets if banding shows.

Also: `max_dist` 16384 -> 131072; handoff schedule restructure so
near/mid stay fixed ({144, 288} then doubling while < D, so the
default D=672 gains a third handoff at 576) instead of tracking
fractions of D; per-range DDA steps are a constant ~144 level-voxels
by construction (final partial range <= ~320 at 128k), so f32 t_max
stays (verified, not just assumed). max_lods stays 8 — the streamer's
rep_grid scratch is 4^n*h bytes, so a 10-level chain would cost
~270 MB; at D=100k the truncated last range is ~318 steps, which is
fine until D3 replaces the deep cascade. `--dist` stays plain voxels
(100000 = 10 km; no km suffix). Verification scripts now live in
scripts/ (moved out of /tmp).

Gates: `zig build test` green; l0f0 sweep halves byte-identical to
views_m31*; def halves regenerated as views_m32*; new km vista benches
(scripts/vista_km.sh) + mem.sh at km scale.

### D3. Heightfield impostor far tier — COMPLETED (milestone 34)

Outcome: past the cascade handoff (default 1152, `--impdist`) a
streamed 2D heightmap grid (`src/impostor.zig`, {top_y, mat, stamp}
per 128-vox cell, `--impostor`; 0 disables) replaces all deeper LOD
levels. Synthesis is behind a generator facade (gen.impostorCell):
terrain samples a 9x9 heightAt grid + pad (4 + max-sample-delta/4,
pinned by a brute-force conservativeness test). The far march
(render.marchImpostor) is
the column-DDA at 1/cell_size scale with one interval test per cell
through the existing SegmentSink/segmentColor path. Seam A/B vs the
deep-cascade reference (960x540): spawn 0.41% (2 km) / 0.67% (4 km)
/ 0.43% (8 km) pixels differing, confined to the horizon band; aerial
7.5-11% (the intended one-mat-per-cell low-pass; mesa-quantized but
static, no shimmer). Cell 64 halved nothing meaningful at 4x cost —
128 kept. Findings that shape D4: impostor warmup at 10 km is ~13 s;
and the streamer's last-cascade-level radius must use the
impostor handoff, not the fog cutoff, or the quadratic coarse-chunk
gen returns (7 min warmup at 10 km). Numbers: PLAN.md milestone 34.

Retained design notes:

Beyond the near/mid cascade (which ends at ~1-2 km), replace all
deeper LOD levels with a streamed 2D heightmap grid: `{top_y,
top_mat}` per cell (~128-256 vox/cell), synthesized directly from
`terrain.heightAt` + strata coloring — no fine data, no flood, no
edits. Synthesis is a multi-resolution heightfield query: `top_y` is
a conservative max of `heightAt` over the cell footprint (sample grid
+ noise Lipschitz pad, or a max-mip over a precomputed heightfield).
**Edits (deferred until persistence):** the impostor is render-only,
but cells covering dirty columns must eventually show them — keep a
per-cell dirty/version stamp so those cells re-synthesize with the
edited columns overlaid on the heightfield (cheap at ~1 us/cell;
edits never enter the cascade below the impostor). The far march is
the existing column-DDA restricted to one solid interval `[0, top_y]`
per cell: one interval test, no neighbor
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

### D3.1. Impostor seam remediation — COMPLETED (milestone 34
follow-up)

Outcome: both findings fixed. F1 (fog): clearKFor ramps the clear
curve's k from 4 (D <= 2048, baselines untouched) to 2 at 8+ km vox,
restoring gentle aerial perspective over the impostor band. F2
(pixel-matched handoffs): the impostor is now a multi-level
heightmap cascade {32, 64, 128, ...} vox/cell doubling while
72*S < cutoff — the cascade's own f/72-px invariant — so every seam
is a 2x-granularity handoff. Seam A/B vs deep-cascade reference
(960x540, dist 4096): spawn 0.67% -> 0.04%, vista 0.47% -> 0.02%,
aerial 11% -> 2.4%; at 8192 spawn 0.43% -> 0.04%. True 10 km
(--dist 100000) unbounded: 13.2 ms/frame at 960x540, warmup ~2 min
single-threaded (D4's
threading target), mem 95 MB (vs 93 at 10240 — the rings add ~2 MB).

Retained findings (original text below the F-list):

- Rotation shimmer was the 128-vox single tier's 16x granularity
  jump at the handoff plus near-zero fog — the multi-level schedule
  removes the jump, F1 covers the rest.
- The horizon pop was the 1152-vox (115 m) handoff, 10x closer than the
  design text's "~1-2 km"; the pixel-matched schedule fixes the
  intent rather than the number.

### D4. Threaded streaming + impostor gen — COMPLETED (milestone 36)

Outcome: the D1 pool moved to main and is shared by render, streamer,
and impostor (null pool = the pre-D4 inline path; tests untouched).
Fill dispatches 64-column ranges, the pyramid 32-column ranges, the
commit encode 8x8 macro-grid groups; ensureChunk and the cross-chunk
flood stay serial in queue order, so worlds stay byte-identical
(pooled-vs-inline snapshot tests, all four sweeps + the 10 km frame
identical). Impostor synthesis rides the pool as 128-cell ranges.
Numbers: walk 12.8 -> 10.3 ms (672), 13.6 -> 11.2 ms (--dist 10240,
~1 km);
--dist 100000 warm-up 35 -> 10 s (3.5x); mem unchanged. Details:
PLAN.md milestone 36.

Retained design notes:

Move fine-chunk gen/pyramid/encode onto the D1 pool; impostor ring
synthesis rides the same pool (cheap: ~1 us/cell, incremental ~ms).
Keeps the walk bench flat at km scale. Gates: stream determinism
tests unchanged (budgeted == completion, snapshot round-trip) — the
impostor is render-only, never lit; edits deferred to the persistence
milestone via D3's dirty-cell re-synthesis.

### D5. Budget reclamation levers (profiling-gated) — current plan

Last measurements: 13.2 ms/frame at true 10 km (--dist 100000 = 10 km
at 10 cm/vox, D3.1, 960x540; D4 left the 10 km frame byte-identical
and cut warm-up 35 -> 10 s but did not re-time it), 11.2 ms walk at
--dist 10240 (~1 km, D4) — likely already under the 16.6 ms target on
this machine.
So: **measure first, implement levers only if over budget.** ReleaseFast
is excluded for now (user directive); lower internal res + upscale and
strip-local fb remain last resorts. Preceded by the refactor pass in
plans/REFACTOR.md (R2.3's marchRange skip-block merge leaves a single
insertion point for lever 2).

- **Lever 1 — impostor-as-oracle early-out.** After the cascade march,
  columns with free rows walk the full impostor chain (~6 levels x ~72
  cells at 10 km) even when the far terrain is entirely below the ray's
  height window (high camera, or a near ridgeline occludes the horizon);
  the per-cell skip rejects those cells individually, the oracle rejects
  them in bulk. Cheap exact form: per-tile `max_top_y` (maintained at
  synthesis), tested against the free spans' steepest downward slope
  per tile span — skip tile spans the lowest free row still clears.
  ~60-100 lines, conservative (exact-output), view-dependent payoff.
- **Lever 2 — per-macro-cell min_solid_y** (the PLAN.md
  hierarchical-DDA summary): extends the 8x8 macro grid from max-only
  to [min,max] so long shallow rays also skip when the height window
  misses the solid interval from below. Doubles the grid, and every
  mutation path (setRange/setColumnRuns/updateMacro, chunk rebuild,
  snapshot hashing) must maintain it. Caveat from the audit: grounded
  heightfield columns are solid from y=0, so the below-skip fires
  mainly under overhangs/arches/caves — its real value is the future
  city generator. Deprioritized; implement only if lever 1 lands and
  the frame is still over budget.
- **Measurement plan:** 10 km frame + walk bench at --dist 100000 and
  10240, scripts/vista_km.sh, mem.sh at 960x540, plus a perf-stat
  attribution (cascade vs impostor vs transpose). If under 16.6 ms, D5
  closes as evaluated-and-deferred with numbers (same disposition as
  milestone 21's levers).

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
5. **Far edits** — impostor cells ignore edits until persistence
   lands; the dirty-cell stamp keeps the hook explicit so D3's
   render-only fast path doesn't bake in the assumption.

## Verification conventions (unchanged)

`zig build test` green; the four PPM sweeps byte-identical under their
pinned configs; `--bench 1000` A/B per milestone; walk bench + mem.sh
for the streaming milestones. New km-scale benches/baselines added at
D2 and extended at D3.

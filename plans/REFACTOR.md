# Refactor pass (pre-D5)

## Status

- R1: COMPLETED. All R1.1-R1.4 items done (committed as "Refactor
  phase 1"). Gates: `zig build test` green; all four sweeps
  byte-identical to views_m39*. `--world-h 0` now returns
  `error.BadWorldSize` (was a terrain assert). Adjustments vs the item
  list: `macro_ok` removal also dropped the `updateMacro` guard
  (world.zig); `chunkBox` covers 4 clamp copies (loadCoarseChunk had a
  4th); `shadeAt` kept (4 test uses); the merged `setColumnRuns` takes
  `keep_light: bool` with no wrappers (callers updated);
  cellEntryAt/cellExitAt became one `cellEdgeAt` with a comptime edge.
- **R2: COMPLETED.** All R2.1-R2.5 items done (uncommitted). Gates:
  `zig build test` green (new seedPrev axis/cell unit test); all four
  sweeps byte-identical to views_m39*; --dist 2048 impostor smoke OK
  (R2.4 changes only the un-pinned km-vista output: boundary cells
  whose entry crossing is z-side now shade 0.6, was always x-side
  0.8). Adjustments vs the item list: R2.1 passes `*SegmentSink`
  (bundles fb/height/sx/free/params/fog_ray; hoisted per-march in
  marchRange) instead of separate free/params scalars — 25 params ->
  7; R2.2 leaves marchImpostor's scalar rescale alone (user call: a
  MarchCfg without a world is a lie, optional world worse), scaledCfg
  serves the two cascade sites; R2.5 found 8 emit sites, not six.
- R3: not started.

Simplification pass ahead of the DISTANCE.md D5 work, from a three-way
audit of src/. Gates after every phase: `zig build test` green and all
four PPM sweeps byte-identical (l0f0/lod0 pinned configs, def/stream vs
views_m39*). Everything is byte-identical by construction except item
R2.4 (the impostor face-axis fix), which touches only the un-pinned
km-vista output. Estimated total: ~250-350 lines removed, one real bug
fix, one shading correctness fix.

## R1. Mechanical cleanups

1. **Fix the dead `--world-h` validation** (main.zig:105-107): the range
   check runs before the flag is applied, so it can never fire and
   `--world-h 0` falls through to a terrain assert. Apply the flag
   first. Real bug.
2. **`forDrawDistance` calls `impostorTruncate`** (render.zig:137-140
   duplicates render.zig:84-88's semantics).
3. **Dead code deletion:**
   - `world.buildDemoRoom` (world.zig:657-672, zero callers)
   - `lighting.lightColor` (lighting.zig:46-50, zero callers)
   - `World.macro_ok` (always true — World.init's `h <= maxInt(u16)`
     assert subsumes it; removes the render-side guard too)
   - `ConstSrc.seek/next`, `SkySrc.seek/next` (spans.zig — fillSpans
     type-dispatch makes them unreachable)
   - `shade.applyGlow` (u32 wrapper), `fogStopV`, `fogStop`
     (shade.zig — no callers; `fogStopsV` is the live path). `shadeAt`
     is test-only: keep or inline into its four test uses.
   - `RenderParams.time_s` (written per frame, never read — pre-pool
     remnant)
   - `CellJob.size` (impostor.zig — derive from `shift` at use)
   - `Impostor.budget` field (hardcoded 512 — make it a module const)
   - `CellCtx.sky_y` init's unreachable `no_solid` branch (render.zig
     :1034 — processCell already early-outs on `no_solid`)
4. **Mechanical dedups:**
   - `world.get` = `getResident(...) orelse 0` (world.zig:522-551)
   - Merge `setColumnRuns`/`setColumnRunsKeepLight` behind a
     `keep_light: bool` param (the builder.encodeDenseColumn convention)
   - One `chunkBox` helper for the triplicated chunk-footprint clamp
     (chunk.zig loadChunk/commitChunk/unloadChunk)
   - Pyramid-downsample + copy-tile-columns helpers shared by chunk.zig
     and stream.zig (three copies of the downsample chain, two of the
     tile copy)
   - `lod.rebuildColumn`'s encode block -> `builder.encodeDenseColumn`
     (lod.zig:59-78 duplicates builder.zig:55-76; import is acyclic)
   - Lighting: shared neighbor-box `contains` for propagate/clearChain
   - `fillHoles`: incremental `scale *= 0.5` instead of the O(lvl) loop
   - Merge `casc_limit`/`t_imp` (render.zig:490-497 — always equal)
   - Small: `rowAt` delegates to `rowAtF`; `detailBoundary` via
     `cellEntryAt`; merge `cellEntryAt`/`cellExitAt`

## R2. Structural render refactors

1. **`processCell` arity**: 25 params -> `MarchCfg` + `*const
   DdaIterator` + ~5 scalars (t0, t1, no_cull, free, params, comptime
   detail). Pure plumbing; the six test call sites get shorter too.
2. **One `scaledCfg` helper** for the three copy-pasted MarchCfg
   scale-frame constructions (render.zig:530, :576, marchImpostor's
   open-coded rescale at :701-709).
3. **Merge marchRange's macro-skip/hole-record blocks**
   (render.zig:645-672) into one path — the single insertion point for
   any future skip (D5 lever 2, if ever).
4. **Shared `seedPrev`** (the t_begin>0 previous-cell seeding,
   render.zig:623-635), called from `marchImpostor` too — **fixes the
   impostor first-cell face-axis bug**: boundary cells currently always
   shade x-side (0.8) when the entry crossing may be z-side (0.6).
   Changes only un-pinned km-vista output; all pinned sweeps have the
   impostor inactive, so gates stay green.
5. **`emitSide` helper** for the six copy-pasted side-face emits in
   genSegments (render.zig:1161-1238). Top/bottom emits stay open-coded
   (stop swap, morph, walk direction differ too much).

## R3. Cross-module consolidation

1. **Generic `pool.dispatchRanges`**: collapses the five hand-written
   "item i -> disjoint range [base+i*gran, ...)" job structs
   (render ColumnJob/TransposeJob, terrain FillJob, chunk PyrJob,
   impostor CellJob; ~50-70 lines). `EmitJob` keeps its custom form
   (2D macro-group indexing + atomic error capture). Keep a one-line
   comment per call site recording the granularity rationale.
2. **Shared `unpackKey`** next to `world.chunkKey` (deletes the copies
   in impostor.zig:50-52 and stream.zig:222-224) and **one
   multiplicative-mix hash context** for ChunkMap/TileMap/CellMap
   (world.zig:102-104, impostor.zig:56-63, lighting.zig:86-93).
3. **`render.lodCount` + `render.resizeLodChain`**: collapses the four
   copies of the increasing-prefix scan / doubling-extension rule
   (main.zig:178-191, main.zig:216-224, render.zig:307-320,
   render.zig:92-98) and makes the `--lods` policy unit-testable.
4. **Warm-up/timing helpers** in main.zig (five copies of the
   timestamp + `runToCompletion` + ms-log pattern).
5. **Resolve test-only `chunk.loadCoarseChunk`** (chunk.zig:148-200 —
   superseded by `Streamer.progressLoad`; only its own tests call it).
   Rewire the coarse-parity test through the shared pyramid/copy
   helpers and delete the function, keeping the test's
   order-independence pin against `lod.build`.
6. **Drop `--lod2`** (exactly `--lod` + `--lods 2`; `--lod2 0` =
   `--lods 1`). Update the one pinned script config
   (scripts/views.sh:12 -> `--lods 1`), help text, PLAN.md note.
   `--lod` stays (heavily pinned in scripts).

## Explicitly kept (checked during the audit, not candidates)

- **gen.zig facade / `--gen` / `Impostor.kind`**: a second world
  generator (cyberpunk city) is planned — the one-member union is the
  extension point it will plug into.
- **`--fogcurve old`, `--atten`, `--time`, `--exact-coarse`,
  `--load-budget`**: documented tuning/A-B levers with pinned tests.
- **World/impostor memo sharding** (`@constCast`, threadlocal slots):
  sound; the constant is shared with pool.max_participants.
- **`Cell.stamp` (impostor)**: persistence milestone's dirty hook.
- **lod.zig**: still live in the bounded path, stream onEdit, tests.
- **Merging impostor ring management with stream.zig**: shapes rhyme,
  payloads differ (flood/lighting/commit vs pure synthesis) — a
  generic would cost more than the ~30 lines saved.

## Sequencing

R1 -> gates -> R2 -> gates -> R3 -> gates -> D5 measurement (see
DISTANCE.md). Doc comments updated in code as mechanisms move; PLAN.md
gets one milestone entry at the end covering the refactor pass + D5
outcome.

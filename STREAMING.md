# Chunked streaming & JIT terrain generation plan

## Status

- **Phase 0 — DONE** (PLAN.md milestone 26). Accessor indirection
  (`World.columnAtMut`), box-local flood scratch keys, optional XZ
  bounds in camera/player clamps: all three verified byte-identical
  against views_m25[/]_lod0 before worldgen changed. Worldgen is
  position-deterministic: `Ctx`/`heightAt`/`genColumn` in
  gen/terrain.zig, hash3-rolled crystals, one arch max per 128x128
  region (first of 8 hash candidates passing flatness/lintel/bounds
  wins; candidate origin range is region-local [10, 88] intersected
  with the bounded world's [10, size-40]), arches stamped into the
  64x64xh Builder tile pre-encode (tile pipeline = future chunk load),
  spawn by ring search near origin. Baselines regenerated as
  views_m26[/]_lod0, rerun byte-identical; tile-independence (64 vs 16)
  pinned by test. Startup 0.50 -> 0.52 s; benches move only with the
  new layout.
- **Phase 1 — DONE** (PLAN.md milestone 27). `World.columns` ->
  `chunks: HashMap(u64, *Chunk)` (64x64-column chunks, packed i32 key,
  multiplicative-mix hash + last-chunk memo behind the inlined
  accessors — plain Wyhash cost ~20% of the frame, memo+inline brought
  the bench back to parity). `w/d` are `?usize`; bounded worlds load
  all covering chunks at init. `loadChunk`/`unloadChunk` in
  src/chunk.zig; chunk gen == eager gen and unload-relight == reflood
  pinned by tests. Both view sweeps byte-identical to views_m26.
- **Phase 2 — DONE** (PLAN.md milestone 28). The coordinate path went
  signed (Region/set/fillBox/pickPixel/Scratch origins i32). Key
  design change vs item 8's original sketch: the flood now confines
  propagation to RESIDENT columns (World.getResident; non-resident
  reads as blocked, not air), so no stored chain can route through an
  unloaded chunk — chunk loads flood as a pure add pass and still land
  the same fixpoint a single flood over the resident set computes
  (pinned by the per-chunk == floodAll parity test, full extent). A
  two-phase load (pre-gen air flood + post-gen clear) was implemented
  first and abandoned: chains whose bright side lay in a non-resident
  chunk reconstructed too dim and survived stale. Coarse chunks
  synthesize from Ctx through a dense pyramid (== iterated lod.build
  by construction; direct-from-fine picks different materials at mixed
  top layers), never from resident fine chunks, so levels are
  independent; fine-chunk unloads with live edits re-synthesize the
  covering coarse columns (repair queue). Approx coarse gen
  (genColumnFast: no sub-skin caves/crystals) is the default —
  `--exact-coarse` opts out; exact stays the test reference.
  relight fast paths: CellMap multiplicative hash, stale scan over
  the map not the volume, shell-only border enqueue, empty-scratch
  skip. Streamer (src/stream.zig): per-level Chebyshev discs (radius
  = level render dist/2^i + margin, one chunk of unload hysteresis),
  nearest-first queue, column-sliced budgeted fills (`--load-budget`,
  default 1200), commit = stamp/encode/flood in one step, player-AABB
  chunks force-generated before physics, sync warm-up in all modes.
  main.zig: --world-w/d are optional test bounds (both or neither);
  the default world is unbounded and streamed. Verification: pinned
  bounded sweeps byte-identical to views_m26[/]_lod0; new unbounded
  sweeps (views_stream[/]_lod0.sh) baselined as views_m28[/]_lod0,
  rerun byte-identical. Bench (960x540, bounded, prev -> new): spawn
  13.39 -> 13.29, aerial 9.56 -> 9.49, neutral. Unbounded spawn
  14.56 (march sees terrain past the old 384 edge). Warm-up 1.3 s
  (was 6.8 s exact/2.9 s approx before the relight fast paths).
  MaxRSS: unbounded 34 MB vs bounded 38 MB; fine tier ~7 MB.
- **Phase 3 — DONE** (PLAN.md milestone 29). Item 13's tests were
  already landed with phases 0-2 (tile independence
  gen/terrain.zig, loadChunk == eager gen and per-chunk floods ==
  floodAll + unload == reflood + coarse parity in src/chunk.zig,
  unload/reload round-trip in src/stream.zig); this phase filled the
  item-14 gaps. `--cam-to` gives --bench a camera path: the camera
  lerps over the bench frames and the streamer runs under the
  default per-frame budget inside the timed loop. Walk bench
  (/tmp/opencode/walk_bench.sh, 960x540, unbounded, spawn -> +320 x
  = 5 fine chunk boundaries over 240 frames): 16.7-16.9 ms/frame
  with 28 chunk loads vs 14.5 static spawn — streaming adds ~2.3
  ms/frame while walking. New unbounded worst view
  (-150,55,-150,5.5): 14.9. Memory (/tmp/opencode/mem.sh, /proc
  VmHWM polling): unbounded 31.4 MB vs bounded 38.4 MB peak.
  Verification: zig build test green; all four sweeps
  byte-identical (views_m26[/]_lod0, views_m28[/]_lod0).

Decisions (agreed): **unbounded** world; worldgen becomes
position-deterministic and the default world's feature placement changes
(view-sweep baselines regenerate); **always chunked** (one world path —
small test worlds just load all their chunks); **synchronous generation
with a per-frame budget** (threads deferred). No persistence: dropped
chunks regenerate identically on demand, edits to dropped chunks are
lost.

## Why the current code is close

- The renderer already tolerates missing columns: `processCell` does
  `columnAt(...) orelse return`, `macroMax` returns null -> skip, AO
  neighbor cursors accept null columns. Missing chunks read as air.
- Only 4 direct `world.columns[...]` accesses exist outside world.zig,
  all in lighting.zig (decodeColumns, seedEmissiveBox, encodeColumns).
- `lighting.relight`'s add pass already seeds from lit cells adjacent to
  the dirty region — exactly the boundary treatment a freshly loaded
  chunk needs. Light reach is capped at 31 voxels (255/8 attenuation).
- A coarse LOD column reads at most 4 fine columns, which a pure
  column-gen function can synthesize transiently: coarse chunks never
  require fine residency.

## Phase 0 — refactors first

1. **Column accessor indirection.** Route lighting.zig's 4
   `world.columns[x * world.d + z]` sites through a new
   `World.columnAtMut(x, z) ?*Column`. Mechanical.
2. **Box-local flood scratch** (lighting.zig). `Scratch.index/coords`
   use the box's own xd/zd strides instead of `world.d`, so the u32 key
   cap (2^32) bounds one flood box ((chunk + 2*reach)^2 * h ~ 2M), not
   the world volume.
3. **Position-deterministic worldgen** (gen/terrain.zig). Generation is
   restructured as a staged per-chunk tile pipeline (the per-column math
   is unchanged — storage and rendering are columnar — but arches are
   tile features crossing chunk boundaries, so they must be stamped
   before encoding, not applied via fillBox after):
   `heightAt` tile -> dense tile scratch (chunk_w x chunk_d x h u8,
   ~512 KB reusable) -> arch stamps into the tile -> run-encode all
   columns -> flood. `Builder` generalizes from single-column dense
   scratch to a dense tile; `genColumn` writes one tile column. The
   staged tile also enables SIMD-batched noise later without touching
   dispatch.
   - `heightAt(noises, x, z) u16` pure function (the fbm2 heightfield
     already is one).
   - Crystal rolls: per-position hash (hash3(x, y, z)-derived rolls, so
     validity order doesn't matter) instead of the sequential
     world-global `rng`.
   - Arches: region-hashed features. Per 128x128 region a hash decides
     existence/position/orientation; flatness via `heightAt` spans
     computed on the fly. Chunk gen consults its own + ring-1 regions
     (arch footprint <= ~35 wide). Replaces the global attempts loop and
     `farFromLandmarks`.
   - Extract `genColumn(ctx, x, z, dense_column_out)` — one code path
     for tests, chunk loading, and coarse-level synthesis.
   - Spawn: `heightAt` search near the origin (unbounded => spawn at
     ~0,0); `landmarks` = arches in regions near spawn (headless debug
     logging only).
   - Regenerate all view-sweep baselines (world layout changes).
4. **Player/camera declamp** (player.zig:72,122-124). XZ clamps become
   no-ops when the world is unbounded; keep them for bounded test
   worlds.

## Phase 1 — chunked storage (world.zig + chunk.zig)

Decisions: chunk lifecycle (`loadChunk`/`unloadChunk`) lives in a new
`src/chunk.zig` importing world/lighting/terrain, so world.zig stays
free of upward imports; the render hot path uses plain AutoHashMap
lookups (bench A/B decides whether a fast path is warranted). The
default world stays bounded and fully resident in phase 1 — the
streamer (item 11/12) flips it to unbounded — so the m26 baselines
must remain byte-identical.

5. `Chunk`: 64x64 columns (one 256 KB 64-aligned block), its own
   8x8-cell `macro_max` grid, per-column light runs as today. Chunk
   coord = `floorDiv(x, 64)`; key = packed i32 pair in a u64.
6. `World` internals: `columns []Column` ->
   `chunks: std.AutoHashMap(u64, *Chunk)`; `w/d` become `?usize` bounds
   (null = unbounded; bounded only for tests); `h` stays required (u16
   y caches). `columnAt`/`columnAtMut`/`get`/`solidAt`/`macroMax` go
   through the map; missing = air. `setColumnRuns`/`setRange` operate on
   resident chunks; `set`/`fillBox` clamp/no-op on unloaded columns.
   `init` no longer pre-fills — chunks allocate on demand with uniform
   air runs (inline, no per-column alloc). Bounded worlds (all test
   worlds, and the default until phase 2) eagerly load their covering
   chunks. Tile origins thread through `genTile`/`Builder.emit` as
   i32 so negative chunk coords work.
7. Chunk lifecycle (src/chunk.zig): `loadChunk(cx, cz)` =
   `World.ensureChunk` + the staged tile pipeline (dense fill ->
   arch stamps -> run-encode); `unloadChunk` blanks the chunk's
   materials PRESERVING light runs, `lighting.relight`s the chunk box
   (the stale-seed clear needs the old runs to find orphan chains into
   neighbors), then frees (see 9 for the hysteresis context). The 3
   `columnAtMut(...).?` sites in lighting.zig become `orelse continue`
   (decode/seed/encode touch resident columns only).

## Phase 2 — streaming, lighting, LOD

8. **Chunk flood on load** (relight-style): scratch box = chunk + reach
   ring; `decodeColumns` loads resident neighbors' border light; seed
   the chunk's emissives; enqueue resident lit cells adjacent to the
   chunk; propagate; `encodeColumns` writes only to resident columns.
   As implemented (phase 2): propagation is confined to resident
   columns (`World.getResident`; non-resident = blocked, not air), so
   no stored chain routes through an unloaded chunk and the load flood
   is a pure add pass landing the resident-set fixpoint. Leaks past
   the resident set are never written, and light reach (31) is far
   inside the load margin past render distance (~100).
9. **Chunk unload**: blank the chunk's materials (uniform-air
   `setColumnRuns` per column) -> relight the region (the existing
   stale-seed path clears orphan light chains) -> free. Unload radius >
   load radius (hysteresis), both beyond fog cutoff, so the clear is
   invisible. Amortize across frames if profiling says so.
10. **LOD chain**: coarse chunks built on demand by downsampling a
    dense pyramid over generated fine columns (genColumn + arch stamps;
    `genColumnFast` approx variant skips sub-skin caves by default) —
    no fine residency, and the levels are mutually independent.
    Edit-driven `rebuildRegion` only fires for resident fine chunks
    (resident-guarded); a fine chunk unloaded with live edits gets its
    covering coarse columns re-synthesized from generation.
11. **Streamer** (new `src/stream.zig`): per frame, the desired set is a
    per-level Chebyshev disc around the camera chunk; radius = level's
    max render distance + 4-voxel margin (fine ~100, lod1 192, lod2
    fog_cutoff 448; generalize for `--lods N`). Load queue nearest-
    first. Generation cost is concentrated in the dense-fill stage, so
    the budget slices by column ranges within that stage: an in-flight
    chunk keeps its partial tile as streamer state across frames, and
    arch-stamp + encode + flood run as one fast finishing step. The
    chunk under the player force-generates synchronously before physics
    (collision reads air as fall-through). Unload beyond the hysteresis
    radius.
12. **main.zig**: replace `gen.generate` + `floodAll` + eager
    `lod.build` with streamer init; per-frame `stream.update(player)`
    before physics/render; `--bench`/`--headless` run the streamer to
    completion around the camera first (synchronous warm-up). CLI:
    `--world-h` kept; `--world-w/d` become optional test bounds; add
    `--load-budget` if profiling wants it. The edit -> dirty -> relight
    path is unchanged (edits only land on resident chunks).

## Phase 3 — verification

13. Tests: per-chunk gen equals whole-region gen over overlaps
    (determinism); unload/reload round-trip identity; chunk-border light
    equals a single big flood on a bounded test world; existing suites
    updated for the accessor/chunkmap API. (All landed with phases 0-2;
    see the status section.)
14. Regression: baselines regenerated against the new worldgen as
    views_m26[/]_lod0 (bounded) and views_m28[/]_lod0 (unbounded),
    rerun byte-identical; bench A/B recorded per milestone (m26-m28)
    plus the walk-across-chunk-boundaries scenario (--cam-to bench
    path, /tmp/opencode/walk_bench.sh); memory measurement
    (/tmp/opencode/mem.sh).

## Generation cost

Cave noise dominates: per column, three `fbm2` heightfield evals (the
milestone-31 biome split) and a cave scan of two `fbm3` evals per
y-position from bedrock to surface-9 (~28 positions on the h=128
plains, up to ~145 under h=256 mountains) where the cave mask passes
(~half of columns). Grounding: milestone 17
measured 768x1024x768 gen + LOD + 3 floods at 51 s in Debug; estimating
gen at ~20-30 us/column Debug gives ~3-8 us/column in ReleaseSafe, so a
64x64x128 chunk lands at ~15-40 ms and a 32x32 chunk at ~4-10 ms.
Measure first (instrument loadChunk), then tune.

Levers, in order: column-sliced resumable generation (planned); 32x32
chunks (more map overhead, same macro-cell granularity); approximate
coarse-LOD synthesis that skips sub-skin cave noise (caves can't change
a coarse column unless they remove its top voxels; fog hides the rest)
~10x cheaper coarse gen; SIMD-batched noise over the dense tile.

## Deferred levers

Background gen threads; chunk persistence / delta save; per-level chunk
sizes; f64 DDA t beyond ~16k.

## Open points to resolve during implementation

- Exact per-level load radii vs `lod_dists` for `--lods N`.
- Whether unload-time relight cost needs cross-frame amortization.

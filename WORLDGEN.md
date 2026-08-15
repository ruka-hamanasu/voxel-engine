# Worldgen — the minecrafty demo world

`src/gen/terrain.zig` generates the demo world: heightmap terrain with
strata, caves, crystals, arches, and a spawn search. Everything derives
from a position-deterministic `Ctx` (seed + world height, no mutable
state), so per-chunk streamed regeneration equals whole-world gen (the
streaming pipeline itself is documented in STREAMING.md). `heightAt` is
the single pure surface function — fine columns, coarse-LOD approx
synthesis, arch flatness spans, and the spawn search all read it, so
they can never disagree about the surface.

## Heightfield (current)

- `heightAt`: `fbm2(x/36, z/36, 4)`, height =
  `clamp(base + n * amp, 6, h - 12)` with base = 0.30h, amp = 0.16h.
  Single-scale noise: relief is ~1.3 player heights (player is 16
  voxels) and plains are exactly as rough as the peaks — the "player
  feels gigantic" problem.
- Strata per column: bedrock at y=0, stone below surface-4, dirt, grass
  on top; sand replaces dirt/grass below `sand_level = base - 0.45*amp`.

## Caves & crystals

- Cave gate: `n_mask.noise2(x/40, z/40) > -0.1` (~half of columns).
- Tunnels: two `fbm3(x/24, y/36, z/24)` fields carved where
  `a*a + b*b < 0.05`, giving ~10-wide tunnels with 14–18 voxels of
  headroom (sized for the 16-voxel player, milestone 22).
- An 8-voxel solid skin under the surface keeps caverns sub-surface
  (sloped terrain still gets occasional skylit slot-canyon breaches,
  which read as cave entrances). The skin is also what makes the
  coarse-LOD approx synthesis (`genColumnFast`, no sub-skin caves)
  silhouette-exact.
- Crystals: hash-rolled (`hash3`, order-independent) on cave floors
  with 5 voxels of headroom, 1-in-48 columns, 4 tall, three colors
  (cyan/magenta/amber).

## Arches

- At most one arch per 128x128 region, decided by a region-coord hash:
  up to 8 hash-derived candidate origins, first one passing the checks
  wins (depends only on seed/region/bounds, never visit order).
- Checks: 29x29 flatness span max-min <= 12 (legs may be partially
  buried in a slope, but a ridge must not split the arch); lintel must
  not clip the world top (`span.min + 34 <= h`).
- Geometry: 27w x 33h x 6 thick, 17x18 opening stepped to a lintel (a
  16-voxel player walks through). Stamped as 4 fill boxes into the
  dense tile after column fill, so arches crossing tile boundaries are
  exact.

## Spawn

- Expanding square-ring search near the origin (bounded worlds clamp
  candidates inside) for a 6x6 spot with height span <= 2, at least 20
  voxels from any arch; falls back to world center (bounded) or origin
  (unbounded).
- Camera spawns with feet on the surface (eye 14 up); yaw aims at the
  nearest arch landmark within 192 voxels.

## Plan: larger plains, higher mountains

Goal: the player stops feeling gigantic — large flat plains and
mountains that tower over them.

1. **Biome-split heightfield** (`heightAt`, contained to terrain.zig):
   - Continentality mask: new `n_biome` noise (Ctx reseed),
     `fbm2(x/384, z/384, 2)` smoothstepped to [0,1] with a plains bias,
     so plains and ranges span hundreds of voxels.
   - Plains: `fbm2(x/128, z/128, 3)` at ~0.02h amplitude — long
     wavelength, ~5-voxel relief.
   - Mountains: ridged fbm `1 - |fbm2(x/96, z/96, 4)|` at ~0.3h
     amplitude — sharp ridgelines, peaks ~5+ player heights above the
     plains.
   - `height = base + lerp(plains, mountains, mask)`; the [6, h-12]
     clamp is unchanged.
   - `sand_level` re-derived from base/plain_amp (beaches in the low
     plains only).
   - Caves, crystals, arches, spawn logic unchanged (arch flatness
     checks get easier on flatter plains; caves simply run deeper under
     mountains).
2. **Default world height 128 -> 256** (`--world-h` default in
   main.zig) for mountain headroom. Memory is ~free: columns are RLE
   runs, so cost scales with strata/detail count, not raw height (a
   512-voxel column is still 2–3 runs; see the Storage section of
   PLAN.md). The real cost is a deeper per-column cave scan at gen
   time under mountains.
3. Update PLAN.md's scale section for the new default.

Verification: `zig build test` green (the 64x96x64 "caves and arches
exist" test may need amplitude tuning if that seed's small world lands
all-mountain); headless spawn render to eyeball the plains/mountain
silhouette.

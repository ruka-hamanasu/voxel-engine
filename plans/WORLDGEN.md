# Worldgen — the minecrafty demo world

`src/gen/terrain.zig` generates the demo world: heightmap terrain with
strata, caves, crystals, and a spawn search. Everything derives
from a position-deterministic `Ctx` (seed + world height, no mutable
state), so per-chunk streamed regeneration equals whole-world gen (the
streaming pipeline itself is documented in STREAMING.md). `heightAt` is
the single pure surface function — fine columns, coarse-LOD approx
synthesis, and the spawn search all read it, so
they can never disagree about the surface.

## Heightfield (current)

- `heightAt` is a biome split (milestone 31): a continentality mask
  (`n_biome` reseed, `fbm2(x/384, z/384, 2)` through a plains-biased
  smoothstep, `t = clamp((bn + 0.1) / 0.7, 0, 1)`, `t*t*(3-2t)`)
  lerps between plains (`fbm2(x/128, z/128, 3)` at 0.02h
  amplitude — long-wavelength, ~5-voxel relief) and ridged mountains
  (`1 - |fbm2(x/96, z/96, 4)|` at 0.3h — sharp ridgelines, peaks ~5
  player heights above the plains). `n_terrain` serves both biome
  fields. `height = base + lerp(plains, mountains, mask)`,
  `clamp(.., 6, h - 12)`, base = 0.30h. Default world height is 256
  for mountain headroom; RLE columns make the extra height ~free, the
  real cost is the deeper cave scan under mountains. At seed 1337 the
  split lands ~71% plains, ~13% mountains; the mask's hundreds-of-
  voxels wavelength keeps both biomes in large contiguous patches.
- Strata per column: bedrock at y=0, stone below surface-4, dirt, grass
  on top; sand replaces dirt/grass below `sand_level = base -
  0.45*plain_amp` (beaches in the low plains only).

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

## Spawn

- Expanding square-ring search near the origin (bounded worlds clamp
  candidates inside) for a 6x6 spot with height span <= 2; falls back
  to world center (bounded) or origin (unbounded).
- Camera spawns with feet on the surface (eye 14 up), yaw pi/4.


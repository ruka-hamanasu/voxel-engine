# TODO

- Make the camera able to see the ground in front of the player's "feet"
- Investigate how we can reduce memory usage & generation time for large maps
- See if we can use multi-resolution noise algorithms to make LOD
  generation faster, making LOD an integral part of map generation

# DONE

- ~~Investigate cache performance of voxel rendering - are we accessing
  neighboring columns?~~ DONE (milestone 21): yes — pcol (L1-hot from
  the previous march step), two AO diagonals per detail cell (cheap
  for X-side faces, row-pitch strided for Z-side), light streams
  pointer-chased per lit column. Measured: misses negligible (L1
  <=0.3%, LLC ~1-3k loads/frame even at 768²), march is ALU/branch-
  bound; prefetch probe regressed, so no relayout.
- ~~Investigate deferring per-pixel computations like AO to tiled
  transpose pass & using a gbuffer~~ DONE (milestone 21): rejected.
  Shading is already per-segment (a per-pixel gbuffer is a strict
  regression); AO/light/sky only exist during the march and can't be
  deferred. Only the fb L2 round-trip remains (L1-scratch strip
  rendering, est. 4-7% at 960x540) — deferred as not worth the
  complexity while compute-bound.
- ~~Determine how much LOD is really helping~~ DONE (milestone 20):
  cascade is 2.6-3.8x at fogcut 448, lod2 ~2x on top, pays for itself
  even at the default cutoff; fog cutoff remains the cheaper lever
  for short draw distances
- Make the player seem less gigantic - ~~fog distance~~ (DONE, milestone
  24: default cutoff 96 -> 448 + lod2 on; milestone 25: N-level LOD
  cascade, --lods N + max_dist 16384 for 100-200m+ draws on big
  worlds), hill height & flat areas.
  Chunked streaming only if km-scale is still wanted after terrain
  feature scale

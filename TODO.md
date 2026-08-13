# TODO

- Investigate cache performance of voxel rendering - are we accessing
  neighboring columns?
- Investigate deferring per-pixel computations like AO to tiled
  transpose pass & using a gbuffer
- Investigate how we can reduce memory usage & generation time for large maps

# DONE

- ~~Determine how much LOD is really helping~~ DONE (milestone 20):
  cascade is 2.6-3.8x at fogcut 448, lod2 ~2x on top, pays for itself
  even at the default cutoff; fog cutoff remains the cheaper lever
  for short draw distances

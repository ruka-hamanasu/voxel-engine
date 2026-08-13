# TODO

- Determine how much LOD is really helping
- Investigate cache performance of voxel rendering - are we accessing
  neighboring columns?
- Investigate deferring per-pixel computations like AO to tiled
  transpose pass & using a gbuffer
- Investigate how we can reduce memory usage & generation time for large maps

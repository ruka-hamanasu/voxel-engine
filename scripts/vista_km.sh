#!/bin/bash
# DISTANCE.md D2: km-scale vista benches + PPMs for the clear-far fog
# curve. usage: vista_km.sh <binary> <outdir> [DEEP=1]
# Unbounded world, 960x540: spawn and aerial cams at 2 / 4 km draw
# distances. PPMs are for eyeballing the far field; the bench numbers
# track the deep-cascade cost D3's impostor will replace.
# Deeper than 4 km is gated behind DEEP=1: coarse-chunk synthesis
# regenerates 4^level fine tiles per chunk, so warmup grows
# quadratically with chain depth (8 km spawn warmup ~15 min) until
# D3/D4 land. The 100 km run is a plumbing smoke test only: --lods 2
# truncates the chain so warmup stays cheap while the march exercises
# max_dist-range rays under the clear curve.
set -e
BIN=$1
OUT=$2
mkdir -p "$OUT"
RES="--width 960 --height 540"
for dist in 2048 4096; do
  $BIN $RES --dist $dist --headless "$OUT/vista_${dist}_spawn.ppm"
  $BIN $RES --dist $dist --cam 100,100,-100,2.4 --headless "$OUT/vista_${dist}_arches.ppm"
  $BIN $RES --dist $dist --cam 0,300,0,0.79 --headless "$OUT/vista_${dist}_aerial.ppm"
  $BIN $RES --dist $dist --bench 60 2>&1 | grep bench | sed "s/^/dist $dist spawn: /"
  $BIN $RES --dist $dist --bench 60 --cam 100,100,-100,2.4 2>&1 | grep bench | sed "s/^/dist $dist arches: /"
done
if [ -n "$DEEP" ]; then
  $BIN $RES --dist 8192 --headless "$OUT/vista_8192_spawn.ppm"
  $BIN $RES --dist 8192 --bench 60 2>&1 | grep bench | sed "s/^/dist 8192 spawn: /"
fi
# 100 km plumbing smoke: a small bounded world (eager LOD pyramid, no
# per-chunk fine regen) so rays march the full 8-level chain out to
# max_dist-range t values past the world edge.
$BIN --width 480 --height 270 --world-w 512 --world-h 64 --world-d 512 --dist 100000 --headless "$OUT/vista_100km_smoke.ppm"

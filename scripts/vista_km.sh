#!/bin/bash
# DISTANCE.md D2/D3/D3.1: km-scale vista benches + PPMs. usage:
# vista_km.sh <binary> <outdir> [DEEP=1]
# Unbounded world, 960x540: spawn / vista / aerial cams at 2048,
# 4096, and 10240 vox (205 m / 410 m / ~1 km at 10 cm voxels; the
# true 10 km target is --dist 100000). At 2048/4096 an --impostor 0
# deep-cascade reference pair is rendered for the D3 seam diff budget
# (scripts/ppmdiff.py): diffs must stay confined to the horizon band
# (distant silhouettes). 10240 has no cascade reference — the
# quadratic coarse-chunk synthesis warmup the impostor replaced
# (8 km vox spawn ~15 min) is gated behind DEEP=1 as the 8192-vox
# reference. The 100000-vox run is a plumbing smoke test only: a
# small bounded world, march exercised to max_dist-range t values
# past the world edge.
set -e
BIN=$1
OUT=$2
mkdir -p "$OUT"
RES="--width 960 --height 540"
for dist in 2048 4096; do
  for cam in "spawn:" "vista:--cam 100,100,-100,2.4" "aerial:--cam 0,300,0,0.79"; do
    name=${cam%%:*}; args=${cam#*:}
    $BIN $RES --dist $dist $args --headless "$OUT/vista_${dist}_${name}_imp.ppm"
    $BIN $RES --dist $dist --impostor 0 $args --headless "$OUT/vista_${dist}_${name}_ref.ppm"
    python3 "$(dirname "$0")/ppmdiff.py" "$OUT/vista_${dist}_${name}_imp.ppm" "$OUT/vista_${dist}_${name}_ref.ppm"
  done
  $BIN $RES --dist $dist --bench 60 2>&1 | grep bench | sed "s/^/dist $dist spawn imp: /"
  $BIN $RES --dist $dist --impostor 0 --bench 60 2>&1 | grep bench | sed "s/^/dist $dist spawn ref: /"
done
$BIN $RES --dist 10240 --headless "$OUT/vista_10240_spawn.ppm"
$BIN $RES --dist 10240 --cam 0,300,0,0.79 --headless "$OUT/vista_10240_aerial.ppm"
$BIN $RES --dist 10240 --bench 60 2>&1 | grep bench | sed "s/^/dist 10240 spawn imp: /"
if [ -n "$DEEP" ]; then
  # Deep-cascade reference at 8 km (quadratic warmup, ~15 min).
  $BIN $RES --dist 8192 --impostor 0 --headless "$OUT/vista_8192_spawn_ref.ppm"
  $BIN $RES --dist 8192 --impostor 0 --bench 60 2>&1 | grep bench | sed "s/^/dist 8192 spawn ref: /"
  $BIN $RES --dist 8192 --headless "$OUT/vista_8192_spawn_imp.ppm"
  $BIN $RES --dist 8192 --bench 60 2>&1 | grep bench | sed "s/^/dist 8192 spawn imp: /"
  python3 "$(dirname "$0")/ppmdiff.py" "$OUT/vista_8192_spawn_imp.ppm" "$OUT/vista_8192_spawn_ref.ppm"
fi
# 100 km plumbing smoke: a small bounded world (eager LOD pyramid, no
# per-chunk fine regen); the impostor clips at the world bounds.
$BIN --width 480 --height 270 --world-w 512 --world-h 64 --world-d 512 --dist 100000 --headless "$OUT/vista_100km_smoke.ppm"

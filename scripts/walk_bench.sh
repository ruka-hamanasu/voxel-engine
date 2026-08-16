#!/bin/bash
# STREAMING.md phase 3: walk-across-chunk-boundaries bench + the
# missing "worst" fixed view for the m28 unbounded A/B record.
# usage: walk_bench.sh <binary>
# The walk lerps the camera from spawn 320 voxels along +x (5 fine
# chunk boundaries) over 240 frames with the default load budget.
BIN=$1
RES="--width 960 --height 540"
for n in 1 2 3; do
  $BIN $RES --bench 240 --cam-to 320,50,0,0 2>&1 | grep bench | sed "s/^/walk run$n: /"
done
# Fixed views (unbounded): spawn + worst (heaviest view found).
# m32: the old worst (-150,55,-150,5.5) is underground since the m31
# biome-split terrain; 100,100,-100,2.4 is a heavy arches vista.
for n in 1 2 3; do
  $BIN $RES --bench 500 2>&1 | grep bench | sed "s/^/spawn run$n: /"
  $BIN $RES --bench 500 --cam 100,100,-100,2.4 2>&1 | grep bench | sed "s/^/worst run$n: /"
done

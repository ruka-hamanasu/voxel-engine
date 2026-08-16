#!/bin/bash
# usage: views_stream_lod0.sh <binary> <outdir> -- regression set:
# 37 views l0f0 + 37 views default + 4 cave views default.
# --fogcut 96 pins the pre-milestone-24 march limit so --lod 0 stays
# byte-identical across the default fog cutoff change.
# Current baselines: views_m31_stream_lod0 (l0f0), views_m32_stream_lod0 (def).
set -e
BIN=$1
OUT=$2
mkdir -p "$OUT"
i=0
for mode in "--no-light --fog 0 --detail 48" ""; do
  tag=l0f0
  [ -z "$mode" ] && tag=def
  $BIN $mode --lod 0 --fogcut 96 --headless "$OUT/v00_spawn_${tag}.ppm"
  i=1
  for x in 48 192 336; do
    for z in 48 192 336; do
      for y in 90 130 180; do
        case $((i % 4)) in
          0) yaw=0;; 1) yaw=1.57;; 2) yaw=3.14;; 3) yaw=4.71;;
        esac
        printf -v n "%02d" $i
        $BIN $mode --lod 0 --fogcut 96 --headless "$OUT/v${n}_x${x}y${y}z${z}_${tag}.ppm" --cam $x.5,$y.0,$z.5,$yaw
        i=$((i+1))
      done
    done
  done
  for x in 96 192 288; do
    for z in 96 192 288; do
      printf -v n "%02d" $i
      $BIN $mode --lod 0 --fogcut 96 --headless "$OUT/v${n}_aerial_x${x}z${z}_${tag}.ppm" --cam $x.5,160.0,$z.5,0.79
      i=$((i+1))
    done
  done
done
$BIN --lod 0 --fogcut 96 --headless "$OUT/cave1_def.ppm" --cam -55.5,38.0,138.5,3.14
$BIN --lod 0 --fogcut 96 --headless "$OUT/cave2_def.ppm" --cam -55.5,38.0,138.5,1.57
$BIN --lod 0 --fogcut 96 --headless "$OUT/cave3_def.ppm" --cam -55.5,23.0,179.5,0.32
$BIN --lod 0 --fogcut 96 --headless "$OUT/cave4_def.ppm" --cam -55.5,23.0,179.5,2.5

#!/bin/bash
# usage: views_stream.sh <binary> <outdir> -- regression set:
# 37 views l0f0 + 37 views default + 4 cave views default.
# l0f0 pins the milestone-23 render defaults so the identity gate
# stays byte-identical across the milestone-24 default changes.
# Current baselines: views_m31_stream (l0f0), views_m32_stream (def).
set -e
BIN=$1
OUT=$2
mkdir -p "$OUT"
i=0
for mode in "--no-light --fog 0 --fogcut 96 --lod 64 --lod2 0 --detail 48" ""; do
  tag=l0f0
  [ -z "$mode" ] && tag=def
  $BIN $mode --headless "$OUT/v00_spawn_${tag}.ppm"
  i=1
  for x in 48 192 336; do
    for z in 48 192 336; do
      for y in 90 130 180; do
        case $((i % 4)) in
          0) yaw=0;; 1) yaw=1.57;; 2) yaw=3.14;; 3) yaw=4.71;;
        esac
        printf -v n "%02d" $i
        $BIN $mode --headless "$OUT/v${n}_x${x}y${y}z${z}_${tag}.ppm" --cam $x.5,$y.0,$z.5,$yaw
        i=$((i+1))
      done
    done
  done
  for x in 96 192 288; do
    for z in 96 192 288; do
      printf -v n "%02d" $i
      $BIN $mode --headless "$OUT/v${n}_aerial_x${x}z${z}_${tag}.ppm" --cam $x.5,160.0,$z.5,0.79
      i=$((i+1))
    done
  done
done
$BIN --headless "$OUT/cave1_def.ppm" --cam -55.5,38.0,138.5,3.14
$BIN --headless "$OUT/cave2_def.ppm" --cam -55.5,38.0,138.5,1.57
$BIN --headless "$OUT/cave3_def.ppm" --cam -55.5,23.0,179.5,0.32
$BIN --headless "$OUT/cave4_def.ppm" --cam -55.5,23.0,179.5,2.5

#!/bin/bash
# usage: views_lod0.sh <binary> <outdir> -- regression set:
# 37 views l0f0 + 37 views default + 4 cave views default.
# --fogcut 96 pins the pre-milestone-24 march limit so --lod 0 stays
# byte-identical across the default fog cutoff change.
# Current baselines: views_m37_lod0.
set -e
BIN=$1
OUT=$2
mkdir -p "$OUT"
i=0
for mode in "--no-light --fog 0 --detail 48" ""; do
  tag=l0f0
  [ -z "$mode" ] && tag=def
  $BIN $mode --world-w 384 --world-d 384 --world-h 128 --lod 0 --fogcut 96 --headless "$OUT/v00_spawn_${tag}.ppm"
  i=1
  for x in 48 192 336; do
    for z in 48 192 336; do
      for y in 44 70 100; do
        case $((i % 4)) in
          0) yaw=0;; 1) yaw=1.57;; 2) yaw=3.14;; 3) yaw=4.71;;
        esac
        printf -v n "%02d" $i
        $BIN $mode --world-w 384 --world-d 384 --world-h 128 --lod 0 --fogcut 96 --headless "$OUT/v${n}_x${x}y${y}z${z}_${tag}.ppm" --cam $x.5,$y.0,$z.5,$yaw
        i=$((i+1))
      done
    done
  done
  for x in 96 192 288; do
    for z in 96 192 288; do
      printf -v n "%02d" $i
      $BIN $mode --world-w 384 --world-d 384 --world-h 128 --lod 0 --fogcut 96 --headless "$OUT/v${n}_aerial_x${x}z${z}_${tag}.ppm" --cam $x.5,90.0,$z.5,0.79
      i=$((i+1))
    done
  done
done
$BIN --world-w 384 --world-d 384 --world-h 128 --lod 0 --fogcut 96 --headless "$OUT/cave1_def.ppm" --cam 10.5,28.0,84.5,3.14
$BIN --world-w 384 --world-d 384 --world-h 128 --lod 0 --fogcut 96 --headless "$OUT/cave2_def.ppm" --cam 10.5,28.0,84.5,0.0
$BIN --world-w 384 --world-d 384 --world-h 128 --lod 0 --fogcut 96 --headless "$OUT/cave3_def.ppm" --cam 2.5,21.0,316.5,0.32
$BIN --world-w 384 --world-d 384 --world-h 128 --lod 0 --fogcut 96 --headless "$OUT/cave4_def.ppm" --cam 2.5,21.0,316.5,3.46

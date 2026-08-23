#!/bin/bash
# m20: LOD value benchmark, 768x1024x768 world, 960x540
BIN=zig-out/bin/voxel_engine
WORLD="--world-w 768 --world-h 1024 --world-d 768"
RES="--width 960 --height 540"
declare -A CAMS=(
  [vista]="32,520,32,0.79"
  [ground]="120,340,120,0.79"
  [aerial]="384,540,384,2.36"
  [cave]="384,330,700,4.71"
)
declare -A CFGS=(
  [A_nolod_long]="--lod 0 --fogcut 448"
  [B_lod1_long]="--lod 96 --lods 1 --fogcut 448"
  # R3 dropped --lod2: the {96,192} chain is no longer expressible, so
  # C now benches the doubled {96,288} chain.
  [C_lod2_long]="--lod 96 --lods 2 --fogcut 448"
  [D_nolod_short]="--lod 0 --fogcut 96"
  [E_default]="--fogcut 96"
)
for view in vista ground aerial cave; do
  for cfg in A_nolod_long B_lod1_long C_lod2_long D_nolod_short E_default; do
    n=500
    [ "$cfg" = "A_nolod_long" ] && n=200
    out=$($BIN $WORLD $RES ${CFGS[$cfg]} --cam ${CAMS[$view]} --bench $n 2>&1 | grep bench)
    echo "$view $cfg n=$n $out"
  done
done

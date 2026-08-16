#!/bin/bash
# usage: stacksample.sh <outfile> -- <command...>
OUT=$1; shift; shift
"$@" & PID=$!
> "$OUT"
N=0
while kill -0 $PID 2>/dev/null && [ $N -lt 1500 ]; do
  gdb -p $PID -batch -ex "bt 8" 2>/dev/null | grep '^#' >> "$OUT"
  echo "---" >> "$OUT"
  N=$((N+1))
done
wait $PID
echo "samples: $N"

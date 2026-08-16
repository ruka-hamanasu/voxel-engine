#!/bin/bash
# STREAMING.md phase 3: reproducible peak-memory measurement.
# usage: mem.sh <binary> [extra args...]
# Runs the binary (default: unbounded warm-up + 60 bench frames),
# polls /proc/<pid>/status VmHWM, reports the peak in MB.
BIN=$1; shift
"$BIN" "$@" --bench 60 &
pid=$!
peak=0
while kill -0 $pid 2>/dev/null; do
  hwm=$(awk '/VmHWM/{print $2}' /proc/$pid/status 2>/dev/null)
  [ -n "$hwm" ] && [ "$hwm" -gt "$peak" ] && peak=$hwm
  sleep 0.05
done
wait $pid
awk -v p="$peak" 'BEGIN{printf "peak VmHWM: %.1f MB\n", p/1024}'

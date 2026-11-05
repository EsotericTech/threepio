#!/usr/bin/env bash
# tool/run_capped.sh <wall_seconds> <max_rss_mb> <command…>
# Runs the command and polls its whole process tree once per second. Kills the tree
# (SIGKILL) when the summed resident memory exceeds the cap (exit 137, prints
# "KILLED: memory …") or the wall-clock cap is reached (exit 124, prints "KILLED: time …").
# Otherwise exits with the command's own status.
set -u
wall="$1"; cap_mb="$2"; shift 2
"$@" < /dev/null &
root=$!
tree() {                                   # $root and all of its descendants
  local all="$root" frontier="$root" kids
  while [ -n "$frontier" ]; do
    kids="$(for p in $frontier; do pgrep -P "$p" 2>/dev/null; done | tr '\n' ' ')"
    all="$all $kids"; frontier="$kids"
  done
  echo $all
}
kill_tree() { kill -9 $(tree) 2>/dev/null; wait "$root" 2>/dev/null; }
start=$SECONDS
while kill -0 "$root" 2>/dev/null; do
  pids="$(tree | tr ' ' ',')"
  rss_kb="$(ps -o rss= -p "$pids" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  rss_mb=$((rss_kb / 1024))
  if [ "$rss_mb" -gt "$cap_mb" ]; then
    kill_tree; echo "KILLED: memory (${rss_mb} MB > ${cap_mb} MB cap)"; exit 137
  fi
  if [ $((SECONDS - start)) -ge "$wall" ]; then
    kill_tree; echo "KILLED: time (${wall} s cap)"; exit 124
  fi
  sleep 1
done
wait "$root"

#!/usr/bin/env bash
# tool/test_shards.sh — sequential test shards; one dart process, one suite at a time.
# Per shard: 300 s wall cap and 4 GB resident-memory cap over the whole process tree
# (tool/run_capped.sh); a shard that needs more than 200 s must be split by sub-directory.
set -euo pipefail
cd "$(dirname "$0")/.."
for shard in "$@"; do
  echo "== shard: $shard"
  t0=$SECONDS
  tool/run_capped.sh 300 4096 dart test -j 1 --timeout 30s --exclude-tags integration \
    --reporter expanded --no-color "$shard" || { echo "SHARD FAILED: $shard"; exit 1; }
  took=$((SECONDS - t0))
  echo "== shard done: $shard (${took} s)"
  if [ "$took" -gt 200 ]; then
    echo "SHARD TOO SLOW: $shard took ${took} s (> 200 s); replace it in the gate command by its sub-directories"
    exit 1
  fi
done
echo "ALL SHARDS PASSED"

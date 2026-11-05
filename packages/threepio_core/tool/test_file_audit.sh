#!/usr/bin/env bash
# tool/test_file_audit.sh [files…] — run each test file alone and print
# file<TAB>result<TAB>seconds<TAB>maxRssMB. Each run has a 20 s wall cap and a 4 GB
# resident-memory cap enforced by tool/run_capped.sh (VM heap flags do not bound a runaway
# synchronous loop). result is one of: "+N: All tests passed!", "+N -M: Some tests failed.",
# "KILLED: memory", "KILLED: time", "DID NOT FINISH (rc=…)".
set -uo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else find test -name '*_test.dart' ! -path 'test/integration/*' ! -name 'gemini_integration_test.dart' | sort; fi |
while IFS= read -r f; do
  log="$(mktemp)"
  /usr/bin/time -l tool/run_capped.sh 20 4096 dart test -j 1 --timeout 10s --exclude-tags integration \
    --reporter expanded --no-color "$f" > "$log" 2>&1 < /dev/null
  rc=$?
  res="$(grep -m1 -oE '^KILLED: (memory|time)' "$log" || true)"
  [ -n "$res" ] || res="$(grep -E 'All tests passed|Some tests failed|No tests ran' "$log" | tail -1 | sed -E 's/^[0-9:]+ //')"
  [ -n "$res" ] || res="DID NOT FINISH (rc=$rc)"
  secs="$(grep -E '^[[:space:]]+[0-9.]+ real' "$log" | awk '{print $1}')"
  rss="$(grep 'maximum resident set size' "$log" | awk '{printf "%d", $1/1048576}')"
  printf '%s\t%s\t%s\t%s\n' "$f" "$res" "$secs" "$rss"
  rm -f "$log"
done

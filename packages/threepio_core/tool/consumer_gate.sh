#!/usr/bin/env bash
# tool/consumer_gate.sh [--record-baseline | --tests]
# Analyze a consumer app against this checkout through a temporary, uncommitted
# pubspec_overrides.yaml. Every file the gate changes in the app is restored
# byte-for-byte on exit, pass or fail.
#   APP=/abs/path/to/app   (default: sourcery_main)
# Works for git-pinned and path-dependent apps alike: dependency_overrides replaces the
# source of threepio_core for the whole dependency graph.
#
# The gate measures its own baseline in every run: it analyzes the app first as it is
# resolved (no override), then with the override, and fails only on analyzer errors that
# are there with the override and not without it. The app is under development and can
# have errors of its own at any moment; those are printed and do not fail the gate. If
# the two runs differ, the app is analyzed once more after the override is gone, so that
# an error the app's owner typed in between the two runs is not blamed on this checkout.
# The files under tool/consumer_baseline/ (--record-baseline) are kept for reference
# and no longer decide the gate.
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-/Users/gp/FlutterProjects/sourcery_app/apps/sourcery_main}"
NAME="$(basename "$APP")"
BASE="$PKG/tool/consumer_baseline/$NAME.errors.txt"
DIRS="lib"; [ ! -d "$APP/test" ] || DIRS="lib test"
TESTS="${CONSUMER_TESTS:-}"
if [ -z "$TESTS" ] && [ "$NAME" = sourcery_main ]; then
  TESTS="test/core/services/kortney test/core/graph test/core/services/processing/threepio"
fi
TMP="$(mktemp -d)"
errors() { grep -E '^ +error • ' "$1" | sed -E 's/:[0-9]+:[0-9]+ • / • /' | sort -u || true; }
[ -f "$APP/.dart_tool/package_config.json" ] || { echo "$NAME is not resolved; the user must run flutter pub get there first"; exit 2; }

if [ "${1:-}" = "--record-baseline" ]; then      # the app as resolved today; no override; nothing written to it
  mkdir -p "$(dirname "$BASE")"
  (cd "$APP" && flutter analyze --no-pub $DIRS > "$TMP/analyze.txt" 2>&1) || true
  errors "$TMP/analyze.txt" > "$BASE"
  if [ -n "$TESTS" ]; then
    (cd "$APP" && flutter test --no-pub -j 1 $TESTS > "$TMP/tests.txt" 2>&1) || true
    tail -1 "$TMP/tests.txt" > "$PKG/tool/consumer_baseline/$NAME.tests.txt"
  fi
  echo "baseline for $NAME: $(wc -l < "$BASE") analyzer errors"
  exit 0
fi

[ ! -e "$APP/pubspec_overrides.yaml" ] || { echo "refusing: $APP/pubspec_overrides.yaml exists"; exit 2; }

# 1. The app as it is right now, without the override: this run's baseline.
(cd "$APP" && flutter analyze --no-pub $DIRS > "$TMP/analyze_before.txt" 2>&1) || true
errors "$TMP/analyze_before.txt" > "$TMP/before.txt"

# 2. The same app against this checkout.
[ ! -e "$APP/pubspec_overrides.yaml" ] || { echo "refusing: $APP/pubspec_overrides.yaml exists"; exit 2; }
SAVED="pubspec.lock .dart_tool/package_config.json .dart_tool/package_graph.json .flutter-plugins-dependencies"
for f in $SAVED; do
  if [ -f "$APP/$f" ]; then mkdir -p "$TMP/saved/$(dirname "$f")"; cp "$APP/$f" "$TMP/saved/$f"; fi
done
RESTORED=0
restore() {
  [ "$RESTORED" = 0 ] || return 0
  RESTORED=1
  rm -f "$APP/pubspec_overrides.yaml"
  for f in $SAVED; do
    if [ -f "$TMP/saved/$f" ]; then cp "$TMP/saved/$f" "$APP/$f"; fi
  done
}
trap restore EXIT
printf 'dependency_overrides:\n  threepio_core:\n    path: %s\n' "$PKG" > "$APP/pubspec_overrides.yaml"
(cd "$APP" && flutter pub get > /dev/null)
(cd "$APP" && flutter analyze --no-pub $DIRS > "$TMP/analyze.txt" 2>&1) || true
errors "$TMP/analyze.txt" > "$TMP/errors.txt"
TESTS_RC=0
if [ "${1:-}" = "--tests" ] && [ -n "$TESTS" ]; then
  (cd "$APP" && flutter test --no-pub -j 1 $TESTS) || TESTS_RC=$?
fi
restore

# 3. Errors that only exist with the override.
comm -13 "$TMP/before.txt" "$TMP/errors.txt" > "$TMP/new.txt"
if [ -s "$TMP/new.txt" ]; then
  # The app may have changed between the two runs: look once more without the override.
  (cd "$APP" && flutter analyze --no-pub $DIRS > "$TMP/analyze_after.txt" 2>&1) || true
  errors "$TMP/analyze_after.txt" > "$TMP/after.txt"
  comm -23 "$TMP/new.txt" "$TMP/after.txt" > "$TMP/introduced.txt"
  mv "$TMP/introduced.txt" "$TMP/new.txt"
fi
OWN="$(wc -l < "$TMP/before.txt" | tr -d ' ')"
if [ "$OWN" != 0 ]; then
  echo "$NAME has $OWN analyzer error(s) of its own (without the override; not counted):"
  cat "$TMP/before.txt"
fi
if [ -s "$TMP/new.txt" ]; then echo "NEW CONSUMER ERRORS ($NAME):"; cat "$TMP/new.txt"; exit 1; fi
if [ "$TESTS_RC" != 0 ]; then echo "CONSUMER TESTS FAILED ($NAME)"; exit 1; fi
echo "CONSUMER GATE PASSED ($NAME)"

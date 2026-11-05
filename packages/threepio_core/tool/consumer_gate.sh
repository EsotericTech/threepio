#!/usr/bin/env bash
# tool/consumer_gate.sh [--record-baseline | --tests]
# Analyze a consumer app against this checkout through a temporary, uncommitted
# pubspec_overrides.yaml. Every file the gate changes in the app is restored
# byte-for-byte on exit, pass or fail.
#   APP=/abs/path/to/app   (default: sourcery_main)
# Works for git-pinned and path-dependent apps alike: dependency_overrides replaces the
# source of threepio_core for the whole dependency graph.
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

[ -f "$BASE" ] || { echo "no baseline for $NAME; run --record-baseline first"; exit 2; }
[ ! -e "$APP/pubspec_overrides.yaml" ] || { echo "refusing: $APP/pubspec_overrides.yaml exists"; exit 2; }
SAVED="pubspec.lock .dart_tool/package_config.json .dart_tool/package_graph.json .flutter-plugins-dependencies"
for f in $SAVED; do
  if [ -f "$APP/$f" ]; then mkdir -p "$TMP/saved/$(dirname "$f")"; cp "$APP/$f" "$TMP/saved/$f"; fi
done
restore() {
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
comm -13 "$BASE" "$TMP/errors.txt" > "$TMP/new.txt"
if [ -s "$TMP/new.txt" ]; then echo "NEW CONSUMER ERRORS ($NAME):"; cat "$TMP/new.txt"; exit 1; fi
if [ "${1:-}" = "--tests" ] && [ -n "$TESTS" ]; then (cd "$APP" && flutter test --no-pub -j 1 $TESTS); fi
echo "CONSUMER GATE PASSED ($NAME)"

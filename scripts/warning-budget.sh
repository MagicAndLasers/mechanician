#!/usr/bin/env bash
# A ratchet on Swift compiler warnings in our own sources.
#
# The compiler is already the best linter this project has: it found a `where` clause that guarded
# only half a `case`, dead bindings, and a pile of API deprecations. Nothing was gating on it, so
# the warnings scrolled past every build and new ones were indistinguishable from old ones.
#
# This does not demand zero. It demands "no more than last time", so the number can only fall. When
# you fix warnings, lower the baseline in the same commit — the script prints the new number.
#
# Warnings are only emitted for files the compiler actually recompiles, so a build that compiles
# nothing reports nothing. Dependencies and the SDK are excluded: their warnings are not ours.
#
# Pass `--log FILE` to count an existing build log instead of building. check.sh does that with the
# output of its Swift test run, so the module is compiled ONCE per check. Compiling it a second time
# just to read diagnostics doubled the slowest step in CI and was enough to make the runner drop the
# job partway through, with no diagnostic to show for it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_FILE="$REPO/scripts/warning-budget.txt"
SOURCES="$REPO/app/Sources"

[ -f "$BASELINE_FILE" ] || { echo "!! missing $BASELINE_FILE" >&2; exit 1; }
BASELINE="$(tr -d '[:space:]' < "$BASELINE_FILE")"

# Only when this script does its own build. Reading a caller's log, the toolchain is whatever
# produced that log, and announcing a different one would be a lie.
#
# Building standalone, measure what developers actually see: dev.sh picks the newest installed Xcode
# for its SDK, and a beta toolchain emits diagnostics the stable one does not — four `weak` capture
# warnings reached a dev build while this gate, running the default toolchain, reported a clean two.
if [ "${1:-}" = "--log" ]; then
  :
elif [ -z "${MECHANICIAN_DEVELOPER_DIR:-}" ]; then
  best_dev=""; best_major=0
  for app in /Applications/Xcode*.app; do
    sdkdir="$app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs"
    [ -d "$sdkdir" ] || continue
    for sdk in "$sdkdir"/MacOSX*.sdk; do
      ver="$(basename "$sdk")"; ver="${ver#MacOSX}"; ver="${ver%.sdk}"
      major="${ver%%.*}"
      case "$major" in ''|*[!0-9]*) continue;; esac
      if [ "$major" -gt "$best_major" ]; then best_major="$major"; best_dev="$app/Contents/Developer"; fi
    done
  done
  [ -n "$best_dev" ] && export DEVELOPER_DIR="$best_dev"
else
  export DEVELOPER_DIR="$MECHANICIAN_DEVELOPER_DIR"
fi
if [ "${1:-}" = "--log" ]; then
  echo "    counting diagnostics from the build above"
else
  echo "    toolchain: ${DEVELOPER_DIR:-default}"
fi

if [ "${1:-}" = "--log" ]; then
  [ -f "${2:-}" ] || { echo "!! no such build log: ${2:-}" >&2; exit 1; }
  LOG="$2"
  CLEANUP_LOG=0
else
  LOG="$(mktemp "${TMPDIR:-/tmp}/mechanician-warnings.XXXXXX")"
  CLEANUP_LOG=1
  # Touch our sources so the module is recompiled and re-emits its diagnostics; an incremental
  # build would otherwise report zero simply because nothing was compiled.
  if [ -d "$REPO/app/.build" ]; then
    find "$SOURCES" -name '*.swift' -exec touch {} +
  fi
  ( cd "$REPO/app" && swift build --arch arm64 ) > "$LOG" 2>&1 || {
    echo "!! build failed" >&2
    tail -200 "$LOG" >&2
    exit 1
  }
fi
trap '[ "$CLEANUP_LOG" = 1 ] && rm -f "$LOG"; rm -f "$LOG.plain"' EXIT

# One line per distinct site. A single warning is reported once per file that triggers it, and the
# compiler repeats each diagnostic with source context, so unique file:line:col is the honest count.
# Strip ANSI colour first. The beta toolchain colourizes diagnostics even when stdout is a pipe,
# which puts an escape sequence between the location and the word "warning" — a plain `: warning: `
# pattern silently matches nothing there, and this gate reported a clean build while dev.sh was
# printing four. Match against decoloured text so the count does not depend on the terminal.
PLAIN="$LOG.plain"
sed -E $'s/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" > "$PLAIN"

# `|| true` on every grep: under `set -o pipefail` a grep that matches nothing exits 1, so a
# genuinely clean build would fail this gate instead of passing it.
COUNT="$( { grep -E "^${SOURCES}/.*: warning: " "$PLAIN" || true; } \
  | sed -E 's/^([^:]+:[0-9]+:[0-9]+): warning: .*/\1/' \
  | sort -u | wc -l | tr -d '[:space:]')"

if [ "$COUNT" -gt "$BASELINE" ]; then
  echo "!! Swift warnings rose: $COUNT (budget $BASELINE)" >&2
  echo "   new or changed sites:" >&2
  { grep -E "^${SOURCES}/.*: warning: " "$PLAIN" || true; } \
    | sed -E "s|^${SOURCES}/Mechanician/||" | sort -u | sed 's/^/     /' >&2
  exit 1
fi

if [ "$COUNT" -lt "$BASELINE" ]; then
  echo "    $COUNT warnings — below the budget of $BASELINE."
  echo "    Lower it in this commit:  echo $COUNT > scripts/warning-budget.txt"
else
  echo "    $COUNT warnings (at the budget)"
fi

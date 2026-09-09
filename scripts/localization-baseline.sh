#!/bin/bash
# Count the user-facing strings that are not yet translatable, and refuse an increase.
#
# Localization readiness is a long program: ~922 literal sites become translatable the moment a
# String Catalog exists, because SwiftUI's literal initialisers already take `LocalizedStringKey`,
# while ~693 computed sites need per-site judgement about whether they are prose or user data.
# Without a counter, that backlog is invisible and every new feature quietly adds to it.
#
# This is a ratchet, not a gate: the baseline may only go down. It is deliberately a count rather
# than a per-string check, because the interesting question is "is this getting better or worse",
# and a per-string allowlist would need editing on every legitimate change.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_FILE="$REPO/scripts/localization-baseline.txt"
SOURCES="$REPO/app/Sources/Mechanician"

# A `Text(someExpression)` is the `String` overload: verbatim, never localized. Some of these are
# correct (a conversation title must never be translated) and some are prose that should be a
# catalogue entry. The count cannot tell them apart, which is exactly why it is a ratchet on the
# total rather than a claim about any one site.
computed=$(grep -rhoE 'Text\([a-zA-Z_][a-zA-Z0-9_.]*\)' --include="*.swift" "$SOURCES" | wc -l | tr -d ' ')

# AppKit surfaces have no automatic localization at all: an alert or menu title set from a Swift
# literal is untranslatable until it goes through `String(localized:)`.
appkit=$(grep -rhoE '(messageText|informativeText)[[:space:]]*=[[:space:]]*"' \
  --include="*.swift" "$SOURCES" | wc -l | tr -d ' ')

total=$((computed + appkit))

if [ "${1:-}" = "--write" ]; then
  echo "$total" > "$BASELINE_FILE"
  echo "==> localization baseline written: $total"
  exit 0
fi

[ -f "$BASELINE_FILE" ] || { echo "!! missing $BASELINE_FILE; run $0 --write"; exit 1; }
baseline=$(tr -d '[:space:]' < "$BASELINE_FILE")

echo "==> localization readiness"
echo "    not yet translatable: $total ($computed computed, $appkit AppKit)  baseline $baseline"

if [ "$total" -gt "$baseline" ]; then
  echo "!! $((total - baseline)) new user-facing string(s) that cannot be translated."
  echo "   Use a literal so SwiftUI localizes it, String(localized:) for AppKit, or"
  echo "   Text(verbatim:) when the value is user data and must never be translated."
  echo "   If this is genuinely user data, raise the baseline: $0 --write"
  exit 1
fi

if [ "$total" -lt "$baseline" ]; then
  echo "    $((baseline - total)) fewer than the baseline. Lock it in: $0 --write"
fi

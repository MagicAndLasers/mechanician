#!/usr/bin/env bash
# Compile the String Catalog into `.lproj` bundles inside an assembled .app.
#
# Usage: compile-string-catalog.sh <path-to-.app> [--pseudo]
#
# Why this is a build step and not SwiftPM resources: this app is assembled by hand, and SwiftUI's
# literal lookup goes through `Bundle.main`. SwiftPM does not compile `.xcstrings` at all — it
# copies the raw catalogue into a resource bundle, where it is both uncompiled and not `Bundle.main`.
# `xcstringstool` is Xcode's own compiler for this format, so the OUTPUT here is byte-for-byte what
# an Xcode app target produces: `en.lproj/Localizable.strings` plus a `.stringsdict` for plurals.
#
# Shared by build-app.sh (release/dogfood) and dev.sh. It is one script rather than two copies on
# purpose: the owner-only-directory rule in this codebase was hand-written three times, two copies
# were taught to repair, and the third — the one everybody believed was unreachable — is what
# stranded two machines. A build rule that must hold for every bundle lives in exactly one place.
#
# `--pseudo` adds `en-XA`, a generated pseudo-locale. It is a test instrument, not a language: an
# untransformed string on screen under `en-XA` is an unlocalized string, which is the only way to
# check localization readiness without a translator. Release builds never carry it.
set -euo pipefail

APP="${1:?usage: compile-string-catalog.sh <path-to-.app> [--pseudo]}"
PSEUDO=""
[ "${2:-}" = "--pseudo" ] && PSEUDO=1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRING_CATALOG="$REPO/app/Resources/Localizable.xcstrings"

[ -f "$STRING_CATALOG" ] || { echo "!! no string catalogue at $STRING_CATALOG"; exit 1; }
[ -d "$APP/Contents/Resources" ] || { echo "!! not an assembled bundle: $APP"; exit 1; }

echo "==> compiling string catalogue"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mechanician-strings.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

SOURCE_CATALOG="$STRING_CATALOG"
if [ -n "$PSEUDO" ]; then
  # The staged copy MUST keep the name `Localizable.xcstrings`. `xcstringstool` names its output
  # table after the INPUT FILENAME, so compiling `pseudo.xcstrings` yields `pseudo.strings` — a
  # table nothing looks up, since SwiftUI and `String(localized:)` both default to `Localizable`.
  # Every lookup then silently falls through to the source language and the build looks unlocalized.
  # That cost a full debugging session and was misdiagnosed as a platform limitation.
  "$REPO/scripts/make-pseudo-locale.py" "$STRING_CATALOG" "$STAGE/Localizable.xcstrings" \
    || { echo "!! pseudo-locale generation failed"; exit 1; }
  SOURCE_CATALOG="$STAGE/Localizable.xcstrings"
fi

xcrun xcstringstool compile "$SOURCE_CATALOG" -o "$STAGE" \
  || { echo "!! string catalogue failed to compile"; exit 1; }

# A compile that produces no `.lproj` is a silent no-op that ships an unlocalized app while
# reporting success. Fail instead.
shopt -s nullglob
lprojs=("$STAGE"/*.lproj)
[ "${#lprojs[@]}" -gt 0 ] || { echo "!! string catalogue compiled to no .lproj bundles"; exit 1; }

for lproj in "${lprojs[@]}"; do
  rm -rf "$APP/Contents/Resources/$(basename "$lproj")"
  cp -R "$lproj" "$APP/Contents/Resources/"
  echo "    $(basename "$lproj"): $(ls "$lproj" | tr '\n' ' ')"
done
chmod -R a+r "$APP/Contents/Resources/"*.lproj 2>/dev/null || true

# Every plural key in the source must reach the installed `.stringsdict`.
#
# The singular of a counted string exists ONLY in the catalogue — the call sites say
# `String(localized: "Delete \(count) Conversations")` and no longer carry a `count == 1` branch.
# So a build that silently shipped without these would not fail to compile; it would put
# "Undo Delete 1 Conversations" in the Edit menu. Fail here instead.
python3 - "$STRING_CATALOG" "$APP/Contents/Resources/en.lproj/Localizable.stringsdict" <<'PY' || exit 1
import json, plistlib, sys
source, compiled = sys.argv[1], sys.argv[2]
with open(source) as handle:
    catalog = json.load(handle)
expected = sorted(
    key for key, entry in catalog["strings"].items()
    if "plural" in entry.get("localizations", {}).get("en", {}).get("variations", {})
)
if not expected:
    sys.exit(0)
try:
    with open(compiled, "rb") as handle:
        installed = plistlib.load(handle)
except FileNotFoundError:
    sys.exit(f"!! {len(expected)} plural(s) declared but no en.lproj/Localizable.stringsdict built")
missing = [key for key in expected if key not in installed]
if missing:
    sys.exit("!! plural(s) missing from the built catalogue: " + ", ".join(missing))
print(f"    plurals verified in en.lproj: {len(expected)}")
PY

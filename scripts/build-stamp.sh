#!/bin/bash
# One line naming the code inside a built bundle.
#
# `CFBundleVersion` does not move on a local build — only `release.sh` bumps it — so two apps a
# commit apart both report the same number, and "on the new release" cannot be verified by anyone.
# That ambiguity cost three debugging sessions in one day: a fix that was not installed was trusted
# twice, and a bug that was already fixed was diagnosed again.
#
# Nothing new has to be recorded to fix it. `Contents/Resources/BuildProvenance.json` is written
# before signing and has carried `sourceCommit` and a hash of the uncommitted diff since it was
# introduced. It was simply never printed. This prints it.
#
# The diff hash is what makes the answer honest rather than merely present. Build, edit, build again
# and both apps carry one commit while containing different code, which is precisely the case that
# misled us. Hashing an empty diff yields a known constant, so a clean tree is recognisable without
# anything having to write a flag.
set -euo pipefail

APP="${1:?usage: build-stamp.sh <path to .app>}"
PLIST="$APP/Contents/Info.plist"
PROVENANCE="$APP/Contents/Resources/BuildProvenance.json"
CLEAN_TREE_DIFF="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

[ -d "$APP" ] || { echo "!! no bundle at $APP" >&2; exit 1; }

plist_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo "?"; }
STAMP="$(plist_key CFBundleShortVersionString) ($(plist_key CFBundleVersion))"

if [ ! -f "$PROVENANCE" ]; then
  # A bundle with no build record cannot say what is in it, and saying so is the point.
  echo "$STAMP · no build record"
  exit 0
fi

provenance_key() { /usr/bin/plutil -extract "$1" raw "$PROVENANCE" 2>/dev/null || true; }
COMMIT="$(provenance_key sourceCommit)"
DIFF="$(provenance_key sourceDiffSHA256)"

[ -z "$COMMIT" ] || STAMP="$STAMP · ${COMMIT:0:7}"
# An absent hash stays quiet: an older bundle predates the field and cannot prove either way. A hash
# that is present and is not the empty-diff constant means uncommitted code went into the build.
if [ -n "$DIFF" ] && [ "$DIFF" != "$CLEAN_TREE_DIFF" ]; then
  STAMP="$STAMP + local changes"
fi

echo "$STAMP"

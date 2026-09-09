#!/usr/bin/env bash
# Build the production-shaped app, sign it, and run the packaged-provider smoke check.
#
# This is the fast feedback loop between `dev.sh` and a public release: it bundles the locked
# agentd dependencies and provider engines exactly like distribution, but deliberately skips
# notarization, DMG creation, appcast generation, uploads, git commits, and tags.
#
#   ./scripts/dogfood.sh             # build + sign + verify; leave build/Mechanician.app ready
#   ./scripts/dogfood.sh --install   # then replace /Applications/Mechanician.app and relaunch
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/build/Mechanician.app"
INSTALL=0

case "${1:-}" in
  "") ;;
  --install) INSTALL=1 ;;
  -h|--help)
    printf '%s\n' \
      'usage: scripts/dogfood.sh [--install]' \
      '' \
      'Build, sign, and verify the production-shaped app without notarizing or publishing.' \
      'Pass --install from a plain Terminal to replace and relaunch the installed app.'
    exit 0
    ;;
  *) echo "usage: $0 [--install]" >&2; exit 64 ;;
esac
[ "$#" -le 1 ] || { echo "usage: $0 [--install]" >&2; exit 64; }

# The visible dogfood label names a Git commit. Refuse a worktree whose tracked or untracked
# source could differ from that commit; dev.sh remains the fast dirty-tree loop, while a packaged
# candidate must be exactly identifiable when the user reports a regression days later.
if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=normal)" ]; then
  echo "!! dogfood packaging requires a clean worktree so its source stamp is exact" >&2
  echo "   commit or stash the current changes, then run scripts/dogfood.sh again" >&2
  exit 1
fi

STARTED_AT=$SECONDS
echo "==> building signed packaged dogfood app"
# `swift build -c release` prints nothing for minutes. Say so, because a silent release build is
# indistinguishable from a hang and has cost at least one debugging session.
echo "    the release build is silent for a few minutes (about 3 on an M-series Mac)"
echo "    no output does not mean it is stuck; press Ctrl-C only if you mean it"
MECHANICIAN_DOGFOOD_BUILD=1 "$REPO/build-app.sh"

[ -x "$APP/Contents/Resources/node" ] \
  || { echo "!! packaged Node runtime is missing" >&2; exit 1; }
echo "==> verifying packaged Claude authentication"
"$APP/Contents/Resources/node" "$REPO/scripts/verify-packaged-auth.mjs" "$APP"

ELAPSED=$((SECONDS - STARTED_AT))
echo "==> dogfood candidate ready in ${ELAPSED}s: $APP"
# Say what is IN it. The build number does not move locally, so without this line the only way to
# tell two candidates apart was to grep the packaged daemon for a string.
STAMP="$("$REPO/scripts/build-stamp.sh" "$APP")"
echo "    $STAMP"
case "$STAMP" in
  *"local changes"*)
    echo "    !! built from a modified working tree, so this app is not any commit"
    ;;
esac

if [ "$INSTALL" -eq 1 ]; then
  echo "==> installing candidate (Mechanician will quit and relaunch)"
  exec "$REPO/scripts/install-local.sh"
fi

echo "    install when ready from a plain Terminal:"
echo "      $REPO/scripts/install-local.sh"

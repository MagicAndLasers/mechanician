#!/usr/bin/env bash
# Build the standard Mechanician app as a flat installer package suitable for an MDM service.
# The package never contains tenant configuration: app and policy have separate lifecycles.
set -euo pipefail

APP="${1:-}"
OUTPUT="${2:-}"
MODE="${3:-}"

usage() {
  echo "usage: $0 /path/to/Mechanician.app /path/to/Mechanician.pkg [--unsigned]" >&2
  exit 64
}

[ -n "$APP" ] && [ -n "$OUTPUT" ] || usage
[ -z "$MODE" ] || [ "$MODE" = "--unsigned" ] || usage
[ -d "$APP" ] || { echo "!! app bundle not found: $APP" >&2; exit 1; }

INFO="$APP/Contents/Info.plist"
[ -f "$INFO" ] || { echo "!! app Info.plist not found: $INFO" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
APP_BASENAME="$(basename "$APP")"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] \
  || { echo "!! invalid app bundle identifier: $BUNDLE_ID" >&2; exit 1; }
[ "$BUNDLE_ID" = "ai.mechanician.app" ] \
  || { echo "!! enterprise package must use the standard ai.mechanician.app identity" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "!! invalid app version: $VERSION" >&2; exit 1; }
[ "$APP_BASENAME" = "Mechanician.app" ] \
  || { echo "!! enterprise package must contain the standard Mechanician.app" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mechanician-pkg.XXXXXX")"
cleanup() { /bin/rm -rf "$WORK"; }
trap cleanup EXIT
ROOT="$WORK/root"
/bin/mkdir -p "$ROOT/Applications"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr \
  "$APP" "$ROOT/Applications/$APP_BASENAME"

/bin/mkdir -p "$(dirname "$OUTPUT")"
/bin/rm -f "$OUTPUT"

ARGS=(
  --root "$ROOT"
  --install-location /
  --identifier "$BUNDLE_ID.installer"
  --version "$VERSION"
  --ownership recommended
)

if [ "$MODE" != "--unsigned" ]; then
  TEAM_ID="${MECHANICIAN_SIGNING_TEAM_ID:-5YPG2C4S34}"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
  APP_TEAM="$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -1)"
  [ "$APP_TEAM" = "$TEAM_ID" ] \
    || { echo "!! app TeamIdentifier $APP_TEAM does not match $TEAM_ID" >&2; exit 1; }
  if [ -n "${MECHANICIAN_INSTALLER_IDENTITY:-}" ]; then
    INSTALLER_IDENTITY="$MECHANICIAN_INSTALLER_IDENTITY"
  else
    INSTALLER_IDENTITY="$(/usr/bin/security find-identity -v -p basic \
      | /usr/bin/sed -n "s/.*\"\(Developer ID Installer:[^\"]*(${TEAM_ID})\)\".*/\1/p" \
      | /usr/bin/head -1)"
  fi
  [ -n "$INSTALLER_IDENTITY" ] \
    || { echo "!! no Developer ID Installer identity for team $TEAM_ID" >&2; exit 1; }
  ARGS+=(--sign "$INSTALLER_IDENTITY")
fi

COPYFILE_DISABLE=1 /usr/bin/pkgbuild "${ARGS[@]}" "$OUTPUT"

[ -s "$OUTPUT" ] || { echo "!! installer package was not created" >&2; exit 1; }
PAYLOAD="$WORK/payload.txt"
/usr/sbin/pkgutil --payload-files "$OUTPUT" > "$PAYLOAD"
[ -s "$PAYLOAD" ] || { echo "!! installer package has an empty payload" >&2; exit 1; }
if /usr/bin/awk -v app="Applications/$APP_BASENAME" -v appbase="$APP_BASENAME" '
  {
    path=$0
    sub(/^\.\//, "", path)
    if (path == "." || path == "Applications" || path == app || index(path, app "/") == 1) next
    # pkgbuild represents protected macOS metadata as AppleDouble siblings. They carry no
    # executable payload and are acceptable only beside the two approved package roots.
    if (path == "._Applications" || path == "Applications/._" appbase) next
    bad=1
  }
  END { exit bad }
' "$PAYLOAD"; then
  :
else
  echo "!! installer package contains files outside /Applications/$APP_BASENAME" >&2
  exit 1
fi

if [ "$MODE" != "--unsigned" ]; then
  /usr/sbin/pkgutil --check-signature "$OUTPUT"
fi

echo "==> built enterprise installer package: $OUTPUT"

#!/usr/bin/env bash
# Build a Finder-guided drag-install DMG. The background lives in source control so every release
# gets the same app-left / Applications-right layout instead of inheriting arbitrary Finder metadata.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"
OUTPUT="${2:-}"
PROFILE="${3:-}"
VOLUME_NAME="${MECHANICIAN_DMG_VOLUME_NAME:-Mechanician}"
BUILD_VOLUME_NAME="$VOLUME_NAME Installer $(uuidgen | tr -d '-' | cut -c1-8)"
BACKGROUND="${MECHANICIAN_DMG_BACKGROUND:-$REPO/app/Resources/dmg-installer-background.png}"
WIDTH=960
HEIGHT=540

usage() {
  echo "usage: $0 /path/to/Mechanician.app /path/to/Mechanician.dmg [Configuration.mechanician-profile]" >&2
  exit 64
}

[ -n "$APP" ] && [ -n "$OUTPUT" ] || usage
[ -d "$APP" ] || { echo "!! app bundle not found: $APP" >&2; exit 1; }
[ -f "$BACKGROUND" ] || { echo "!! installer background not found: $BACKGROUND" >&2; exit 1; }
if [ -n "$PROFILE" ]; then
  [ -f "$PROFILE" ] || { echo "!! enterprise profile not found: $PROFILE" >&2; exit 1; }
  case "$PROFILE" in
    *.mechanician-profile) ;;
    *) echo "!! enterprise profile must end in .mechanician-profile" >&2; exit 1 ;;
  esac
  "$REPO/scripts/verify-enterprise-profile.swift" "$PROFILE"
fi
# The in-volume app name follows the bundle we were handed, so a tenant build (e.g. "Mechanician for
# Acme.app") drops in with its real name and the Finder layout still positions it correctly.
APP_BASENAME="$(basename "$APP")"
PROFILE_BASENAME="${PROFILE:+$(basename "$PROFILE")}"
GUIDE_BASENAME="${PROFILE:+Install Enterprise Configuration.txt}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mechanician-dmg.XXXXXX")"
RW_DMG="$WORK/Mechanician-rw.dmg"
MOUNT=""
DEVICE=""
ATTACHED=0

cleanup() {
  if [ "$ATTACHED" = 1 ]; then
    hdiutil detach "${DEVICE:-$MOUNT}" -quiet 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"

# A writable HFS+ image is needed because Finder persists icon positions and background metadata on
# the volume. The compressed release image is created only after that metadata is flushed.
APP_KB="$(du -sk "$APP" | awk '{ print $1 }')"
IMAGE_MB=$(( (APP_KB + (128 * 1024) + 1023) / 1024 ))
hdiutil create -size "${IMAGE_MB}m" -fs HFS+ -volname "$BUILD_VOLUME_NAME" -ov "$RW_DMG" -quiet
ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
# The unique staging volume name makes this path unambiguous even when other Mechanician images are
# open. Preserve the complete path because both the volume name and mount point contain spaces.
MOUNT="$(printf '%s\n' "$ATTACH_OUTPUT" | sed -n 's/^.*Apple_HFS[[:space:]]*//p' | head -1)"
DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ { print $1; exit }')"
[ -n "$MOUNT" ] && [ -n "$DEVICE" ] \
  || { echo "!! could not identify the mounted DMG volume" >&2; exit 1; }
ATTACHED=1

ditto "$APP" "$MOUNT/$APP_BASENAME"
ln -s /Applications "$MOUNT/Applications"
if [ -n "$PROFILE" ]; then
  /usr/bin/ditto "$PROFILE" "$MOUNT/$PROFILE_BASENAME"
  /usr/bin/printf '%s\n' \
    '1. Drag Mechanician.app to Applications.' \
    '2. Open Mechanician once.' \
    "3. Double-click $PROFILE_BASENAME." \
    '4. Review the signed configuration, then choose Install and Relaunch.' \
    > "$MOUNT/$GUIDE_BASENAME"
fi
mkdir -p "$MOUNT/.background"
cp "$BACKGROUND" "$MOUNT/.background/Mechanician-installer.png"
chflags hidden "$MOUNT/.background" 2>/dev/null || true

# Finder coordinates are in the background's 960×540 point coordinate system. The art deliberately
# keeps these two regions quiet, and its magic beam points from the app icon toward Applications.
osascript - "$BUILD_VOLUME_NAME" "$MOUNT" "$WIDTH" "$HEIGHT" "$APP_BASENAME" \
  "$PROFILE_BASENAME" "$GUIDE_BASENAME" <<'APPLESCRIPT'
on run argv
  set volumeName to item 1 of argv
  set mountPath to item 2 of argv
  set windowWidth to (item 3 of argv) as integer
  set windowHeight to (item 4 of argv) as integer
  set appItemName to item 5 of argv
  set profileItemName to item 6 of argv
  set guideItemName to item 7 of argv
  set backgroundFile to POSIX file (mountPath & "/.background/Mechanician-installer.png") as alias

  tell application "Finder"
    tell disk volumeName
      open
      delay 1
      set containerWindow to container window
      set current view of containerWindow to icon view
      set toolbar visible of containerWindow to false
      set statusbar visible of containerWindow to false
      set bounds of containerWindow to {100, 100, 100 + windowWidth, 100 + windowHeight}
      set viewOptions to icon view options of containerWindow
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 104
      set text size of viewOptions to 14
      set background picture of viewOptions to backgroundFile
      if profileItemName is "" then
        set position of item appItemName to {200, 267}
        set position of item "Applications" to {765, 267}
      else
        set position of item appItemName to {180, 230}
        set position of item "Applications" to {780, 230}
        set position of item profileItemName to {480, 385}
        set position of item guideItemName to {480, 95}
      end if
      update without registering applications
      close containerWindow
    end tell
  end tell
end run
APPLESCRIPT

# Closing Finder flushes the .DS_Store. Wait for it explicitly and refuse to publish a plain DMG if
# Finder failed to persist the custom background or icon positions.
for _ in {1..40}; do
  [ -s "$MOUNT/.DS_Store" ] && break
  sleep 0.25
done
[ -s "$MOUNT/.DS_Store" ] \
  || { echo "!! Finder did not write installer layout metadata (.DS_Store)" >&2; exit 1; }
# The unique staging name avoids collisions in Finder. Restore the user-facing volume name only
# after Finder has closed and persisted the layout.
diskutil rename "$DEVICE" "$VOLUME_NAME" >/dev/null
sync
hdiutil detach "$DEVICE" -quiet
ATTACHED=0
DEVICE=""
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$OUTPUT" -quiet

# Verify the compressed artifact itself, not just the writable staging image.
MOUNT="$WORK/verify"
mkdir -p "$MOUNT"
hdiutil attach "$OUTPUT" -readonly -noverify -noautoopen -mountpoint "$MOUNT" -quiet
ATTACHED=1
[ -s "$MOUNT/.DS_Store" ] \
  || { echo "!! compressed DMG is missing Finder layout metadata" >&2; exit 1; }
[ -f "$MOUNT/.background/Mechanician-installer.png" ] \
  || { echo "!! compressed DMG is missing installer background artwork" >&2; exit 1; }
if [ -n "$PROFILE" ]; then
  [ -f "$MOUNT/$PROFILE_BASENAME" ] \
    || { echo "!! compressed DMG is missing the signed enterprise profile" >&2; exit 1; }
  [ -f "$MOUNT/$GUIDE_BASENAME" ] \
    || { echo "!! compressed DMG is missing the enterprise installation guide" >&2; exit 1; }
fi
hdiutil detach "$MOUNT" -quiet
ATTACHED=0

echo "==> built Finder-guided DMG: $OUTPUT"

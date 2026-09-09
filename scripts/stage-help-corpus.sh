#!/usr/bin/env bash
# Build the signed, read-only Mechanician product-knowledge resource into an assembled app bundle.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: stage-help-corpus.sh <app> <Info.plist> [tenant-id] [node] [source-commit] [source-diff-sha256]}"
INFO_PLIST="${2:?usage: stage-help-corpus.sh <app> <Info.plist> [tenant-id] [node] [source-commit] [source-diff-sha256]}"
TENANT_ID="${3:-default}"
NODE="${4:-$(command -v node || true)}"
SOURCE_COMMIT="${5:-}"
SOURCE_DIFF_SHA256="${6:-}"
OUTPUT="$APP/Contents/Resources/MechanicianHelp.sqlite"

[ -d "$APP/Contents/Resources" ] || { echo "!! not an assembled bundle: $APP" >&2; exit 1; }
[ -f "$INFO_PLIST" ] || { echo "!! Info.plist not found: $INFO_PLIST" >&2; exit 1; }
[ -x "$NODE" ] || { echo "!! Node 24+ is required to compile Mechanician Help" >&2; exit 1; }
if [ -z "$SOURCE_COMMIT" ] && [ -z "$SOURCE_DIFF_SHA256" ]; then
  SOURCE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
  SOURCE_DIFF_SHA256="$(git -C "$REPO" diff --binary HEAD | /usr/bin/shasum -a 256 | awk '{print $1}')"
elif [ -z "$SOURCE_COMMIT" ] || [ -z "$SOURCE_DIFF_SHA256" ]; then
  echo "!! Help corpus source commit and diff digest must be supplied together" >&2
  exit 1
fi
[[ "$SOURCE_COMMIT" =~ ^[a-f0-9]{40}$ ]] \
  || { echo "!! invalid Help corpus source commit" >&2; exit 1; }
[[ "$SOURCE_DIFF_SHA256" =~ ^[a-f0-9]{64}$ ]] \
  || { echo "!! invalid Help corpus source diff digest" >&2; exit 1; }

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"

echo "==> compiling Mechanician Help"
"$NODE" "$REPO/scripts/build-help-corpus.mjs" \
  --source "$REPO/help/corpus.json" \
  --output "$OUTPUT" \
  --app-version "$APP_VERSION" \
  --app-build "$APP_BUILD" \
  --bundle-id "$BUNDLE_ID" \
  --tenant-id "$TENANT_ID" \
  --source-commit "$SOURCE_COMMIT" \
  --source-diff-sha256 "$SOURCE_DIFF_SHA256"

# Evidence and source identity are read throughout compilation. Refuse an artifact assembled while
# tracked source was changing instead of sealing a database whose provenance names two snapshots.
CURRENT_SOURCE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
CURRENT_SOURCE_DIFF_SHA256="$(git -C "$REPO" diff --binary HEAD | /usr/bin/shasum -a 256 | awk '{print $1}')"
[ "$CURRENT_SOURCE_COMMIT" = "$SOURCE_COMMIT" ] \
  && [ "$CURRENT_SOURCE_DIFF_SHA256" = "$SOURCE_DIFF_SHA256" ] \
  || { echo "!! tracked source changed while compiling Mechanician Help" >&2; exit 1; }

[ -f "$OUTPUT" ] || { echo "!! Mechanician Help corpus was not staged" >&2; exit 1; }
[ ! -e "$OUTPUT-wal" ] && [ ! -e "$OUTPUT-shm" ] \
  || { echo "!! Mechanician Help corpus has live SQLite sidecars" >&2; exit 1; }
chmod 644 "$OUTPUT"

#!/usr/bin/env bash
# Remove update-bucket objects that are not referenced by the live Sparkle feed.
#
# Dry-run is the default. The two stable website downloads are retained even though
# they are intentionally not referenced by appcast.xml.
set -euo pipefail

# Homebrew installs gcloud here on Apple Silicon, but non-interactive release
# shells do not consistently inherit that path.
export PATH="$PATH:/opt/homebrew/bin"

BUCKET="${MECHANICIAN_UPDATE_BUCKET:-gs://mechanician-updates}"
ARTIFACT_NAME="${MECHANICIAN_ARTIFACT_NAME:-Mechanician}"
APPLY=0
VERBOSE=0

usage() {
  cat <<'EOF'
usage: scripts/prune-updates.sh [--apply] [--verbose]

Without --apply, prints the retention/deletion summary without changing GCS.

  --apply     delete unreferenced objects (the bucket's soft-delete policy still applies)
  --verbose   list every object that would be deleted
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

[[ "$BUCKET" =~ ^gs://[A-Za-z0-9._-]+$ ]] \
  || { echo "MECHANICIAN_UPDATE_BUCKET must be a canonical root gs:// bucket" >&2; exit 1; }
[[ "$ARTIFACT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || { echo "MECHANICIAN_ARTIFACT_NAME must be filesystem/URL safe" >&2; exit 1; }
command -v gcloud >/dev/null || { echo "gcloud is required" >&2; exit 1; }

BUCKET_NAME="${BUCKET#gs://}"
BUCKET_NAME="${BUCKET_NAME%%/*}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mechanician-prune.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APPCAST="$TMP_DIR/appcast.xml"
KEEP="$TMP_DIR/keep.txt"
KEEP_IF_PRESENT="$TMP_DIR/keep-if-present.txt"
FEED_OBJECTS="$TMP_DIR/feed-objects.txt"
OBJECTS="$TMP_DIR/objects.tsv"
DELETE="$TMP_DIR/delete.tsv"
MIN_DELETE_AGE_SECONDS="${MECHANICIAN_PRUNE_MIN_AGE_SECONDS:-86400}"
[[ "$MIN_DELETE_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "MECHANICIAN_PRUNE_MIN_AGE_SECONDS must be a positive integer" >&2; exit 1; }
[ "$MIN_DELETE_AGE_SECONDS" -ge 86400 ] \
  || { echo "MECHANICIAN_PRUNE_MIN_AGE_SECONDS cannot be less than 86400" >&2; exit 1; }

echo "==> reading live appcast and bucket inventory"
APPCAST_GENERATION="$(gcloud storage objects describe "$BUCKET/appcast.xml" --format='value(generation)')"
[[ "$APPCAST_GENERATION" =~ ^[1-9][0-9]*$ ]] \
  || { echo "!! refusing to prune: live appcast has no valid generation" >&2; exit 1; }
gcloud storage cat "$BUCKET/appcast.xml" > "$APPCAST"
gcloud storage ls -L "$BUCKET/**" \
  | /usr/bin/awk '
      function emit() { if (url != "" && size != "" && created != "") print size "\t" url "\t" created }
      /^gs:\/\// { emit(); url=$1; sub(/:$/, "", url); size=""; created=""; next }
      /^[[:space:]]*Content-Length:/ { size=$2; next }
      /^[[:space:]]*Creation Time:/ { created=$3; next }
      END { emit() }
    ' > "$OBJECTS"

# A successful fetch is not enough evidence that the feed is safe to prune from.
# Refuse malformed, empty, or unexpectedly re-hosted feeds rather than interpreting
# "no recognized artifacts" as permission to delete every versioned archive.
grep -q '<sparkle:version>[^<][^<]*</sparkle:version>' "$APPCAST" \
  || { echo "!! refusing to prune: live appcast has no Sparkle version" >&2; exit 1; }
grep -Eo "https://storage.googleapis.com/${BUCKET_NAME}/[^\"<[:space:]]+" "$APPCAST" \
  | sed "s|^https://storage.googleapis.com/${BUCKET_NAME}/||" \
  | LC_ALL=C sort -u > "$FEED_OBJECTS" \
  || true
[ -s "$FEED_OBJECTS" ] \
  || { echo "!! refusing to prune: live appcast has no recognized bucket artifacts" >&2; exit 1; }

# Preserve every GCS object URL in the feed. This covers full archives and deltas.
# The stable names are website downloads and intentionally do not appear in the feed.
{
  echo "appcast.xml"
  echo "$ARTIFACT_NAME-latest.dmg"
  echo "$ARTIFACT_NAME-latest.zip"
  sed -n 'p' "$FEED_OBJECTS"
} | LC_ALL=C sort -u > "$KEEP"

# Non-feed artifacts for every version the feed still offers: the immutable DMG and enterprise
# installer package, checksums, provenance, and the version/build-scoped record that proves a Daily artifact was promoted to
# Stable. Sparkle has no use for them, so none is referenced by appcast.xml; the feed alone would
# otherwise prune the exact artifacts and evidence a later promotion needs.
#
# SOFT retention, unlike $KEEP: kept when present, never required to exist. Releases cut before
# these files existed have none, and a version whose records were pruned earlier must not turn every
# later run into a hard abort. Missing evidence is not a reason to refuse to reclaim space.
grep -Eo '<sparkle:shortVersionString>[^<]+</sparkle:shortVersionString>|<sparkle:version>[^<]+</sparkle:version>' "$APPCAST" \
  | sed -E 's|</?sparkle:[a-zA-Z]+>||g' \
  | paste - - \
  | while IFS=$'\t' read -r first second; do
      # generate_appcast currently emits <sparkle:version> (the build) before
      # <sparkle:shortVersionString>, but pairing on document order alone would silently produce
      # nonsense filenames if that ever flipped. The build is the all-digits one; decide from the
      # values rather than from their position.
      case "$first" in
        ''|*[!0-9]*) build="$second"; version="$first" ;;
        *)           build="$first";  version="$second" ;;
      esac
      case "$build" in ''|*[!0-9]*) continue ;; esac
      [ -n "$version" ] || continue
      echo "$ARTIFACT_NAME-$version.dmg"
      echo "$ARTIFACT_NAME-$version.pkg"
      echo "$ARTIFACT_NAME-$version-$build-SHA256SUMS.txt"
      echo "$ARTIFACT_NAME-$version-$build-provenance.json"
      echo "$ARTIFACT_NAME-$version-$build-sbom.cdx.json"
      echo "$ARTIFACT_NAME-$version-$build-release.json"
      echo "$ARTIFACT_NAME-$version-$build-stable-promotion-authorization.json"
    done \
  | LC_ALL=C sort -u > "$KEEP_IF_PRESENT"

# Abort rather than prune if the live feed already points at a missing object.
while IFS= read -r object; do
  if ! awk -F '\t' -v url="$BUCKET/$object" '$2 == url { found=1 } END { exit !found }' "$OBJECTS"; then
    echo "!! refusing to prune: required object is missing: $BUCKET/$object" >&2
    exit 1
  fi
done < "$KEEP"

NOW_EPOCH="$(date +%s)"
while IFS=$'\t' read -r size url created; do
  object="${url#"$BUCKET/"}"
  if ! grep -Fqx "$object" "$KEEP" && ! grep -Fqx "$object" "$KEEP_IF_PRESENT"; then
    case "$created" in
      *Z) created_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$created" +%s 2>/dev/null || true)" ;;
      *) created_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$created" +%s 2>/dev/null || true)" ;;
    esac
    [[ "$created_epoch" =~ ^[0-9]+$ ]] \
      || { echo "!! refusing to prune: invalid creation time for $url" >&2; exit 1; }
    if [ "$((NOW_EPOCH - created_epoch))" -ge "$MIN_DELETE_AGE_SECONDS" ]; then
      printf '%s\t%s\n' "$size" "$url" >> "$DELETE"
    fi
  fi
done < "$OBJECTS"
touch "$DELETE"

TOTAL_COUNT="$(wc -l < "$OBJECTS" | tr -d ' ')"
DELETE_COUNT="$(wc -l < "$DELETE" | tr -d ' ')"
# Counted as what survives, not as the length of the keep list: a soft-retained record that is not
# in the bucket would otherwise inflate the number and stop it reconciling with total - delete.
KEEP_COUNT="$((TOTAL_COUNT - DELETE_COUNT))"
TOTAL_BYTES="$(awk -F '\t' '{ total += $1 } END { printf "%.0f", total }' "$OBJECTS")"
DELETE_BYTES="$(awk -F '\t' '{ total += $1 } END { printf "%.0f", total }' "$DELETE")"

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", units, " "); unit=1
    while (bytes >= 1024 && unit < 5) { bytes /= 1024; unit++ }
    printf "%.2f %s", bytes, units[unit]
  }'
}

echo "    bucket:  $TOTAL_COUNT objects, $(human_bytes "$TOTAL_BYTES")"
echo "    keep:    $KEEP_COUNT objects"
echo "    delete:  $DELETE_COUNT objects, $(human_bytes "$DELETE_BYTES")"
echo ""
echo "Required objects retained:"
sed 's/^/  /' "$KEEP"

# Only the ones actually in the bucket; listing records that were never published would read as a
# promise the run cannot keep.
PRESENT_OPTIONALS="$TMP_DIR/present-optionals.txt"
: > "$PRESENT_OPTIONALS"
while IFS= read -r object; do
  awk -F '\t' -v url="$BUCKET/$object" '$2 == url { found=1 } END { exit !found }' "$OBJECTS" \
    && echo "$object" >> "$PRESENT_OPTIONALS"
done < "$KEEP_IF_PRESENT"
if [ -s "$PRESENT_OPTIONALS" ]; then
  echo ""
  echo "Optional release artifacts retained (kept when present):"
  sed 's/^/  /' "$PRESENT_OPTIONALS"
fi

if [ "$VERBOSE" -eq 1 ] && [ "$DELETE_COUNT" -gt 0 ]; then
  echo ""
  echo "Objects selected for deletion:"
  cut -f2 "$DELETE" | sed 's/^/  /'
fi

if [ "$APPLY" -eq 0 ]; then
  echo ""
  echo "DRY RUN — re-run with --apply to delete the unreferenced objects."
  exit 0
fi

if [ "$DELETE_COUNT" -eq 0 ]; then
  echo ""
  echo "==> nothing to delete"
  exit 0
fi

echo ""
echo "==> deleting $DELETE_COUNT unreferenced objects"
# A release uploads immutable objects before appcast CAS. Never delete from an inventory computed
# against an older feed after that CAS has made one of those objects live.
CURRENT_APPCAST_GENERATION="$(gcloud storage objects describe "$BUCKET/appcast.xml" --format='value(generation)')"
[ "$CURRENT_APPCAST_GENERATION" = "$APPCAST_GENERATION" ] \
  || { echo "!! refusing to prune: live appcast changed after the deletion plan was computed" >&2; exit 1; }
batch=()
while IFS=$'\t' read -r _ url; do
  batch+=("$url")
  if [ "${#batch[@]}" -eq 50 ]; then
    CURRENT_APPCAST_GENERATION="$(gcloud storage objects describe "$BUCKET/appcast.xml" --format='value(generation)')"
    [ "$CURRENT_APPCAST_GENERATION" = "$APPCAST_GENERATION" ] \
      || { echo "!! refusing to prune: live appcast changed during deletion" >&2; exit 1; }
    gcloud storage rm "${batch[@]}"
    batch=()
  fi
done < "$DELETE"
if [ "${#batch[@]}" -gt 0 ]; then
  CURRENT_APPCAST_GENERATION="$(gcloud storage objects describe "$BUCKET/appcast.xml" --format='value(generation)')"
  [ "$CURRENT_APPCAST_GENERATION" = "$APPCAST_GENERATION" ] \
    || { echo "!! refusing to prune: live appcast changed during deletion" >&2; exit 1; }
  gcloud storage rm "${batch[@]}"
fi
CURRENT_APPCAST_GENERATION="$(gcloud storage objects describe "$BUCKET/appcast.xml" --format='value(generation)')"
[ "$CURRENT_APPCAST_GENERATION" = "$APPCAST_GENERATION" ] \
  || { echo "!! live appcast changed during deletion; retained-object verification will fail closed" >&2; exit 1; }

# Re-read the inventory and prove every retained object is still present.
gcloud storage ls -L "$BUCKET/**" \
  | /usr/bin/awk '
      function emit() { if (url != "" && size != "" && created != "") print size "\t" url "\t" created }
      /^gs:\/\// { emit(); url=$1; sub(/:$/, "", url); size=""; created=""; next }
      /^[[:space:]]*Content-Length:/ { size=$2; next }
      /^[[:space:]]*Creation Time:/ { created=$3; next }
      END { emit() }
    ' > "$OBJECTS"
while IFS= read -r object; do
  if ! awk -F '\t' -v url="$BUCKET/$object" '$2 == url { found=1 } END { exit !found }' "$OBJECTS"; then
    echo "!! required object missing after prune: $BUCKET/$object" >&2
    exit 1
  fi
done < "$KEEP"
while IFS= read -r object; do
  if ! awk -F '\t' -v url="$BUCKET/$object" '$2 == url { found=1 } END { exit !found }' "$OBJECTS"; then
    echo "!! retained optional object missing after prune: $BUCKET/$object" >&2
    exit 1
  fi
done < "$PRESENT_OPTIONALS"

REMAINING_COUNT="$(wc -l < "$OBJECTS" | tr -d ' ')"
echo "==> prune complete: $REMAINING_COUNT live objects remain"

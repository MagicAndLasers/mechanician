#!/usr/bin/env bash
# Promote one already-published Daily build to Stable without rebuilding or re-signing the app.
# The only newly signed object is appcast.xml; ZIP/DMG bytes remain the exact Daily artifacts.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET="${MECHANICIAN_UPDATE_BUCKET:-gs://mechanician-updates}"
URL_PREFIX="${MECHANICIAN_UPDATE_URL_PREFIX:-https://storage.googleapis.com/mechanician-updates/}"
ARTIFACT_NAME="${MECHANICIAN_ARTIFACT_NAME:-Mechanician}"
APP_NAME="${MECHANICIAN_APP_NAME:-Mechanician}"
PLIST_REL="${MECHANICIAN_INFO_PLIST_REL:-app/Mechanician-Info.plist}"
SPARKLE_ACCOUNT="${MECHANICIAN_SPARKLE_ACCOUNT:-ed25519}"
REQUIRED_CI_CHECK="${MECHANICIAN_REQUIRED_CI_CHECK:-macOS 26 / Apple Silicon}"
RELEASE_BRANCH="${MECHANICIAN_RELEASE_BRANCH:-main}"
RELEASE_COMMIT_PREFIX="${MECHANICIAN_RELEASE_COMMIT_PREFIX:-chore(release)}"
RELEASE_TAG_PREFIX="${MECHANICIAN_RELEASE_TAG_PREFIX:-v}"
GCLOUD="${MECHANICIAN_GCLOUD:-gcloud}"
GH="${MECHANICIAN_GH:-gh}"
GIT="${MECHANICIAN_GIT:-git}"
UPDATE_HISTORY="$REPO/scripts/stage-update-history.sh"
ARTIFACT_PUBLISHER="$REPO/scripts/publish-update-artifacts.sh"
ATTESTATION_VALIDATOR="$REPO/scripts/validate-stable-promotion.mjs"
SIGN_UPDATE="${MECHANICIAN_SIGN_UPDATE:-$REPO/app/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
STAGE="${MECHANICIAN_PROMOTION_STAGE:-$REPO/build/stable-promotion}"
VOLUME_ROOT="${MECHANICIAN_PROMOTION_VOLUME_ROOT:-/Volumes}"

case "$URL_PREFIX" in */) ;; *) URL_PREFIX="$URL_PREFIX/" ;; esac
BUCKET="${BUCKET%/}"

die() {
  echo "!! $*" >&2
  exit 1
}

DMG_MOUNT=""
cleanup_mount() {
  if [ -n "$DMG_MOUNT" ]; then
    hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
    DMG_MOUNT=""
  fi
}
trap cleanup_mount EXIT

usage() {
  cat <<'EOF'
usage: scripts/promote-daily.sh <version> --attestation <file> [--urgent-reason <text>]

Promotes the exact signed/notarized artifacts already published for one Daily
release. Normal policy requires two distinct machine smokes and a 24-hour soak.
--urgent-reason may waive only the soak duration, never artifact or smoke checks.

The command is idempotent. If the appcast was already promoted but an alias copy
failed, rerun the same command with the same attestation to reconcile aliases.
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
VERSION="${1:-}"
[ -n "$VERSION" ] || { usage >&2; exit 64; }
shift || true
ATTESTATION=""
URGENT_REASON=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attestation) [ "$#" -ge 2 ] || die "--attestation requires a file"; ATTESTATION="$2"; shift 2 ;;
    --urgent-reason) [ "$#" -ge 2 ] || die "--urgent-reason requires text"; URGENT_REASON="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "version must be a numeric semantic version"
[ -f "$ATTESTATION" ] || die "--attestation must name a readable JSON file"
[[ "$BUCKET" =~ ^gs://[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
  || die "MECHANICIAN_UPDATE_BUCKET must be a canonical gs:// bucket or bucket path"
[[ "$ARTIFACT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "MECHANICIAN_ARTIFACT_NAME must be filesystem/URL safe"
mkdir -p "$REPO/build"
case "$STAGE" in
  "$REPO/build/"?*) ;;
  *) die "promotion stage must be one direct child of $REPO/build" ;;
esac
STAGE_NAME="${STAGE#"$REPO/build/"}"
case "$STAGE_NAME" in ''|.|..|*/*|*\\*) die "promotion stage must be one direct build child" ;; esac
[ -d "$VOLUME_ROOT" ] || die "promotion volume root does not exist: $VOLUME_ROOT"

export PATH="/opt/homebrew/bin:$PATH"
for executable in "$UPDATE_HISTORY" "$ARTIFACT_PUBLISHER" "$ATTESTATION_VALIDATOR" "$SIGN_UPDATE"; do
  [ -x "$executable" ] || die "required executable is missing: $executable"
done
for command in "$GCLOUD" "$GH" "$GIT" ditto codesign spctl xcrun hdiutil plutil node; do
  command -v "$command" >/dev/null || die "$command is required"
done

if [ -z "${CLOUDSDK_PYTHON:-}" ]; then
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -c \
      'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
      export CLOUDSDK_PYTHON="$candidate"
      break
    fi
  done
fi
export CLOUDSDK_STORAGE_USE_GCLOUD_CRC32C=false

field() {
  printf '%s\n' "$1" | /usr/bin/cut -f"$2"
}

require_green_ci() {
  local commit="$1" label="$2" checks required_count required_conclusion
  checks=""
  if response="$("$GH" api "repos/{owner}/{repo}/commits/$commit/check-runs" \
      --jq '.check_runs[] | "\(.conclusion // "pending")\t\(.name)"' 2>/dev/null)"; then
    checks="$response"
  fi
  [ -n "$checks" ] || die "no CI run found for $label $commit"
  required_count="$(printf '%s\n' "$checks" | /usr/bin/awk -F '\t' -v name="$REQUIRED_CI_CHECK" '$2 == name { count++ } END { print count + 0 }')"
  [ "$required_count" = "1" ] || die "$label must have exactly one $REQUIRED_CI_CHECK CI run"
  required_conclusion="$(printf '%s\n' "$checks" | /usr/bin/awk -F '\t' -v name="$REQUIRED_CI_CHECK" '$2 == name { print $1 }')"
  [ "$required_conclusion" = "success" ] \
    || die "$REQUIRED_CI_CHECK CI is not successful for $label $commit: $required_conclusion"
  echo "    green CI: $label ${commit:0:12}" >&2
}

remote_sha256() {
  local object="$1" output="$2" before after
  before="$("$GCLOUD" storage objects describe "$BUCKET/$object" \
    '--format=value(generation,size)')" || die "missing immutable object: $object"
  [[ "$(field "$before" 1)" =~ ^[1-9][0-9]*$ ]] || die "invalid object generation: $object"
  [[ "$(field "$before" 2)" =~ ^[1-9][0-9]*$ ]] || die "invalid object size: $object"
  "$GCLOUD" storage cp "$BUCKET/$object" "$output"
  after="$("$GCLOUD" storage objects describe "$BUCKET/$object" \
    '--format=value(generation,size)')" || die "immutable object disappeared: $object"
  [ "$before" = "$after" ] || die "immutable object changed while downloading: $object"
  [ "$(/usr/bin/stat -f '%z' "$output")" = "$(field "$before" 2)" ] \
    || die "downloaded object size mismatch: $object"
  /usr/bin/shasum -a 256 "$output" | /usr/bin/awk '{print $1}'
}

remote_object_facts() {
  local object="$1" row
  row="$("$GCLOUD" storage objects describe "$BUCKET/$object" \
    --format='value(generation,crc32c_hash,creation_time)')" || die "missing immutable object facts: $object"
  [[ "$(field "$row" 1)" =~ ^[1-9][0-9]*$ ]] || die "invalid object generation: $object"
  [ -n "$(field "$row" 2)" ] || die "missing object CRC32C: $object"
  [ -n "$(field "$row" 3)" ] || die "missing object creation time: $object"
  printf '%s\n' "$row" | /usr/bin/awk -F '\t' 'BEGIN { OFS="\t" } {
    if ($3 ~ /[+-][0-9][0-9][0-9][0-9]$/) {
      $3 = substr($3, 1, length($3) - 2) ":" substr($3, length($3) - 1)
    }
    print
  }'
}

checksum_row() {
  local manifest="$1" object="$2" row
  row="$(/usr/bin/awk -v object="$object" '$3 == object { print }' "$manifest")"
  [ "$(printf '%s\n' "$row" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')" = "1" ] \
    || die "checksum manifest must contain exactly one row for $object"
  printf '%s\n' "$row"
}

verify_manifest_artifact() {
  local manifest="$1" artifact="$2" expected_object="$3" row actual_hash actual_size
  row="$(checksum_row "$manifest" "$expected_object")"
  actual_hash="$(/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{print $1}')"
  actual_size="$(/usr/bin/stat -f '%z' "$artifact")"
  [ "$(printf '%s\n' "$row" | /usr/bin/awk '{print $1}')" = "$actual_hash" ] \
    && [ "$(printf '%s\n' "$row" | /usr/bin/awk '{print $2}')" = "$actual_size" ] \
    || die "checksum manifest does not match $expected_object"
}

code_identity() {
  codesign -d --verbose=4 "$1" 2>&1 \
    | /usr/bin/awk -F= '
      /^Identifier=/ { identifier=$2 }
      /^TeamIdentifier=/ { team=$2 }
      /^CDHash=/ { hash=$2 }
      END {
        if (identifier == "" || team == "" || hash == "") exit 1
        printf "%s\t%s\t%s\n", identifier, team, hash
      }'
}

verify_dmg_app_identity() {
  local dmg="$1" zip_app="$2" provenance="$3" attach_plist mount_json dmg_app zip_identity dmg_identity
  local canonical_mount canonical_volume relative_mount
  attach_plist="$STAGE/dmg-attach.plist"
  hdiutil attach -readonly -nobrowse -noautoopen -plist "$dmg" > "$attach_plist"
  mount_json="$(plutil -convert json -o - "$attach_plist")"
  DMG_MOUNT="$(printf '%s' "$mount_json" | node -e '
    let input = ""
    process.stdin.setEncoding("utf8")
    process.stdin.on("data", chunk => { input += chunk })
    process.stdin.on("end", () => {
      const plist = JSON.parse(input)
      const mounts = (plist["system-entities"] ?? [])
        .map(entity => entity["mount-point"])
        .filter(value => typeof value === "string" && value.length > 0)
      if (mounts.length !== 1) process.exit(1)
      process.stdout.write(mounts[0])
    })
  ')" || die "could not identify the mounted Daily DMG"
  canonical_volume="$(cd "$VOLUME_ROOT" && pwd -P)" \
    || die "could not canonicalize promotion volume root"
  canonical_mount="$(cd "$DMG_MOUNT" && pwd -P)" \
    || die "could not canonicalize mounted Daily DMG path"
  case "$canonical_mount" in
    "$canonical_volume/"?*) ;;
    *) die "Daily DMG mounted outside the configured volume root" ;;
  esac
  relative_mount="${canonical_mount#"$canonical_volume/"}"
  case "$relative_mount" in ''|*/*) die "Daily DMG mount must be a direct volume child" ;; esac
  DMG_MOUNT="$canonical_mount"
  dmg_app="$DMG_MOUNT/$APP_NAME.app"
  [ -d "$dmg_app" ] || die "Daily DMG does not contain $APP_NAME.app"
  codesign --verify --deep --strict --verbose=2 "$dmg_app"
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$dmg_app/Contents/Info.plist")" = "$VERSION" ] \
    && [ "$(plutil -extract CFBundleVersion raw -o - "$dmg_app/Contents/Info.plist")" = "$BUILD" ] \
    || die "DMG-embedded app identity does not match the Daily feed"
  cmp -s "$provenance" "$dmg_app/Contents/Resources/BuildProvenance.json" \
    || die "DMG-embedded provenance differs from the immutable release provenance"
  zip_identity="$(code_identity "$zip_app")" || die "could not read ZIP app signing identity"
  dmg_identity="$(code_identity "$dmg_app")" || die "could not read DMG app signing identity"
  [ "$zip_identity" = "$dmg_identity" ] \
    || die "ZIP and DMG do not contain the same signed app identity"
  hdiutil detach "$DMG_MOUNT" >/dev/null
  DMG_MOUNT=""
}

require_product_identity() {
  local app="$1" label="$2" expected_identifier="$3" expected_team="$4" identity
  identity="$(code_identity "$app")" || die "could not read $label signing identity"
  [ "$(field "$identity" 1)" = "$expected_identifier" ] \
    || die "$label bundle identifier does not match the tagged product"
  [ "$(field "$identity" 2)" = "$expected_team" ] \
    || die "$label signing team is not the configured Mechanician team"
}

verify_tag_and_provenance() {
  local build="$1" provenance="$2" app_provenance="$3"
  local tag release_commit remote_tag_commit subject changed_files parent expected_diff
  tag="$RELEASE_TAG_PREFIX$VERSION"
  "$GIT" -C "$REPO" fetch --quiet --prune origin "$RELEASE_BRANCH" --tags
  [ "$("$GIT" -C "$REPO" cat-file -t "$tag" 2>/dev/null || true)" = "tag" ] \
    || die "$tag must be an annotated tag"
  release_commit="$("$GIT" -C "$REPO" rev-parse "$tag^{commit}")"
  remote_tag_commit="$("$GIT" -C "$REPO" ls-remote --tags origin "refs/tags/$tag^{}" \
    | /usr/bin/awk 'NR == 1 { print $1 }')"
  [ "$remote_tag_commit" = "$release_commit" ] \
    || die "$tag is not the annotated remote tag for the Daily release commit"
  "$GIT" -C "$REPO" merge-base --is-ancestor "$release_commit" "origin/$RELEASE_BRANCH" \
    || die "$tag release commit is not on origin/$RELEASE_BRANCH"
  subject="$("$GIT" -C "$REPO" log -1 --format='%s' "$release_commit")"
  [ "$subject" = "$RELEASE_COMMIT_PREFIX: $VERSION (daily)" ] \
    || die "$tag is not the Daily release commit for $VERSION"
  changed_files="$("$GIT" -C "$REPO" diff-tree --no-commit-id --name-only -r "$release_commit")"
  [ "$changed_files" = "$PLIST_REL" ] || die "Daily release commit is not version-plist-only"
  [ "$("$GIT" -C "$REPO" show "$release_commit:$PLIST_REL" | plutil -extract CFBundleShortVersionString raw -o - -)" = "$VERSION" ] \
    && [ "$("$GIT" -C "$REPO" show "$release_commit:$PLIST_REL" | plutil -extract CFBundleVersion raw -o - -)" = "$build" ] \
    || die "Daily release commit plist identity is wrong"
  cmp -s "$provenance" "$app_provenance" \
    || die "uploaded provenance differs from the ZIP-embedded provenance"
  [ "$(plutil -extract version raw -o - "$provenance")" = "$VERSION" ] \
    && [ "$(plutil -extract build raw -o - "$provenance")" = "$build" ] \
    && [ "$(plutil -extract dogfood raw -o - "$provenance")" = "false" ] \
    || die "provenance version/build/dogfood identity is wrong"
  parent="$("$GIT" -C "$REPO" rev-parse "$release_commit^")"
  [ "$(plutil -extract sourceCommit raw -o - "$provenance")" = "$parent" ] \
    || die "provenance source commit is not the Daily release parent"
  expected_diff="$("$GIT" -C "$REPO" diff --binary "$release_commit^" "$release_commit" \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [ "$(plutil -extract sourceDiffSHA256 raw -o - "$provenance")" = "$expected_diff" ] \
    || die "provenance source diff does not match the Daily release commit"
  require_green_ci "$release_commit" "Daily release commit"
  printf '%s\t%s\n' "$parent" "$("$GIT" -C "$REPO" show -s --format='%cI' "$release_commit")"
}

if [ -n "$("$GIT" -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]; then
  die "working tree must be clean before Stable promotion"
fi
[ "$("$GIT" -C "$REPO" branch --show-current)" = "$RELEASE_BRANCH" ] \
  || die "promotion must run from $RELEASE_BRANCH"
[ "$("$GIT" -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)" = "origin/$RELEASE_BRANCH" ] \
  || die "$RELEASE_BRANCH must track origin/$RELEASE_BRANCH"
"$GIT" -C "$REPO" fetch --quiet --prune origin "$RELEASE_BRANCH" --tags
[ "$("$GIT" -C "$REPO" rev-parse HEAD)" = "$("$GIT" -C "$REPO" rev-parse "origin/$RELEASE_BRANCH")" ] \
  || die "local $RELEASE_BRANCH must exactly match origin/$RELEASE_BRANCH"
require_green_ci "$("$GIT" -C "$REPO" rev-parse HEAD)" "promotion tooling"

rm -rf "$STAGE"
mkdir -p "$STAGE"
echo "==> snapshotting signed update feed and exact Daily archive"
"$UPDATE_HISTORY" stage "$STAGE"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$STAGE/.appcast-before.xml" \
  || die "the staged live appcast signature is invalid"

ITEMS="$STAGE/.appcast-before-items.tsv"
TARGET_LINES="$(/usr/bin/awk -F '\t' -v version="$VERSION" '$2 == version { print }' "$ITEMS")"
[ "$(printf '%s\n' "$TARGET_LINES" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')" = "1" ] \
  || die "live feed must contain exactly one item for version $VERSION"
TARGET_LINE="$(printf '%s\n' "$TARGET_LINES" | /usr/bin/awk 'NF { print; exit }')"
BUILD="$(field "$TARGET_LINE" 1)"
ZIP_OBJECT="$(field "$TARGET_LINE" 3)"
[ "$ZIP_OBJECT" = "$ARTIFACT_NAME-$VERSION.zip" ] || die "Daily feed uses an unexpected ZIP object"
DMG_OBJECT="$ARTIFACT_NAME-$VERSION.dmg"
CHECKSUM_OBJECT="$ARTIFACT_NAME-$VERSION-$BUILD-SHA256SUMS.txt"
PROVENANCE_OBJECT="$ARTIFACT_NAME-$VERSION-$BUILD-provenance.json"
RECORD_OBJECT="$ARTIFACT_NAME-$VERSION-$BUILD-stable-promotion-authorization.json"

ZIP="$STAGE/$ZIP_OBJECT"
DMG="$STAGE/$DMG_OBJECT"
CHECKSUMS="$STAGE/$CHECKSUM_OBJECT"
PROVENANCE="$STAGE/$PROVENANCE_OBJECT"
ZIP_SHA="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"
DMG_SHA="$(remote_sha256 "$DMG_OBJECT" "$DMG")"
remote_sha256 "$CHECKSUM_OBJECT" "$CHECKSUMS" >/dev/null
PROVENANCE_SHA="$(remote_sha256 "$PROVENANCE_OBJECT" "$PROVENANCE")"
verify_manifest_artifact "$CHECKSUMS" "$ZIP" "$ZIP_OBJECT"
verify_manifest_artifact "$CHECKSUMS" "$DMG" "$DMG_OBJECT"

echo "==> verifying the exact Daily app, DMG, source, and provenance"
UNZIP_DIR="$STAGE/unpacked"
mkdir -p "$UNZIP_DIR"
ditto -x -k "$ZIP" "$UNZIP_DIR"
APP="$UNZIP_DIR/$APP_NAME.app"
[ -d "$APP" ] || die "Daily ZIP does not contain $APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$DMG"
DMG_OUTER_IDENTITY="$(code_identity "$DMG")" || die "could not read Daily DMG signing identity"
[ "$(field "$DMG_OUTER_IDENTITY" 2)" = "${MECHANICIAN_SIGNING_TEAM_ID:-5YPG2C4S34}" ] \
  || die "Daily DMG signing team is not the configured Mechanician team"
hdiutil verify "$DMG" >/dev/null
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
verify_dmg_app_identity "$DMG" "$APP" "$PROVENANCE"
SOURCE_FACTS="$(verify_tag_and_provenance "$BUILD" "$PROVENANCE" "$APP/Contents/Resources/BuildProvenance.json")"
SOURCE_COMMIT="$(field "$SOURCE_FACTS" 1)"
RELEASE_COMMITTED_AT="$(field "$SOURCE_FACTS" 2)"
RELEASE_COMMIT="$("$GIT" -C "$REPO" rev-parse "$RELEASE_TAG_PREFIX$VERSION^{commit}")"
EXPECTED_BUNDLE_ID="$("$GIT" -C "$REPO" show "$RELEASE_COMMIT:$PLIST_REL" | plutil -extract CFBundleIdentifier raw -o - -)"
EXPECTED_TEAM_ID="${MECHANICIAN_SIGNING_TEAM_ID:-5YPG2C4S34}"
[ -n "$EXPECTED_BUNDLE_ID" ] || die "tagged product has no bundle identifier"
require_product_identity "$APP" "ZIP app" "$EXPECTED_BUNDLE_ID" "$EXPECTED_TEAM_ID"
[ "$(plutil -extract bundleIdentifier raw -o - "$PROVENANCE")" = "$EXPECTED_BUNDLE_ID" ] \
  || die "release provenance bundle identifier does not match the tagged product"
ZIP_REMOTE_FACTS="$(remote_object_facts "$ZIP_OBJECT")"
DMG_REMOTE_FACTS="$(remote_object_facts "$DMG_OBJECT")"
ZIP_GENERATION="$(field "$ZIP_REMOTE_FACTS" 1)"
ZIP_CRC="$(field "$ZIP_REMOTE_FACTS" 2)"
DMG_GENERATION="$(field "$DMG_REMOTE_FACTS" 1)"
DMG_CRC="$(field "$DMG_REMOTE_FACTS" 2)"
# Re-download the exact generations that will later be copied to Stable aliases, then bind them to
# the already-validated local artifacts. This closes the validation-to-alias overwrite window.
"$GCLOUD" storage cp "$BUCKET/$ZIP_OBJECT#$ZIP_GENERATION" "$STAGE/generation-bound.zip"
"$GCLOUD" storage cp "$BUCKET/$DMG_OBJECT#$DMG_GENERATION" "$STAGE/generation-bound.dmg"
cmp -s "$ZIP" "$STAGE/generation-bound.zip" || die "validated Daily ZIP generation changed before promotion"
cmp -s "$DMG" "$STAGE/generation-bound.dmg" || die "validated Daily DMG generation changed before promotion"
rm -f "$STAGE/generation-bound.zip" "$STAGE/generation-bound.dmg"
RELEASED_AT="$(printf '%s\n%s\n%s\n' "$RELEASE_COMMITTED_AT" "$(field "$ZIP_REMOTE_FACTS" 3)" "$(field "$DMG_REMOTE_FACTS" 3)" \
  | node -e '
      const fs = require("fs")
      const values = fs.readFileSync(0, "utf8").trim().split(/\n/)
      const times = values.map(value => Date.parse(value))
      if (times.some(value => !Number.isFinite(value))) process.exit(1)
      process.stdout.write(new Date(Math.max(...times)).toISOString())
    ')" || die "could not derive the Daily publication time"

VALIDATOR_ARGS=(
  --attestation "$ATTESTATION"
  --version "$VERSION"
  --build "$BUILD"
  --zip-sha "$ZIP_SHA"
  --dmg-sha "$DMG_SHA"
  --provenance-sha "$PROVENANCE_SHA"
  --source-commit "$SOURCE_COMMIT"
  --released-at "$RELEASED_AT"
)
[ -z "$URGENT_REASON" ] || VALIDATOR_ARGS+=(--urgent-reason "$URGENT_REASON")
RECORD="$STAGE/$RECORD_OBJECT"
node "$ATTESTATION_VALIDATOR" "${VALIDATOR_ARGS[@]}" > "$RECORD"
[ -s "$RECORD" ] || die "promotion attestation did not produce a record"

echo "==> constructing and proving the metadata-only Stable feed"
STATE="$("$UPDATE_HISTORY" prepare-promotion "$STAGE" "$BUILD" "$VERSION")"
case "$STATE" in
  promotion-required)
    "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$STAGE/appcast.xml"
    "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$STAGE/appcast.xml"
    ;;
  already-promoted) ;;
  *) die "unknown promotion state: $STATE" ;;
esac
"$UPDATE_HISTORY" verify-promotion "$STAGE" "$BUILD" "$VERSION"
"$UPDATE_HISTORY" verify-remote "$STAGE"

echo "==> publishing immutable promotion authorization"
"$ARTIFACT_PUBLISHER" upload-immutable "$RECORD" "$RECORD_OBJECT"
if [ "$STATE" = "promotion-required" ]; then
  echo "==> CAS-publishing Stable appcast"
  "$UPDATE_HISTORY" publish "$STAGE"
else
  echo "==> feed already promoted; reconciling only Stable aliases"
fi

echo "==> reconciling Stable aliases from immutable Daily artifacts"
"$ARTIFACT_PUBLISHER" reconcile-stable-aliases "$VERSION" "$BUILD" \
  "$ZIP_GENERATION" "$ZIP_CRC" "$DMG_GENERATION" "$DMG_CRC"
echo "==> exact Daily build $VERSION ($BUILD) is Stable"

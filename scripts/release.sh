#!/usr/bin/env bash
# Cut a Mechanician release end-to-end and publish it to the Sparkle appcast, UNATTENDED.
# (~10-15 min; notarization is the long pole.) Meant to be run without babysitting:
#
#   ./scripts/release.sh 0.7.31              # bump to 0.7.31, auto-increment the build number
#   ./scripts/release.sh 0.7.31 --build 60   # explicit CFBundleVersion
#   ./scripts/release.sh 0.7.31 --channel daily # opt-in Sparkle daily channel
#   ./scripts/release.sh 0.7.31 --resume     # publish an already signed/notarized build
#   NOTARY_PROFILE=my-profile ./scripts/release.sh 0.7.31
#   NO_PUSH=1 ./scripts/release.sh 0.7.31    # notarize + commit locally; don't publish or push
#
# It: verifies the canonical branch and release inputs, bumps the plist locally, builds/signs/
# notarizes every artifact, commits and pushes the exact source, uploads all artifacts, and updates
# the appcast last. A failed build therefore cannot publish a version commit or a partial feed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# FR-103: every identity knob defaults to the public app's historical value. A tenant wrapper sets
# the complete group; release integrity checks below use these variables consistently so a tenant
# release cannot mutate the public plist, sign with the public Sparkle key, or publish to its bucket.
PLIST_REL="${MECHANICIAN_INFO_PLIST_REL:-app/Mechanician-Info.plist}"
PLIST="$REPO/$PLIST_REL"
APP_NAME="${MECHANICIAN_APP_NAME:-Mechanician}"
ARTIFACT_NAME="${MECHANICIAN_ARTIFACT_NAME:-Mechanician}"
APP="$REPO/build/$APP_NAME.app"
STAGE="${MECHANICIAN_UPDATE_STAGE:-$REPO/build/updates}"
BUCKET="${MECHANICIAN_UPDATE_BUCKET:-gs://mechanician-updates}"
URL_PREFIX="${MECHANICIAN_UPDATE_URL_PREFIX:-https://storage.googleapis.com/mechanician-updates/}"
GEN="$REPO/app/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
GENERATE_KEYS="$REPO/app/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
SIGN_UPDATE="${MECHANICIAN_SIGN_UPDATE:-$REPO/app/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
UPDATE_HISTORY="$REPO/scripts/stage-update-history.sh"
ARTIFACT_PUBLISHER="$REPO/scripts/publish-update-artifacts.sh"
PKG_BUILDER="$REPO/scripts/create-enterprise-pkg.sh"
RELEASE_MANIFEST_GENERATOR="$REPO/scripts/generate-release-manifest.mjs"
SPARKLE_ACCOUNT="${MECHANICIAN_SPARKLE_ACCOUNT:-ed25519}"
REQUIRED_CI_CHECK="${MECHANICIAN_REQUIRED_CI_CHECK:-macOS 26 / Apple Silicon}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mechanician-notary}"
RELEASE_COMMIT_PREFIX="${MECHANICIAN_RELEASE_COMMIT_PREFIX:-chore(release)}"
RELEASE_TAG_PREFIX="${MECHANICIAN_RELEASE_TAG_PREFIX:-v}"
RELEASE_NOTES_DIR="${MECHANICIAN_RELEASE_NOTES_DIR:-$REPO/docs/release-notes}"
RELEASE_NOTES_GENERATOR="$REPO/scripts/generate-release-notes.sh"
LATEST_ZIP="$ARTIFACT_NAME-latest.zip"
LATEST_DMG="$ARTIFACT_NAME-latest.dmg"

[[ "$ARTIFACT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || { echo "!! MECHANICIAN_ARTIFACT_NAME must be filesystem/URL safe"; exit 1; }
mkdir -p "$REPO/build"
case "$STAGE" in
  "$REPO/build/"?*) ;;
  *) echo "!! update stage must be one direct child of $REPO/build"; exit 1 ;;
esac
STAGE_NAME="${STAGE#"$REPO/build/"}"
case "$STAGE_NAME" in
  ''|.|..|*/*|*\\*) echo "!! update stage must be one direct build child"; exit 1 ;;
esac

# gcloud lives in Homebrew's bin, which isn't on a non-interactive shell's PATH.
export PATH="/opt/homebrew/bin:$PATH"

# Current Cloud SDK releases require Python 3.10+. macOS still ships 3.9, and a
# non-interactive shell can select it even when Homebrew Python is installed.
if [ -z "${CLOUDSDK_PYTHON:-}" ]; then
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -c \
      'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
      export CLOUDSDK_PYTHON="$candidate"
      break
    fi
  done
fi

# The Homebrew gcloud-crc32c helper can retain a Gatekeeper quarantine bit.
# When macOS blocks it, the helper silently reports CRC32C AAAAAA== (zero) and
# gcloud rejects valid downloads with HashMismatchError. Use Cloud SDK's Python
# checksum implementation instead; it remains fully hash-validated.
export CLOUDSDK_STORAGE_USE_GCLOUD_CRC32C=false

# ---------------------------------------------------------------- args
VERSION="${1:-}"
[ -n "$VERSION" ] || {
  echo "usage: $0 <version> [--build N] [--resume] [--channel stable|daily]"
  echo "       update channel defaults to stable"
  exit 1
}
shift || true
BUILD_OVERRIDE=""
RESUME=0
RELEASE_CHANNEL="stable"
while [ $# -gt 0 ]; do
  case "$1" in
    --build) [ "$#" -ge 2 ] || { echo "!! --build requires a value"; exit 1; }; BUILD_OVERRIDE="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    --channel) [ "$#" -ge 2 ] || { echo "!! --channel requires stable or daily"; exit 1; }; RELEASE_CHANNEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done
[ "$RESUME" -eq 0 ] || [ -z "$BUILD_OVERRIDE" ] \
  || { echo "!! --resume uses the build number already in the app; omit --build"; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "!! version must be a numeric semantic version (for example 0.9.3)"; exit 1; }
[ -z "$BUILD_OVERRIDE" ] || [[ "$BUILD_OVERRIDE" =~ ^[1-9][0-9]*$ ]] \
  || { echo "!! --build must be a positive integer"; exit 1; }
[ "$RELEASE_CHANNEL" = "stable" ] || [ "$RELEASE_CHANNEL" = "daily" ] \
  || { echo "!! --channel must be stable or daily (default: stable)"; exit 1; }
VERSIONED_ZIP="$ARTIFACT_NAME-$VERSION.zip"
VERSIONED_DMG="$ARTIFACT_NAME-$VERSION.dmg"
VERSIONED_PKG="$ARTIFACT_NAME-$VERSION.pkg"
VERSIONED_ZIP_CACHE="$REPO/build/$VERSIONED_ZIP"
VERSION_TAG="$RELEASE_TAG_PREFIX$VERSION"
RELEASE_COMMIT_SUBJECT="$RELEASE_COMMIT_PREFIX: $VERSION"
[ "$RELEASE_CHANNEL" = "stable" ] \
  || RELEASE_COMMIT_SUBJECT="$RELEASE_COMMIT_SUBJECT (daily)"

command -v gcloud >/dev/null || { echo "!! gcloud not found — install the Google Cloud SDK"; exit 1; }
[ -f "$PLIST" ] || { echo "!! no Info.plist at $PLIST"; exit 1; }
[ -x "$GENERATE_KEYS" ] || { echo "!! Sparkle generate_keys missing at $GENERATE_KEYS"; exit 1; }
[ -x "$SIGN_UPDATE" ] || { echo "!! Sparkle sign_update missing at $SIGN_UPDATE"; exit 1; }
[ -x "$UPDATE_HISTORY" ] || { echo "!! update-history helper missing at $UPDATE_HISTORY"; exit 1; }
[ -x "$ARTIFACT_PUBLISHER" ] || { echo "!! artifact publisher missing at $ARTIFACT_PUBLISHER"; exit 1; }
[ -x "$PKG_BUILDER" ] || { echo "!! enterprise package builder missing at $PKG_BUILDER"; exit 1; }
[ -x "$RELEASE_MANIFEST_GENERATOR" ] \
  || { echo "!! release manifest generator missing at $RELEASE_MANIFEST_GENERATOR"; exit 1; }
[ -x "$RELEASE_NOTES_GENERATOR" ] \
  || { echo "!! release-note generator missing at $RELEASE_NOTES_GENERATOR"; exit 1; }
case "$URL_PREFIX" in */) ;; *) URL_PREFIX="$URL_PREFIX/" ;; esac
PLIST_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST" 2>/dev/null || true)"
PLIST_PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
[ "$PLIST_FEED_URL" = "${URL_PREFIX}appcast.xml" ] \
  || { echo "!! plist feed $PLIST_FEED_URL does not match ${URL_PREFIX}appcast.xml"; exit 1; }
KEYCHAIN_PUBLIC_ED_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
[ "$PLIST_PUBLIC_ED_KEY" = "$KEYCHAIN_PUBLIC_ED_KEY" ] \
  || { echo "!! plist Sparkle key does not match Keychain account $SPARKLE_ACCOUNT"; exit 1; }

signed_app_identity() {
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

verify_cached_dmg_app() (
  local dmg="$1" expected_app="$2" expected_provenance="$3"
  local attach_plist mount_json mount_path canonical_mount volume_root relative_mount
  local dmg_app expected_identity actual_identity
  mount_path=""
  cleanup_cached_dmg() {
    [ -z "$mount_path" ] || hdiutil detach "$mount_path" >/dev/null 2>&1 || true
  }
  trap cleanup_cached_dmg EXIT
  attach_plist="$(mktemp "${TMPDIR:-/tmp}/mechanician-release-dmg.plist.XXXXXX")" || return 1
  hdiutil attach -readonly -nobrowse -noautoopen -plist "$dmg" > "$attach_plist" || return 1
  mount_json="$(plutil -convert json -o - "$attach_plist")" || return 1
  rm -f "$attach_plist"
  mount_path="$(printf '%s' "$mount_json" | node -e '
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
  ')" || return 1
  volume_root="$(cd /Volumes && pwd -P)" || return 1
  canonical_mount="$(cd "$mount_path" && pwd -P)" || return 1
  case "$canonical_mount" in "$volume_root/"?*) ;; *) return 1 ;; esac
  relative_mount="${canonical_mount#"$volume_root/"}"
  case "$relative_mount" in ''|*/*) return 1 ;; esac
  mount_path="$canonical_mount"
  dmg_app="$mount_path/$APP_NAME.app"
  [ -d "$dmg_app" ] || return 1
  codesign --verify --deep --strict "$dmg_app" || return 1
  cmp -s "$expected_provenance" "$dmg_app/Contents/Resources/BuildProvenance.json" || return 1
  expected_identity="$(signed_app_identity "$expected_app")" || return 1
  actual_identity="$(signed_app_identity "$dmg_app")" || return 1
  [ "$expected_identity" = "$actual_identity" ] || return 1
)

# ---------------------------------------------------------------- 0. verify canonical source and a CLEAN working tree
# The release builds from the working tree, so any uncommitted change would ship in the binary with
# NO matching git history — and the release notes (generated from commits since the last release)
# would come out empty. Refuse to run until the tree is committed; the ONLY change this script then
# introduces is its own version bump. Ignored build output is harmless; every other untracked file
# is rejected because SwiftPM and shell tooling can consume files that git does not know about.
if [ -n "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "!! working tree has uncommitted changes — commit or stash them before releasing."
  git -C "$REPO" status --short --untracked-files=all
  exit 1
fi

RELEASE_BRANCH="${MECHANICIAN_RELEASE_BRANCH:-main}"
CURRENT_BRANCH="$(git -C "$REPO" branch --show-current)"
[ "$CURRENT_BRANCH" = "$RELEASE_BRANCH" ] \
  || { echo "!! releases must be cut from $RELEASE_BRANCH (currently $CURRENT_BRANCH)"; exit 1; }
UPSTREAM="$(git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
[ "$UPSTREAM" = "origin/$RELEASE_BRANCH" ] \
  || { echo "!! $RELEASE_BRANCH must track origin/$RELEASE_BRANCH (found ${UPSTREAM:-none})"; exit 1; }
git -C "$REPO" fetch --quiet --prune origin "$RELEASE_BRANCH" --tags
[ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse "$UPSTREAM")" ] \
  || { echo "!! local $RELEASE_BRANCH is not identical to $UPSTREAM — pull/push before releasing"; exit 1; }

# A release must never outrun CI. Four consecutive 0.10.x builds shipped to auto-updating users from
# a red main because the result existed and nothing read it.
CI_GATE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
if [ -n "${MECHANICIAN_SKIP_CI_GATE:-}" ]; then
  echo "!! MECHANICIAN_SKIP_CI_GATE is set; publishing without green CI for ${CI_GATE_COMMIT:0:12}"
elif ! command -v gh >/dev/null; then
  echo "!! the GitHub CLI is required to verify CI before release"
  echo "   (set MECHANICIAN_SKIP_CI_GATE=1 to override deliberately)"; exit 1
else
  echo "==> CI status for ${CI_GATE_COMMIT:0:12}"
  # A commit can be pushed to dev and then fast-forwarded to main. Check-runs are keyed only by
  # SHA, so querying them directly sees both workflows and makes a green main release look
  # ambiguous. Choose the one push workflow run for the canonical release branch first, then
  # verify the required job inside that run.
  CI_RUNS=""
  if CI_RESPONSE="$(gh api "repos/{owner}/{repo}/actions/runs?head_sha=$CI_GATE_COMMIT&event=push&per_page=100" \
      --jq '.workflow_runs[] | "\(.id)\t\(.head_branch)\t\(.head_sha)\t\(.status // "pending")\t\(.conclusion // "pending")"' 2>/dev/null)"; then
    CI_RUNS="$CI_RESPONSE"
  fi
  CI_MAIN_RUNS="$(printf '%s\n' "$CI_RUNS" | /usr/bin/awk -F '\t' -v branch="$RELEASE_BRANCH" -v commit="$CI_GATE_COMMIT" \
    '$2 == branch && $3 == commit { print }')"
  CI_MAIN_RUN_COUNT="$(printf '%s\n' "$CI_MAIN_RUNS" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
  [ "$CI_MAIN_RUN_COUNT" = "1" ] \
    || { echo "!! expected one push CI run on $RELEASE_BRANCH for $CI_GATE_COMMIT, found $CI_MAIN_RUN_COUNT"
         echo "   (set MECHANICIAN_SKIP_CI_GATE=1 to override deliberately)"; exit 1; }
  CI_RUN_ID="$(printf '%s\n' "$CI_MAIN_RUNS" | /usr/bin/cut -f1)"
  CI_RUN_STATUS="$(printf '%s\n' "$CI_MAIN_RUNS" | /usr/bin/cut -f4)"
  CI_RUN_CONCLUSION="$(printf '%s\n' "$CI_MAIN_RUNS" | /usr/bin/cut -f5)"
  if [ "$CI_RUN_STATUS" != "completed" ] || [ "$CI_RUN_CONCLUSION" != "success" ]; then
    echo "!! CI run $CI_RUN_ID on $RELEASE_BRANCH is not successful for $CI_GATE_COMMIT: ${CI_RUN_CONCLUSION:-pending}"
    echo "   (set MECHANICIAN_SKIP_CI_GATE=1 to override deliberately)"
    exit 1
  fi

  # gh prints its error body on stdout and exits nonzero, so branch on the exit status: an
  # unobservable or unfinished job must not look like a passing check list.
  CI_CHECKS=""
  if CI_RESPONSE="$(gh api "repos/{owner}/{repo}/actions/runs/$CI_RUN_ID/jobs?per_page=100" \
      --jq '.jobs[] | "\(.conclusion // "pending")\t\(.name)"' 2>/dev/null)"; then
    CI_CHECKS="$CI_RESPONSE"
  fi
  [ -n "$CI_CHECKS" ] \
    || { echo "!! no CI jobs found in main run $CI_RUN_ID for $CI_GATE_COMMIT"
         echo "   (set MECHANICIAN_SKIP_CI_GATE=1 to override deliberately)"; exit 1; }
  CI_REQUIRED_COUNT="$(printf '%s\n' "$CI_CHECKS" | /usr/bin/awk -F '\t' -v name="$REQUIRED_CI_CHECK" '$2 == name { count++ } END { print count + 0 }')"
  CI_REQUIRED_CONCLUSION="$(printf '%s\n' "$CI_CHECKS" | /usr/bin/awk -F '\t' -v name="$REQUIRED_CI_CHECK" '$2 == name { print $1 }')"
  if [ "$CI_REQUIRED_COUNT" != "1" ] || [ "$CI_REQUIRED_CONCLUSION" != "success" ]; then
    echo "!! required CI check is not uniquely successful for $CI_GATE_COMMIT: $REQUIRED_CI_CHECK"
    echo "   (set MECHANICIAN_SKIP_CI_GATE=1 to override deliberately)"
    exit 1
  fi
  printf '    main push run %s\n' "$CI_RUN_ID"
  printf '    %s\n' "$CI_CHECKS"
fi

# The release transaction is long enough for another process to advance this checkout after CI was
# verified. A clean status is not sufficient: the version bump can still be the only worktree change
# while HEAD names an unverified commit. Bind both the checkout and the signed bundle to the exact
# source commit whose CI result was accepted.
verify_gated_release_source() {
  CURRENT_SOURCE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
  CURRENT_SOURCE_DIFF="$(git -C "$REPO" diff --binary HEAD | /usr/bin/shasum -a 256 | awk '{print $1}')"
  [ "$CURRENT_SOURCE_COMMIT" = "$CI_GATE_COMMIT" ] \
    || { echo "!! source HEAD changed from CI-gated commit $CI_GATE_COMMIT to $CURRENT_SOURCE_COMMIT during release"; return 1; }
  [ "$PROVENANCE_SOURCE" = "$CI_GATE_COMMIT" ] \
    || { echo "!! release app provenance does not name the CI-gated source commit"; return 1; }
  [ "$PROVENANCE_DIFF" = "$CURRENT_SOURCE_DIFF" ] \
    || { echo "!! release app provenance does not match the current release source diff"; return 1; }
}

CUR_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
CUR_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

version_greater_than() {
  local candidate="$1" current="$2" c_major c_minor c_patch o_major o_minor o_patch
  IFS=. read -r c_major c_minor c_patch <<< "$candidate"
  IFS=. read -r o_major o_minor o_patch <<< "$current"
  [ "$c_major" -gt "$o_major" ] ||
    { [ "$c_major" -eq "$o_major" ] && [ "$c_minor" -gt "$o_minor" ]; } ||
    { [ "$c_major" -eq "$o_major" ] && [ "$c_minor" -eq "$o_minor" ] && [ "$c_patch" -gt "$o_patch" ]; }
}

if [ "$RESUME" -eq 0 ]; then
  version_greater_than "$VERSION" "$CUR_VERSION" \
    || { echo "!! release $VERSION must be newer than source version $CUR_VERSION"; exit 1; }
  if git -C "$REPO" rev-parse -q --verify "refs/tags/$VERSION_TAG" >/dev/null; then
    echo "!! tag $VERSION_TAG already exists — use a new version"
    exit 1
  fi
elif git -C "$REPO" rev-parse -q --verify "refs/tags/$VERSION_TAG" >/dev/null; then
  [ "$(git -C "$REPO" rev-list -n 1 "$VERSION_TAG")" = "$(git -C "$REPO" rev-parse HEAD)" ] \
    || { echo "!! existing tag $VERSION_TAG does not point at HEAD"; exit 1; }
fi

if [ "$RESUME" -eq 1 ]; then
  # Resume only the publishing half of a release that already completed its
  # expensive build/sign/notarize steps. Refuse stale or mismatched bundles.
  [ "$CUR_VERSION" = "$VERSION" ] \
    || { echo "!! source plist is $CUR_VERSION, not requested version $VERSION"; exit 1; }
  [ -d "$APP" ] || { echo "!! no app at $APP — cannot resume"; exit 1; }
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  [ "$APP_VERSION" = "$VERSION" ] && [ "$APP_BUILD" = "$CUR_BUILD" ] \
    || { echo "!! built app is $APP_VERSION ($APP_BUILD), expected $VERSION ($CUR_BUILD)"; exit 1; }

  # A resumable bundle is tied to the exact release commit. build-app.sh runs before that commit is
  # created, so its provenance records the commit's parent plus the SHA-256 of the version-only
  # worktree diff. Verify both halves before trusting an expensive artifact left in build/.
  [ "$(git -C "$REPO" log -1 --format='%s')" = "$RELEASE_COMMIT_SUBJECT" ] \
    || { echo "!! --resume requires HEAD to be $RELEASE_COMMIT_SUBJECT"; exit 1; }
  [ "$(git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD)" = "$PLIST_REL" ] \
    || { echo "!! release commit contains files other than the version plist"; exit 1; }
  PROVENANCE_IN_APP="$APP/Contents/Resources/BuildProvenance.json"
  [ -f "$PROVENANCE_IN_APP" ] \
    || { echo "!! built app has no provenance record — cannot resume safely"; exit 1; }
  PROVENANCE_SOURCE="$(plutil -extract sourceCommit raw -o - "$PROVENANCE_IN_APP")"
  PROVENANCE_DIFF="$(plutil -extract sourceDiffSHA256 raw -o - "$PROVENANCE_IN_APP")"
  RELEASE_PARENT="$(git -C "$REPO" rev-parse HEAD^)"
  RELEASE_DIFF="$(git -C "$REPO" diff --binary HEAD^ HEAD | /usr/bin/shasum -a 256 | awk '{print $1}')"
  [ "$PROVENANCE_SOURCE" = "$RELEASE_PARENT" ] && [ "$PROVENANCE_DIFF" = "$RELEASE_DIFF" ] \
    || { echo "!! existing app provenance does not match the release commit"; exit 1; }

  NEW_BUILD="$CUR_BUILD"
  echo "==> resuming $VERSION (build $NEW_BUILD) from existing notarized app"
  codesign --verify --deep --strict "$APP"
  spctl --assess --type execute "$APP"
  xcrun stapler validate "$APP"
else
  # -------------------------------------------------------------- 1. bump version + build number
  # The build number must be monotonic against BOTH the local plist AND what is actually published.
  # A release commit that never reached origin (an interrupted or NO_PUSH run) leaves the local plist
  # behind the live feed; deriving from the plist alone then reuses an already-published build, which
  # Sparkle silently refuses to offer as an update. Taking the max of both makes that collision
  # impossible — so `--build N` is never needed by hand, and the 160/161/162 confusion cannot recur.
  LIVE_BUILD=0
  if LIVE_FEED="$(curl -fsS --max-time 20 "${URL_PREFIX}appcast.xml" 2>/dev/null)"; then
    LIVE_BUILD="$(printf '%s' "$LIVE_FEED" | grep -oE '<sparkle:version>[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)"
    [ -n "$LIVE_BUILD" ] || LIVE_BUILD=0
    echo "==> highest published build on the live feed: $LIVE_BUILD"
  else
    echo "==> could not read the live feed; deriving the build from the local plist only"
  fi
  BASELINE_BUILD="$CUR_BUILD"
  [ "$LIVE_BUILD" -gt "$BASELINE_BUILD" ] && BASELINE_BUILD="$LIVE_BUILD"
  NEW_BUILD="${BUILD_OVERRIDE:-$((BASELINE_BUILD + 1))}"
  { [ "$NEW_BUILD" -gt "$CUR_BUILD" ] && [ "$NEW_BUILD" -gt "$LIVE_BUILD" ]; } \
    || { echo "!! build $NEW_BUILD must exceed both the local plist ($CUR_BUILD) and the published build ($LIVE_BUILD)"; exit 1; }
  echo "==> releasing $VERSION (local build $CUR_BUILD, live build $LIVE_BUILD -> $NEW_BUILD)"
  PLIST_BACKUP="$(mktemp "${TMPDIR:-/tmp}/mechanician-release-plist.XXXXXX")"
  cp "$PLIST" "$PLIST_BACKUP"
  VERSION_COMMITTED=0
  restore_uncommitted_version() {
    status=$?
    trap - EXIT
    if [ "$status" -ne 0 ] && [ "$VERSION_COMMITTED" -eq 0 ]; then
      git -C "$REPO" restore --staged -- "$PLIST_REL" 2>/dev/null || true
      cp "$PLIST_BACKUP" "$PLIST"
      echo "!! release failed before commit; restored $PLIST_REL" >&2
    fi
    rm -f "$PLIST_BACKUP"
    exit "$status"
  }
  trap restore_uncommitted_version EXIT
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

  # -------------------------------------------------------------- 2. assemble + sign + notarize
  echo "==> build-app.sh (sign + notarize + staple — the long pole)"
  MECHANICIAN_INFO_PLIST="$PLIST" MECHANICIAN_DISTRIBUTION_BUILD=1 \
    MECHANICIAN_NOTARY_PROFILE="$NOTARY_PROFILE" "$REPO/build-app.sh"
fi

# ---------------------------------------------------------------- 4. create and verify every local release artifact
[ -x "$GEN" ] || { echo "!! generate_appcast missing at $GEN"; exit 1; }
[ -d "$APP" ] || { echo "!! no app at $APP — build-app.sh must have failed"; exit 1; }
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$APP_VERSION" = "$VERSION" ] && [ "$APP_BUILD" = "$NEW_BUILD" ] \
  || { echo "!! built app is $APP_VERSION ($APP_BUILD), expected $VERSION ($NEW_BUILD)"; exit 1; }
PROVENANCE_IN_APP="$APP/Contents/Resources/BuildProvenance.json"
[ -f "$PROVENANCE_IN_APP" ] \
  || { echo "!! release app has no provenance record"; exit 1; }
[ "$(plutil -extract dogfood raw -o - "$PROVENANCE_IN_APP")" = "false" ] \
  || { echo "!! refusing to publish an app stamped as dogfood"; exit 1; }
if [ "$RESUME" -eq 0 ]; then
  PROVENANCE_SOURCE="$(plutil -extract sourceCommit raw -o - "$PROVENANCE_IN_APP")"
  PROVENANCE_DIFF="$(plutil -extract sourceDiffSHA256 raw -o - "$PROVENANCE_IN_APP")"
  verify_gated_release_source
fi
# This is a disposable publishing stage. Starting clean prevents generate_appcast's
# old_updates/ directory from being re-ingested and duplicated on every release.
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "==> staging signed branch heads from $BUCKET (for delta generation)"
"$UPDATE_HISTORY" stage "$STAGE"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$STAGE/.appcast-before.xml" \
  || { echo "!! staged live appcast signature is invalid"; exit 1; }

# If a prior run published the appcast and then stopped during the mutable alias copies, remember
# that state but continue through every cached and remote artifact proof before touching aliases.
PUBLISHED_RESUME=""
if [ "$RESUME" -eq 1 ]; then
  PUBLISHED_LINE="$(/usr/bin/awk -F '\t' -v build="$NEW_BUILD" '$1 == build { print }' \
    "$STAGE/.appcast-before-items.tsv")"
  if [ -n "$PUBLISHED_LINE" ]; then
    [ "$(printf '%s\n' "$PUBLISHED_LINE" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')" = "1" ] \
      || { echo "!! live feed has ambiguous build $NEW_BUILD"; exit 1; }
    [ "$(printf '%s\n' "$PUBLISHED_LINE" | /usr/bin/cut -f2)" = "$VERSION" ] \
      || { echo "!! live build $NEW_BUILD has a different version"; exit 1; }
    PUBLISHED_CHANNEL="$(printf '%s\n' "$PUBLISHED_LINE" | /usr/bin/cut -f12)"
    if [ "$RELEASE_CHANNEL" = "stable" ] && [ -z "$PUBLISHED_CHANNEL" ]; then
      PUBLISHED_RESUME="stable"
    elif [ "$RELEASE_CHANNEL" = "daily" ] && [ "$PUBLISHED_CHANNEL" = "daily" ]; then
      PUBLISHED_RESUME="daily"
    else
      echo "!! live build $NEW_BUILD is published on channel ${PUBLISHED_CHANNEL:-stable}, not $RELEASE_CHANNEL"
      exit 1
    fi
  fi
fi

ZIP="$STAGE/$VERSIONED_ZIP"
if [ "$RESUME" -eq 1 ]; then
  [ -s "$VERSIONED_ZIP_CACHE" ] \
    || { echo "!! exact cached ZIP is missing at $VERSIONED_ZIP_CACHE; cannot resume immutable upload"; exit 1; }
  ZIP_CHECK="$(mktemp -d "${TMPDIR:-/tmp}/mechanician-release-zip.XXXXXX")"
  ditto -x -k "$VERSIONED_ZIP_CACHE" "$ZIP_CHECK"
  CACHED_APP="$ZIP_CHECK/$APP_NAME.app"
  [ -d "$CACHED_APP" ] \
    || { echo "!! cached release ZIP does not contain $APP_NAME.app"; exit 1; }
  codesign --verify --deep --strict "$CACHED_APP"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CACHED_APP/Contents/Info.plist")" = "$VERSION" ] \
    && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CACHED_APP/Contents/Info.plist")" = "$NEW_BUILD" ] \
    || { echo "!! cached release ZIP has the wrong version/build"; exit 1; }
  cmp -s "$PROVENANCE_IN_APP" "$CACHED_APP/Contents/Resources/BuildProvenance.json" \
    || { echo "!! cached release ZIP provenance differs from the release app"; exit 1; }
  EXPECTED_APP_IDENTITY="$(signed_app_identity "$APP")" \
    || { echo "!! could not read release app signing identity"; exit 1; }
  CACHED_APP_IDENTITY="$(signed_app_identity "$CACHED_APP")" \
    || { echo "!! could not read cached ZIP app signing identity"; exit 1; }
  [ "$EXPECTED_APP_IDENTITY" = "$CACHED_APP_IDENTITY" ] \
    || { echo "!! cached release ZIP app identity differs from the release app"; exit 1; }
  rm -rf "$ZIP_CHECK"
  echo "==> reusing exact cached ZIP -> $(basename "$ZIP")"
else
  echo "==> zipping app -> $(basename "$VERSIONED_ZIP_CACHE")"
  rm -f "$VERSIONED_ZIP_CACHE"
  ditto -c -k --keepParent "$APP" "$VERSIONED_ZIP_CACHE"
fi
cp "$VERSIONED_ZIP_CACHE" "$ZIP"

# Release notes for the in-app update panel (it renders the appcast item's <description>).
# A hand-written docs/release-notes/<version>.html wins; otherwise generate a bullet list
# from the commit subjects since the previous release commit.
NOTES="$STAGE/$ARTIFACT_NAME-$VERSION.html"
if [ -n "$PUBLISHED_RESUME" ]; then
  echo "==> appcast already published; skipping release-note and appcast regeneration"
elif [ -f "$RELEASE_NOTES_DIR/$VERSION.html" ]; then
  cp "$RELEASE_NOTES_DIR/$VERSION.html" "$NOTES"
  echo "==> release notes: $RELEASE_NOTES_DIR/$VERSION.html"
else
  # The new release commit is deliberately created only after artifact verification, so HEAD here
  # is still the last source change. On --resume, HEAD is that release commit, so use its parent as
  # the notes tip; otherwise the release would become its own boundary and produce empty notes.
  NOTES_HEAD="HEAD"
  [ "$RESUME" -eq 0 ] || NOTES_HEAD="HEAD^"
  # The live leader of the channel being released is the notes boundary. Resolve its version tag
  # rather than inferring releases from commit-subject prefixes: an integration commit may share
  # that prefix, and exact-artifact promotion retains the original `(daily)` release commit.
  PREV_CHANNEL_VERSION="$("$RELEASE_NOTES_GENERATOR" --channel-leader \
    "$STAGE/.appcast-before-items.tsv" "$RELEASE_CHANNEL")"
  if [ -n "$PREV_CHANNEL_VERSION" ]; then
    PREV_CHANNEL_TAG="$RELEASE_TAG_PREFIX$PREV_CHANNEL_VERSION"
    PREV_RELEASE="$(git -C "$REPO" rev-parse -q --verify "refs/tags/$PREV_CHANNEL_TAG^{commit}" 2>/dev/null || true)"
    [ -n "$PREV_RELEASE" ] \
      || { echo "!! live $RELEASE_CHANNEL release $PREV_CHANNEL_VERSION has no tag $PREV_CHANNEL_TAG"; exit 1; }
    git -C "$REPO" merge-base --is-ancestor "$PREV_RELEASE" "$NOTES_HEAD" \
      || { echo "!! live $RELEASE_CHANNEL tag $PREV_CHANNEL_TAG is not an ancestor of $NOTES_HEAD"; exit 1; }
  else
    PREV_RELEASE=""
  fi
  RANGE="${PREV_RELEASE:+$PREV_RELEASE..}$NOTES_HEAD"
  "$RELEASE_NOTES_GENERATOR" "$REPO" "$RANGE" "$RELEASE_COMMIT_PREFIX" "$VERSION" > "$NOTES"
  echo "==> release notes: generated from $(git -C "$REPO" rev-list --count "$RANGE") commit(s)"
fi

if [ -z "$PUBLISHED_RESUME" ]; then
  echo "==> generate_appcast (EdDSA sign; binary-delta computation is the slow step)"
  MAXIMUM_DELTAS=1
  DAILY_HEAD_COUNT="$(/usr/bin/xmllint --nonet --xpath \
    "count(/rss/channel/item/*[local-name()='channel' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle' and text()='daily'])" \
    "$STAGE/.appcast-before.xml")"
  [ "$DAILY_HEAD_COUNT" = "0" ] || MAXIMUM_DELTAS=2
  echo "    generating up to $MAXIMUM_DELTAS direct channel-head delta(s)"
  if [ "$RELEASE_CHANNEL" = "daily" ]; then
    "$GEN" --account "$SPARKLE_ACCOUNT" --download-url-prefix "$URL_PREFIX" --embed-release-notes \
      --versions "$NEW_BUILD" --maximum-versions 1 --maximum-deltas "$MAXIMUM_DELTAS" --channel daily "$STAGE"
  else
    "$GEN" --account "$SPARKLE_ACCOUNT" --download-url-prefix "$URL_PREFIX" --embed-release-notes \
      --versions "$NEW_BUILD" --maximum-versions 1 --maximum-deltas "$MAXIMUM_DELTAS" "$STAGE"
  fi
  # generate_appcast recalculates every staged branch's deltas, even when this release did not change
  # that branch. Restore each surviving old item byte-for-byte, then sign the resulting feed; only the
  # new item and its two direct upgrade paths are allowed to change.
  "$UPDATE_HISTORY" preserve-unaffected "$STAGE" "$NEW_BUILD"
  "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$STAGE/appcast.xml"
  "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$STAGE/appcast.xml"
  "$UPDATE_HISTORY" verify-transition "$STAGE" "$NEW_BUILD" "$VERSION" "$RELEASE_CHANNEL"
  rm -f "$NOTES"   # embedded into the appcast — don't leave it to be uploaded as an artifact
fi

DMG="$REPO/build/$VERSIONED_DMG"
# Every channel produces an immutable versioned DMG from the exact signed app. Daily leaves the
# website aliases alone, but retaining its already-signed/notarized DMG is what makes a later
# metadata-only Daily -> Stable promotion possible without rebuilding, re-signing, or notarizing.
# Build it OUTSIDE $STAGE so generate_appcast cannot ingest it.
[ "$RELEASE_CHANNEL" != "daily" ] \
  || echo "==> daily channel: retaining a promotable DMG without touching Stable aliases"
echo "==> building versioned DMG: $VERSIONED_DMG"
if [ "$RESUME" -eq 1 ]; then
  [ -s "$DMG" ] \
    || { echo "!! exact cached DMG is missing at $DMG; cannot resume immutable upload"; exit 1; }
  echo "==> reusing exact signed/notarized versioned DMG"
else
  "$REPO/scripts/create-dmg.sh" "$APP" "$DMG"
  SIGNING_TEAM_ID="${MECHANICIAN_SIGNING_TEAM_ID:-5YPG2C4S34}"
  if [ -n "${MECHANICIAN_SIGNING_IDENTITY:-}" ]; then
    DEVID="$MECHANICIAN_SIGNING_IDENTITY"
  else
    DEVID="$(security find-identity -v -p codesigning \
      | sed -n "s/.*\"\(Developer ID Application:[^\"]*(${SIGNING_TEAM_ID})\)\".*/\1/p" | head -1)"
  fi
  [ -n "$DEVID" ] || { echo "!! no Developer ID Application identity for team $SIGNING_TEAM_ID"; exit 1; }
  codesign --force --timestamp --sign "$DEVID" "$DMG"
  echo "==> notarizing and stapling versioned DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
codesign --verify --strict --verbose=2 "$DMG"
hdiutil verify "$DMG" >/dev/null
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
if [ "$RESUME" -eq 1 ]; then
  verify_cached_dmg_app "$DMG" "$APP" "$PROVENANCE_IN_APP" \
    || { echo "!! cached DMG does not contain the exact release app"; exit 1; }
fi

# The installer package is an enterprise distribution artifact, not a second app build. It wraps
# the exact already-signed standard app and intentionally contains no tenant profile or policy.
PKG="$REPO/build/$VERSIONED_PKG"
echo "==> building enterprise installer package: $VERSIONED_PKG"
if [ "$RESUME" -eq 1 ]; then
  [ -s "$PKG" ] \
    || { echo "!! exact cached installer package is missing at $PKG; cannot resume immutable upload"; exit 1; }
  echo "==> reusing exact signed/notarized installer package"
else
  "$PKG_BUILDER" "$APP" "$PKG"
  echo "==> notarizing and stapling enterprise installer package"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
/usr/sbin/pkgutil --check-signature "$PKG"
xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=2 "$PKG"

codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
[ -s "$ZIP" ] || { echo "!! release zip was not created"; exit 1; }
[ -s "$STAGE/appcast.xml" ] || { echo "!! signed appcast was not created"; exit 1; }
grep -q "<sparkle:shortVersionString>$VERSION<" "$STAGE/appcast.xml" \
  || { echo "!! generated appcast does not contain $VERSION"; exit 1; }

DSYM_ZIP="$REPO/build/$ARTIFACT_NAME-$VERSION-$NEW_BUILD.dSYM.zip"
if [ "$RESUME" -eq 1 ]; then
  [ -s "$DSYM_ZIP" ] \
    || { echo "!! exact cached dSYM archive is missing at $DSYM_ZIP; cannot reproduce checksums"; exit 1; }
  echo "==> reusing exact cached dSYM archive"
else
  DSYM="$REPO/build/$APP_NAME.app.dSYM"
  [ -d "$DSYM" ] || { echo "!! release dSYM missing at $DSYM"; exit 1; }
  rm -f "$DSYM_ZIP"
  ditto -c -k --keepParent "$DSYM" "$DSYM_ZIP"
fi
[ -s "$DSYM_ZIP" ] || { echo "!! failed to archive release dSYM"; exit 1; }

PROVENANCE="$REPO/build/$ARTIFACT_NAME-$VERSION-$NEW_BUILD-provenance.json"
SBOM="$REPO/build/$ARTIFACT_NAME-$VERSION-$NEW_BUILD-sbom.cdx.json"
cp "$APP/Contents/Resources/BuildProvenance.json" "$PROVENANCE"
cp "$APP/Contents/Resources/Licenses/agentd-sbom.cdx.json" "$SBOM"
CHECKSUMS="$REPO/build/$ARTIFACT_NAME-$VERSION-$NEW_BUILD-SHA256SUMS.txt"
: > "$CHECKSUMS"
CHECKSUM_ARTIFACTS=("$ZIP" "$DSYM_ZIP" "$DMG" "$PKG" "$PROVENANCE" "$SBOM")
for artifact in "${CHECKSUM_ARTIFACTS[@]}"; do
  hash="$(/usr/bin/shasum -a 256 "$artifact" | awk '{print $1}')"
  bytes="$(stat -f '%z' "$artifact")"
  printf '%s  %s  %s\n' "$hash" "$bytes" "$(basename "$artifact")" >> "$CHECKSUMS"
done
RELEASE_MANIFEST="$REPO/build/$ARTIFACT_NAME-$VERSION-$NEW_BUILD-release.json"
"$RELEASE_MANIFEST_GENERATOR" \
  --app "$APP" \
  --base-url "$URL_PREFIX" \
  --output "$RELEASE_MANIFEST" \
  --artifact "zip=$ZIP" \
  --artifact "dmg=$DMG" \
  --artifact "pkg=$PKG" \
  --artifact "checksums=$CHECKSUMS" \
  --artifact "provenance=$PROVENANCE" \
  --artifact "sbom=$SBOM"

# Commit only after every expensive local operation succeeds. Until this point, the EXIT trap
# restores the plist on failure, avoiding the dead release commits that older runs left behind.
if [ "$RESUME" -eq 0 ]; then
  verify_gated_release_source
  RELEASE_STATUS="$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)"
  [ "$RELEASE_STATUS" = " M $PLIST_REL" ] && git -C "$REPO" diff --cached --quiet \
    || { echo "!! source changed during release; refusing to commit or publish"; exit 1; }
  git -C "$REPO" add "$PLIST_REL"
  git -C "$REPO" commit -m "$RELEASE_COMMIT_SUBJECT"
  VERSION_COMMITTED=1
  RELEASE_PARENT="$(git -C "$REPO" rev-parse HEAD^)"
  RELEASE_DIFF="$(git -C "$REPO" diff --binary HEAD^ HEAD | /usr/bin/shasum -a 256 | awk '{print $1}')"
  [ "$RELEASE_PARENT" = "$CI_GATE_COMMIT" ] \
    || { echo "!! release commit parent is not the CI-gated source commit; refusing to publish"; exit 1; }
  [ "$PROVENANCE_SOURCE" = "$RELEASE_PARENT" ] \
    && [ "$PROVENANCE_DIFF" = "$RELEASE_DIFF" ] \
    || { echo "!! release app provenance does not match the release commit; refusing to publish"; exit 1; }
  [ "$(git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD)" = "$PLIST_REL" ] \
    || { echo "!! release commit contains files other than the version plist"; exit 1; }
  [ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ] \
    || { echo "!! commit hooks changed the source; refusing to publish"; exit 1; }
  trap - EXIT
  rm -f "$PLIST_BACKUP"
fi

if [ -n "${NO_PUSH:-}" ]; then
  echo "==> NO_PUSH set: notarized local build and commit are ready; no update artifacts or git refs were published"
  exit 0
fi

# Make the exact release source available before publishing binaries. Fail hard: a release must
# never be downloadable without its corresponding source commit on the canonical branch.
git -C "$REPO" push --porcelain origin "$RELEASE_BRANCH"

# ---------------------------------------------------------------- 5. upload every artifact while the old appcast remains live
echo "==> publishing immutable versioned artifacts"
"$ARTIFACT_PUBLISHER" upload-immutable "$ZIP" "$VERSIONED_ZIP"
"$ARTIFACT_PUBLISHER" upload-immutable "$DMG" "$VERSIONED_DMG"
"$ARTIFACT_PUBLISHER" upload-immutable "$PKG" "$VERSIONED_PKG"
"$ARTIFACT_PUBLISHER" upload-immutable "$CHECKSUMS" "$(basename "$CHECKSUMS")"
"$ARTIFACT_PUBLISHER" upload-immutable "$PROVENANCE" "$(basename "$PROVENANCE")"
"$ARTIFACT_PUBLISHER" upload-immutable "$SBOM" "$(basename "$SBOM")"
"$ARTIFACT_PUBLISHER" upload-immutable "$RELEASE_MANIFEST" "$(basename "$RELEASE_MANIFEST")"
ZIP_REMOTE_FACTS="$("$ARTIFACT_PUBLISHER" object-facts "$VERSIONED_ZIP")"
DMG_REMOTE_FACTS="$("$ARTIFACT_PUBLISHER" object-facts "$VERSIONED_DMG")"

echo "==> uploading generated deltas"
shopt -s nullglob
new_deltas=("$STAGE"/*.delta)
if [ -n "$PUBLISHED_RESUME" ]; then
  echo "   (appcast already published; no delta publication remains)"
elif [ ${#new_deltas[@]} -gt 0 ]; then
  for delta in "${new_deltas[@]}"; do
    "$ARTIFACT_PUBLISHER" upload-immutable "$delta" "$(basename "$delta")"
  done
else
  echo "   (no deltas for build $NEW_BUILD — Sparkle falls back to the full zip)"
fi

if [ "$RELEASE_CHANNEL" = "daily" ]; then
  echo "==> preserving stable download aliases for daily-channel release"
fi

# Verify all referenced objects before changing the feed.
curl -fsSI "${URL_PREFIX}$VERSIONED_ZIP" >/dev/null \
  || { echo "!! $VERSIONED_ZIP not reachable"; exit 1; }
curl -fsSI "${URL_PREFIX}$VERSIONED_DMG" >/dev/null \
  || { echo "!! $VERSIONED_DMG not reachable"; exit 1; }
curl -fsSI "${URL_PREFIX}$VERSIONED_PKG" >/dev/null \
  || { echo "!! $VERSIONED_PKG not reachable"; exit 1; }
curl -fsSI "${URL_PREFIX}$(basename "$CHECKSUMS")" >/dev/null \
  || { echo "!! release checksum manifest not reachable"; exit 1; }
curl -fsSI "${URL_PREFIX}$(basename "$PROVENANCE")" >/dev/null \
  || { echo "!! release provenance not reachable"; exit 1; }
curl -fsSI "${URL_PREFIX}$(basename "$SBOM")" >/dev/null \
  || { echo "!! release SBOM not reachable"; exit 1; }
curl -fsSI "${URL_PREFIX}$(basename "$RELEASE_MANIFEST")" >/dev/null \
  || { echo "!! release manifest not reachable"; exit 1; }
[ -n "$PUBLISHED_RESUME" ] || "$UPDATE_HISTORY" verify-remote "$STAGE"

if [ -n "$PUBLISHED_RESUME" ]; then
  if [ "$PUBLISHED_RESUME" = "stable" ]; then
    echo "==> exact appcast and artifacts already published; reconciling Stable aliases"
    "$ARTIFACT_PUBLISHER" reconcile-stable-aliases "$VERSION" "$NEW_BUILD" \
      "$(printf '%s\n' "$ZIP_REMOTE_FACTS" | cut -f1)" "$(printf '%s\n' "$ZIP_REMOTE_FACTS" | cut -f2)" \
      "$(printf '%s\n' "$DMG_REMOTE_FACTS" | cut -f1)" "$(printf '%s\n' "$DMG_REMOTE_FACTS" | cut -f2)"
  else
    echo "==> exact Daily appcast and artifacts already published; no Stable aliases belong to this release"
  fi
  exit 0
fi

# Publish the source tag before the feed, too. A resumed release may already have this exact tag.
if ! git -C "$REPO" rev-parse -q --verify "refs/tags/$VERSION_TAG" >/dev/null; then
  git -C "$REPO" tag -a "$VERSION_TAG" -m "$APP_NAME $VERSION (build $NEW_BUILD)"
fi
git -C "$REPO" push --porcelain origin "refs/tags/$VERSION_TAG"

# ---------------------------------------------------------------- 6. appcast is the final externally visible publishing step
echo "==> publishing appcast last (un-cached)"
"$UPDATE_HISTORY" publish "$STAGE"

# Stable website aliases are intentionally AFTER the generation-matched appcast publish. A losing
# concurrent release or any earlier failure therefore cannot advertise an artifact the feed did not
# accept. Both sources are immutable versioned objects, so this final alias promotion is retryable.
if [ "$RELEASE_CHANNEL" = "stable" ]; then
  echo "==> promoting stable download aliases (un-cached)"
  "$ARTIFACT_PUBLISHER" reconcile-stable-aliases "$VERSION" "$NEW_BUILD" \
    "$(printf '%s\n' "$ZIP_REMOTE_FACTS" | cut -f1)" "$(printf '%s\n' "$ZIP_REMOTE_FACTS" | cut -f2)" \
    "$(printf '%s\n' "$DMG_REMOTE_FACTS" | cut -f1)" "$(printf '%s\n' "$DMG_REMOTE_FACTS" | cut -f2)"
fi

echo "==> verifying the live feed"
FEED="$(curl -fsS "${URL_PREFIX}appcast.xml")" || { echo "!! appcast fetch failed"; exit 1; }
echo "$FEED" | grep -q "<sparkle:shortVersionString>$VERSION<" \
  || { echo "!! appcast does not contain $VERSION"; exit 1; }
curl -fsSI "${URL_PREFIX}$VERSIONED_ZIP" >/dev/null || { echo "!! $VERSIONED_ZIP not reachable"; exit 1; }
curl -fsSI "${URL_PREFIX}$VERSIONED_PKG" >/dev/null || { echo "!! $VERSIONED_PKG not reachable"; exit 1; }
if [ "$RELEASE_CHANNEL" = "stable" ]; then
  curl -fsSI "${URL_PREFIX}$LATEST_DMG" >/dev/null || { echo "!! $LATEST_DMG not reachable"; exit 1; }
  curl -fsSI "${URL_PREFIX}$LATEST_ZIP" >/dev/null || { echo "!! $LATEST_ZIP not reachable"; exit 1; }
fi
echo "    live feed OK: $VERSION is published and downloadable"

echo ""
echo "==> DONE: $VERSION (build $NEW_BUILD, $RELEASE_CHANNEL) published, verified, and tagged $VERSION_TAG."
echo "    enterprise installer package: $PKG"
echo "    machine-readable release manifest: $RELEASE_MANIFEST"
echo "    Agent daemon CycloneDX SBOM: $SBOM"
echo "    dSYM archive (retain with crash symbols): $DSYM_ZIP"
echo "    checksums: $CHECKSUMS"
echo "    optional maintenance (separate transaction): $REPO/scripts/prune-updates.sh --apply"

#!/usr/bin/env bash
# Render bounded, escaped Sparkle release notes from a Git revision range.
set -euo pipefail

if [ "${1:-}" = "--channel-leader" ]; then
  ITEMS="${2:-}"
  CHANNEL="${3:-}"
  [ -f "$ITEMS" ] && { [ "$CHANNEL" = "stable" ] || [ "$CHANNEL" = "daily" ]; } || {
    echo "usage: $0 --channel-leader <appcast-items.tsv> <stable|daily>" >&2
    exit 64
  }
  # Daily users are eligible for both default-channel Stable items and explicit Daily items.
  # Stable users are eligible only for the default channel. The highest eligible live build is
  # therefore the release-note boundary each audience has actually seen.
  /usr/bin/awk -F '\t' -v channel="$CHANNEL" '
    ((channel == "stable" && $12 == "") ||
      (channel == "daily" && ($12 == "" || $12 == "daily"))) &&
      $1 + 0 > highest { highest=$1 + 0; version=$2 }
    END { print version }
  ' "$ITEMS"
  exit 0
fi

REPO="${1:-}"
RANGE="${2:-}"
RELEASE_COMMIT_PREFIX="${3:-}"
VERSION="${4:-}"

[ -n "$REPO" ] && [ -n "$RANGE" ] && [ -n "$RELEASE_COMMIT_PREFIX" ] && [ -n "$VERSION" ] || {
  echo "usage: $0 <repo> <git-range> <release-commit-prefix> <version>" >&2
  exit 64
}

echo "<h2>What's new in $VERSION</h2><ul>"
# Read the complete Git stream so pipefail cannot turn the twenty-item bound into a SIGPIPE failure.
# awk also succeeds when every subject is filtered, allowing a valid empty list for metadata-only
# releases instead of aborting the release transaction midway through artifact creation.
git -C "$REPO" log --no-merges --format='%s' "$RANGE" \
  | /usr/bin/awk -v release_prefix="$RELEASE_COMMIT_PREFIX:" '
      index($0, release_prefix) == 1 { next }
      emitted < 20 { print; emitted += 1 }
    ' \
  | /usr/bin/sed -E 's/^[a-z]+(\([^)]*\))?(!)?: //' \
  | /usr/bin/sed -E 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' \
  | /usr/bin/perl -pe 's/^(.)/\U$1/' \
  | /usr/bin/sed -E 's/^(.*)$/<li>\1<\/li>/'
echo "</ul>"

#!/usr/bin/env bash
# Retired: publishing only the ZIP/appcast bypassed release source, DMG notarization, provenance,
# and transactional ordering checks. Keep this guardrail for existing bookmarks and runbooks.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat >&2 <<EOF
scripts/publish-update.sh is retired because it can create an incomplete release.

Use the canonical transaction instead:
  $REPO/scripts/release.sh <version>

To prepare and verify all local artifacts without pushing or uploading:
  NO_PUSH=1 $REPO/scripts/release.sh <version>
EOF
exit 64

#!/usr/bin/env bash
# Build a legacy-only support root from a real installed corpus, for the opt-in migration and
# post-soak reclaim rehearsals in SQLiteAuthorityCopiedCorpusRehearsalTests.
#
# This exists because the fixture kept being assembled by hand, and twice that hand-assembly quietly
# created conditions no real installation has:
#
#   * a 0700 support root, which hid the lease defect that shipped in 0.24.1 and blocked a user's Mac
#   * media referenced by absolute path into the *live* root, so copied Conversations resolved their
#     attachments against the real library and the managed-media path was never exercised
#
# Both are handled below and asserted by the tests, so a future run cannot silently regress to them.
#
# Usage:
#   scripts/build-migration-rehearsal-fixture.sh [path-to-live-support-root]
#
# Prints the fixture root on the last line. The live corpus is only ever read.
set -euo pipefail

LIVE="${1:-$HOME/Library/Application Support/Mechanician}"
LIVE="${LIVE%/}"

if [[ ! -d "$LIVE/conversations" ]]; then
  echo "error: $LIVE does not look like a Mechanician support root" >&2
  exit 1
fi

BASE="$(mktemp -d /tmp/mechanician-public-migration.XXXXXX)"
# Stands in for ~/Library/Application Support, which macOS creates owner-only. The migration's
# backup step requires a private parent, so a world-readable /tmp base would fail for a reason no
# real machine has.
chmod 700 "$BASE"

ROOT="$BASE/Mechanician"
mkdir -p "$ROOT"
# The condition that matters: an installation which has never migrated has whatever mode its
# directory was created with, and the default umask gives 0755. Recognition and the lease must
# repair that rather than refuse. Do NOT "fix" this to 0700.
chmod 755 "$ROOT"

echo "fixture base: $BASE"
echo "copying legacy sources from: $LIVE"

for entry in conversations workspaces artifacts ambient conversation-media trash; do
  [[ -e "$LIVE/$entry" ]] || continue
  cp -Rp "$LIVE/$entry" "$ROOT/$entry"
done
for entry in home-workspace.json; do
  [[ -e "$LIVE/$entry" ]] && cp -p "$LIVE/$entry" "$ROOT/$entry"
done

# Deliberately absent, because a legacy-only installation has none of them: library.db and its
# journals, projections.db, storage-authority.json, preserved-sources. `trash`, when present, is
# Legacy undo/recovery authority and must be rehearsed along with the live Conversation corpus.

# Sidecars store attachment paths in two shapes, and only one of them is portable. Rewrite the
# absolute ones so a copied Conversation resolves its media inside the fixture; leaving them alone
# means the migration reads the developer's live attachments and reports success it did not earn.
REWRITTEN=$(LIVE_PATH="$LIVE" ROOT_PATH="$ROOT" perl -0777 -i -pe '
  BEGIN {
    $from = $ENV{LIVE_PATH}; $from =~ s{/}{\\/}g;
    $to   = $ENV{ROOT_PATH}; $to   =~ s{/}{\\/}g;
    $count = 0;
  }
  $count += s/\Q$from\E/$to/g;
  END { print STDERR "$count\n" }
' "$ROOT/conversations"/*.json 2>&1 >/dev/null | tail -1)
echo "rewrote $REWRITTEN absolute media references into the fixture"

# The imperfect shapes. Exhaustive per-shape coverage lives in MigrationFidelityTests against
# synthetic corpora; what these add is that the reclaim's coverage proof runs against a root that
# really does hold preserved sources, of both kinds, at real scale.
# Smallest sidecars, so the shapes land on Conversations whose loss would be cheap if this were ever
# pointed at something real. `mapfile` is bash 4; macOS ships 3.2.
cd "$ROOT/conversations"
SIDECARS=()
while IFS= read -r line; do SIDECARS+=("$line"); done < <(ls -S ./*.json | tail -4)
if (( ${#SIDECARS[@]} < 4 )); then
  echo "error: need at least 4 Conversations to inject the rehearsal shapes" >&2
  exit 1
fi

# 1. An unreadable sidecar. No Conversation can be built from it, so it must migrate as a preserved
#    record and be counted by the reclaim's coverage proof.
printf '{ this is not json' > "${SIDECARS[0]}"
echo "injected: unreadable sidecar ${SIDECARS[0]#./}"

# 2. A `.json.corrupt-*` recovery copy whose live twin decodes. The library represents the twin, not
#    the copy, and the whole point of keeping one is that its owner may want it back.
cp "${SIDECARS[1]}" "${SIDECARS[1]}.corrupt-20260101T000000Z"
echo "injected: recovery duplicate ${SIDECARS[1]#./}.corrupt-20260101T000000Z"

# 3. A member this build does not re-emit — the shape `appliedRuntimeEventIDs` left on every 0.10.x
#    installation. It decodes and renders today, so it must keep its place in the library while the
#    member we cannot reproduce is preserved beside it.
perl -0777 -i -pe 's/^\{/{"appliedRuntimeEventIDs":[],/' "${SIDECARS[2]}"
echo "injected: unknown member into ${SIDECARS[2]#./}"

# 4. An attachment the person deleted from Finder. The reference is real, the bytes are not, and
#    that must not cost anyone their Conversation or their backups.
MISSING=""
for sidecar in ./*.json; do
  ref=$(grep -o "conversation-media\\\\/[0-9A-Fa-f-]\{36\}\\\\/[0-9A-Fa-f-]\{36\}\.[a-z]\{3,4\}" "$sidecar" 2>/dev/null | head -1 || true)
  [[ -n "$ref" ]] || continue
  # JSON escapes the separators, so the reference reads `conversation-media\/<id>\/<file>`. The only
  # backslashes in it are those escapes; dropping them is the whole unescape.
  candidate="$ROOT/${ref//\\/}"
  if [[ -f "$candidate" ]]; then rm -f "$candidate"; MISSING="$candidate"; break; fi
done
if [[ -n "$MISSING" ]]; then
  echo "injected: deleted attachment ${MISSING#$ROOT/}"
else
  # Fail rather than warn. A rehearsal that quietly drops a shape is how a fixture ends up proving
  # less than it claims, which is the mistake this script exists to stop repeating.
  echo "error: no managed attachment could be deleted; the missing-media shape was not injected" >&2
  exit 1
fi

cd - >/dev/null
LIVE_COUNT=$(find "$ROOT/conversations" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
echo "fixture holds $LIVE_COUNT live Conversation sidecars"
echo "root mode: $(stat -f '%Lp' "$ROOT") (must be 755)"
echo "$ROOT"

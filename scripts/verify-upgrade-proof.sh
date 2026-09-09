#!/usr/bin/env bash
# Assert that the cross-version authority upgrade was actually proven by this run.
#
# Why this is a named gate rather than "it's in the suite somewhere":
#
# On 2026-08-14 schema v7 shipped with 2239 passing Swift tests and bricked launch on every machine
# that already had a library. Every one of those tests provisioned a fresh database at the current
# schema version. None opened a pre-existing older-version ACTIVE authority with the new binary,
# because until that commit the situation could not arise — so nobody had written the test, and a
# green suite was mistaken for evidence that upgrades work.
#
# A fresh-provision test and an upgrade test look almost identical and prove completely different
# things. This gate exists so the difference cannot go quiet again: if the upgrade proof is deleted,
# renamed, or silently skipped, check.sh fails here instead of passing and shipping a brick.
set -euo pipefail

LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="${2:-}"; shift 2 ;;
    *) echo "usage: $0 --log <swift-test-log>" >&2; exit 2 ;;
  esac
done

[ -n "$LOG" ] || { echo "!! $0 requires --log" >&2; exit 2; }
[ -f "$LOG" ] || { echo "!! $0: no swift test log at $LOG" >&2; exit 2; }

# Each of these answers a question a fresh-provision test cannot.
REQUIRED=(
  # An older active authority is carried forward and the product opens against it.
  "testCurrentBinaryCarriesAPreviousVersionActiveLibraryForwardAndOpensIt"
  # Every version this build claims it can upgrade has a ladder step. This is the one that fails
  # when a new schema version is added and its migration step is forgotten.
  "testEverySchemaVersionThisBuildClaimsToUpgradeHasALadderStep"
  # The database/marker swap is resumable, so an interrupted upgrade is finished rather than fatal.
  "testAnUpgradeInterruptedBeforeTheMarkerWasRepublishedIsFinished"
  # An upgrade never runs without the writer lease.
  "testWithoutTheProcessLeaseNothingIsTouched"
)

echo "==> cross-version upgrade proof"
missing=0
for name in "${REQUIRED[@]}"; do
  if grep -q "'-\[MechanicianTests\.SQLiteAuthorityUpgradeTests $name\]' passed" "$LOG"; then
    echo "    ok   $name"
  else
    echo "    MISSING  $name"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  cat >&2 <<'EOF'
!! The cross-version upgrade proof did not run.

   A green test suite that only provisions fresh databases is not evidence that an existing
   library can be opened by a newer build. That mistake shipped schema v7 and bricked launch for
   every installation that already had a library (reverted 2026-08-14).

   Restore the tests in app/Tests/MechanicianTests/SQLiteAuthorityUpgradeTests.swift, or if they
   were renamed on purpose, update the required list in scripts/verify-upgrade-proof.sh.

   Do not bump SQLiteLibraryStore.schemaVersion while this gate is failing.
EOF
  exit 1
fi

echo "    an older active authority opens under this binary"

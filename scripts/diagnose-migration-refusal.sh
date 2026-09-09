#!/bin/bash
# Read-only diagnosis of a refused library migration. Touches nothing.
set -u
DB="$HOME/Library/Application Support/Mechanician/library.db"
[ -f "$DB" ] || { echo "no library.db at $DB"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$DB" "$TMP/lib.db" 2>/dev/null || { echo "could not copy library.db"; exit 1; }
[ -f "$DB-wal" ] && cp "$DB-wal" "$TMP/lib.db-wal" 2>/dev/null
[ -f "$DB-shm" ] && cp "$DB-shm" "$TMP/lib.db-shm" 2>/dev/null

echo "=== per-domain counters ==="
sqlite3 -header -column "$TMP/lib.db" "
SELECT s.domain,
       COUNT(*) AS total,
       SUM(CASE WHEN dirty=0 AND import_state='current' THEN 1 ELSE 0 END) AS current,
       SUM(dirty) AS dirty,
       SUM(CASE WHEN import_state='mismatch' THEN 1 ELSE 0 END) AS mismatch,
       SUM(CASE WHEN import_state='quarantine' THEN 1 ELSE 0 END) AS quarantine,
       SUM(CASE WHEN import_state='error' THEN 1 ELSE 0 END) AS errors,
       (SELECT COALESCE(MAX(d.expected_source_count),-1) FROM domain_reconciliation d
         WHERE d.domain=s.domain) AS census_expects
FROM migration_sources s GROUP BY s.domain ORDER BY s.domain;"

echo
echo "=== operative_state rows that are dirty but NOT accepted ==="
sqlite3 -header -line "$TMP/lib.db" "
SELECT twin.source_identity, twin.import_state,
       substr(COALESCE(twin.diagnostics,'(none)'),1,160) AS diagnostics,
       COALESCE((SELECT c.import_state FROM migration_sources c
                  WHERE c.domain='conversations'
                    AND c.source_identity=twin.source_identity),'(no twin row)') AS conversation_state,
       CASE WHEN EXISTS (SELECT 1 FROM conversations cl
                          WHERE cl.source_identity=twin.source_identity)
            THEN 'yes' ELSE 'no' END AS conversation_row_exists
FROM migration_sources twin
WHERE twin.domain='operative_state' AND twin.dirty=1
  AND twin.source_identity NOT IN (
    SELECT issue.source_identity FROM migration_sources issue
    WHERE issue.domain='conversations'
      AND issue.import_state IN ('quarantine','mismatch')
      AND issue.dirty=1
      AND issue.imported_revision IS NULL AND issue.imported_digest IS NULL
      AND issue.imported_at IS NULL
      AND issue.diagnostics IS NOT NULL AND issue.diagnostics <> ''
      AND issue.observed_digest IS NOT NULL AND LENGTH(issue.observed_digest)=64
      AND issue.observed_revision IS NOT NULL AND issue.observed_revision <> ''
      AND issue.source_byte_count > 0
      AND NOT EXISTS (SELECT 1 FROM conversations claimed
                       WHERE claimed.source_identity=issue.source_identity))
LIMIT 25;"

echo
echo "=== accepted counts vs actual, operative_state ==="
sqlite3 -header -column "$TMP/lib.db" "
WITH accepted AS (
  SELECT issue.source_identity FROM migration_sources issue
  WHERE issue.domain='conversations'
    AND issue.import_state IN ('quarantine','mismatch') AND issue.dirty=1
    AND issue.imported_revision IS NULL AND issue.imported_digest IS NULL
    AND issue.imported_at IS NULL
    AND issue.diagnostics IS NOT NULL AND issue.diagnostics <> ''
    AND issue.observed_digest IS NOT NULL AND LENGTH(issue.observed_digest)=64
    AND issue.observed_revision IS NOT NULL AND issue.observed_revision <> ''
    AND issue.source_byte_count > 0
    AND NOT EXISTS (SELECT 1 FROM conversations claimed
                     WHERE claimed.source_identity=issue.source_identity))
SELECT
 (SELECT COUNT(*) FROM migration_sources t JOIN migration_sources i
   ON i.domain='conversations' AND i.source_identity=t.source_identity
      AND i.import_state=t.import_state
  WHERE t.domain='operative_state' AND t.import_state='quarantine' AND t.dirty=1
    AND t.source_identity IN (SELECT source_identity FROM accepted)) AS accepted_quarantine,
 (SELECT COUNT(*) FROM migration_sources t JOIN migration_sources i
   ON i.domain='conversations' AND i.source_identity=t.source_identity
      AND i.import_state=t.import_state
  WHERE t.domain='operative_state' AND t.import_state='mismatch' AND t.dirty=1
    AND t.source_identity IN (SELECT source_identity FROM accepted)) AS accepted_mismatch;"

echo
echo "=== artifact_media sources that are dirty (why the media domain refused) ==="
# Named columns rather than a verdict: this is the domain with no quarantine allowance before
# 0.26.14, so the question is always WHICH of the proof conditions a row fails.
sqlite3 -header -line "$TMP/lib.db" "
SELECT source_identity,
       import_state,
       substr(COALESCE(diagnostics,'(none)'),1,200) AS diagnostics,
       COALESCE(source_byte_count,-1) AS source_byte_count,
       CASE WHEN observed_digest IS NOT NULL AND LENGTH(observed_digest)=64
            THEN 'yes' ELSE 'no' END AS has_full_digest,
       CASE WHEN observed_revision IS NOT NULL AND observed_revision <> ''
            THEN 'yes' ELSE 'no' END AS has_revision,
       CASE WHEN imported_revision IS NULL AND imported_digest IS NULL AND imported_at IS NULL
            THEN 'yes' ELSE 'no' END AS never_imported,
       CASE WHEN EXISTS (SELECT 1 FROM artifacts a
                          WHERE a.source_identity=migration_sources.source_identity)
             OR EXISTS (SELECT 1 FROM retained_byte_sources r
                          WHERE r.source_identity=migration_sources.source_identity)
            THEN 'yes' ELSE 'no' END AS claimed_by_a_row
FROM migration_sources
WHERE domain='artifact_media' AND dirty=1
LIMIT 25;"

echo
echo "=== would the artifact_media quarantine allowance accept them? ==="
sqlite3 -header -column "$TMP/lib.db" "
SELECT
 (SELECT COUNT(*) FROM migration_sources
   WHERE domain='artifact_media' AND import_state='quarantine') AS quarantined,
 (SELECT COUNT(*) FROM migration_sources issue
   WHERE issue.domain='artifact_media'
     AND issue.import_state='quarantine'
     AND issue.dirty=1
     AND issue.imported_revision IS NULL AND issue.imported_digest IS NULL
     AND issue.imported_at IS NULL
     AND issue.diagnostics IS NOT NULL AND issue.diagnostics <> ''
     AND issue.observed_digest IS NOT NULL AND LENGTH(issue.observed_digest)=64
     AND issue.observed_revision IS NOT NULL AND issue.observed_revision <> ''
     AND issue.source_byte_count > 0
     AND NOT EXISTS (SELECT 1 FROM artifacts claimed
                      WHERE claimed.source_identity=issue.source_identity)
     AND NOT EXISTS (SELECT 1 FROM retained_byte_sources claimed
                      WHERE claimed.source_identity=issue.source_identity)) AS would_be_accepted;"

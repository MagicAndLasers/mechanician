#!/usr/bin/env bash
# Make a non-public Mechanician bundle an Alternate importer/viewer for .convrec without relying on
# declaration ordering. Custom tenant plists are allowed to add or reorder document declarations.
set -euo pipefail

target_plist="${1:?usage: downgrade-conversation-record-plist.sh INFO_PLIST}"
conversation_record_identifier="ai.mechanician.conversation-record"
plist_buddy="/usr/libexec/PlistBuddy"

[ -f "$target_plist" ] || { echo "!! Info.plist not found: $target_plist"; exit 1; }

conversation_export_index=""
conversation_export_count=0
candidate_index=0
while $plist_buddy -c "Print :UTExportedTypeDeclarations:$candidate_index" \
  "$target_plist" >/dev/null 2>&1; do
  candidate_identifier="$($plist_buddy \
    -c "Print :UTExportedTypeDeclarations:$candidate_index:UTTypeIdentifier" \
    "$target_plist" 2>/dev/null || true)"
  if [ "$candidate_identifier" = "$conversation_record_identifier" ]; then
    conversation_export_index="$candidate_index"
    conversation_export_count=$((conversation_export_count + 1))
  fi
  candidate_index=$((candidate_index + 1))
done
[ "$conversation_export_count" -eq 1 ] || {
  echo "!! expected one exported Conversation Record declaration, found $conversation_export_count"
  exit 1
}

if ! $plist_buddy -c 'Print :UTImportedTypeDeclarations' "$target_plist" >/dev/null 2>&1; then
  $plist_buddy -c 'Add :UTImportedTypeDeclarations array' "$target_plist"
fi

import_index=0
while $plist_buddy -c "Print :UTImportedTypeDeclarations:$import_index" \
  "$target_plist" >/dev/null 2>&1; do
  imported_identifier="$($plist_buddy \
    -c "Print :UTImportedTypeDeclarations:$import_index:UTTypeIdentifier" \
    "$target_plist" 2>/dev/null || true)"
  if [ "$imported_identifier" = "$conversation_record_identifier" ]; then
    echo "!! Conversation Record is already imported as well as exported in $target_plist"
    exit 1
  fi
  import_index=$((import_index + 1))
done

$plist_buddy \
  -c "Copy :UTExportedTypeDeclarations:$conversation_export_index :UTImportedTypeDeclarations:$import_index" \
  "$target_plist"
$plist_buddy -c "Delete :UTExportedTypeDeclarations:$conversation_export_index" "$target_plist"

conversation_document_index=""
conversation_document_count=0
document_index=0
while $plist_buddy -c "Print :CFBundleDocumentTypes:$document_index" \
  "$target_plist" >/dev/null 2>&1; do
  content_type_index=0
  while $plist_buddy \
    -c "Print :CFBundleDocumentTypes:$document_index:LSItemContentTypes:$content_type_index" \
    "$target_plist" >/dev/null 2>&1; do
    content_type="$($plist_buddy \
      -c "Print :CFBundleDocumentTypes:$document_index:LSItemContentTypes:$content_type_index" \
      "$target_plist" 2>/dev/null || true)"
    if [ "$content_type" = "$conversation_record_identifier" ]; then
      conversation_document_index="$document_index"
      conversation_document_count=$((conversation_document_count + 1))
    fi
    content_type_index=$((content_type_index + 1))
  done
  document_index=$((document_index + 1))
done
[ "$conversation_document_count" -eq 1 ] || {
  echo "!! expected one Conversation Record document declaration, found $conversation_document_count"
  exit 1
}

$plist_buddy \
  -c "Set :CFBundleDocumentTypes:$conversation_document_index:LSHandlerRank Alternate" \
  "$target_plist"

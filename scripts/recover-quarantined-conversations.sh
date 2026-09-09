#!/usr/bin/env bash
# Recover conversation sidecars quarantined by the 0.11.7 `toolEvents` decode regression.
#
# Root cause: FR-90 added `var toolEvents: [SubagentToolEvent] = []` (non-optional) to
# SubagentRun. Swift's synthesized Decodable ignores default values, so every pre-0.11.7
# sidecar that contains a subagent (and therefore has no "toolEvents" key) throws
# keyNotFound on load and gets renamed `.json` -> `.json.corrupt-<stamp>`.
#
# This script injects `"toolEvents": []` into every subagent that lacks it, then restores the
# canonical `<UUID>.json` name. The data itself is untouched otherwise. The running 0.11.7
# app's conversations-directory watcher adopts the restored files live (no relaunch needed);
# they also load normally on next launch.
#
# Safe by construction: originals were already backed up to conversations-corrupt-backup-*,
# each file is validated as JSON before and after, and the write is atomic (temp + mv).
set -euo pipefail

DIR="${1:-$HOME/Library/Application Support/Mechanician/conversations}"
cd "$DIR"

shopt -s nullglob
files=( *.corrupt-* )
if [ ${#files[@]} -eq 0 ]; then echo "No quarantined files in $DIR"; exit 0; fi

echo "Recovering ${#files[@]} quarantined conversation(s) in:"
echo "  $DIR"
echo

for f in "${files[@]}"; do
  # UUID is the stem before the first `.json`.
  uuid="${f%%.json*}"
  dest="${uuid}.json"

  if ! jq empty "$f" >/dev/null 2>&1; then
    echo "  SKIP  $uuid  (not valid JSON — leaving quarantined)"; continue
  fi
  if [ -e "$dest" ]; then
    echo "  SKIP  $uuid  ($dest already exists — not overwriting)"; continue
  fi

  tmp="$(mktemp "${DIR}/.recover.XXXXXX")"
  # Add toolEvents:[] to any subagent missing it; leave everything else exactly as-is.
  jq '.subagents |= (with_entries(.value.toolEvents = (.value.toolEvents // [])))' "$f" > "$tmp"

  if ! jq empty "$tmp" >/dev/null 2>&1; then
    echo "  FAIL  $uuid  (re-serialized JSON invalid — aborting this file)"; rm -f "$tmp"; continue
  fi

  mv "$tmp" "$dest"
  title="$(jq -r '.title // "(untitled)"' "$dest")"
  subs="$(jq -r '.subagents|length' "$dest")"
  echo "  OK    $uuid  subagents=$subs  \"$title\""
done

echo
echo "Done. If the app is running it will adopt these within ~1s; otherwise they appear on next launch."
echo "The original quarantined bytes remain in conversations-corrupt-backup-* until you delete them."

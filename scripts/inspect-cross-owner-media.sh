#!/bin/bash
# Read-only. Names where a Conversation's media references actually came from.
set -u
CID="${1:-}"
[ -n "$CID" ] || { echo "usage: $0 <conversation-uuid>"; exit 1; }
S="$HOME/Library/Application Support/Mechanician"
F="$S/conversations/$CID.json"
[ -f "$F" ] || { echo "no sidecar at $F"; exit 1; }
python3 - "$F" "$CID" "$S" <<'PY'
import json, sys, os, re
path, cid, support = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
print("fork provenance:", json.dumps(d.get("forkProvenance")) if d.get("forkProvenance") else "none")
media = os.path.join(support, "conversation-media")
pat = re.compile(re.escape(media) + r"/([0-9A-Fa-f-]{36})/([^\s\)\"']+)")
seen = []
def scan(text, where):
    for m in pat.finditer(text or ""):
        owner, name = m.group(1), m.group(2)
        if owner.lower() == cid.lower(): continue
        seen.append((where, owner, name, os.path.exists(m.group(0))))
for i, e in enumerate(d.get("messages", [])):
    sup = any(e.get(k) is not None for k in
              ("supersessionEventID","supersededByEntryID","supersededByFrameUUID"))
    scan(e.get("text"), f"message[{i}] kind={e.get('kind')} superseded={sup}")
for k in ("draft","pendingTurnPrompt"):
    scan(d.get(k), k)
for i, p in enumerate(d.get("queuedPrompts") or []):
    scan(p, f"queuedPrompt[{i}]")
if not seen:
    print("no cross-owner media references found in this sidecar")
for where, owner, name, exists in seen:
    print(f"  {where}\n    -> owner {owner} file {name} exists={exists}")
PY

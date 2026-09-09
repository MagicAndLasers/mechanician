# Encoding spec: minimal valid JSON verifiable-agent-record
Source: draft-birkholz-verifiable-agent-conversations-00 (pinned .txt). CDDL prose sections §3 (lines ~1057–1904); collated normative CDDL §4 (lines 1909–2201). `start = verifiable-agent-record / signed-agent-record` (line 1911) — an unsigned bare JSON `verifiable-agent-record` object is a valid document root; the COSE `signed-agent-record` envelope is optional and out of scope for the prototype.

## 0. JSON encoding conventions
- CDDL maps → JSON objects; CDDL bare-word member names become JSON string keys **spelled exactly as in the CDDL, hyphens included**: `"session-id"`, `"model-id"`, `"is-error"`, `"event-type"`, `"token-usage"`, `"file-attribution"`, `"recording-agent"`, `"working-dir"`, `"call-id"`, `"start-line"`, `"end-line"`, `"content-hash"`, `"content-hash-alg"`, `"cli-name"`, `"cli-version"`, `"model-provider"`, `"session-start"`, `"session-end"`, `"parent-id"`, `"agent-meta"`. Never camelCase.
- `? member` = optional; unprefixed = required. `tstr` → JSON string, `uint` → non-negative integer, `number` → any JSON number, `bool` → true/false, `any` → any JSON value, `[* x]` → array (zero or more allowed, so `[]` is valid).
- Most maps end with `* tstr => any` — an open extension point: arbitrary extra string-keyed members of any value are permitted and are how native/vendor fields are preserved (lines 1093, 1151, 1199, 1245, 1268, 1306, 1363, 1418, 1470, 1525, 1580, 1616). Maps WITHOUT it (closed): `file-attribution-record`, `file`, `conversation`, `range`, `contributor`, `resource`, `trace-metadata`.

## 1. Common types
- `abstract-timestamp = tstr .regexp date-time-regexp / uint` (line 1914). Either a full RFC 3339 date-time string (regexp at line 1923 — requires date`T`time plus `Z` or `±HH:MM` offset; fractional seconds optional; no date-only form) OR an unsigned integer epoch value. New implementations SHOULD emit RFC 3339 strings; consumers MUST accept both (lines 1069–1071). Emit strings like `"2026-08-02T14:30:00Z"`.
- `session-id = tstr / bstr` (line 1917) — in JSON, use a string (UUID v4/v7, SHA-256 hash, or other opaque format; lines 1073–1075).
- `entry-id = tstr` (line 1920) — a string, unique per entry **within a session**, used for parent-child linking and (conceptually) call/result correlation (lines 1077–1079).

## 2. Top level: verifiable-agent-record (lines 1085–1094; collated 1928–1937)
```
{
  version: tstr            REQUIRED  — schema version, semver, e.g. "3.0.0-draft" (line 1107)
  id: tstr                 REQUIRED  — record identifier, typically a UUID
  session: session-trace   REQUIRED
  ? created: abstract-timestamp        — when the RECORD was generated (distinct from session times)
  ? file-attribution: file-attribution-record
  ? vcs: vcs-context                    — record-level VCS metadata
  ? recording-agent: recording-agent    — tool that generated the record (vs. the conversing agent)
  * tstr => any
}
```
Note key/type name split: JSON key is `"file-attribution"` (type `file-attribution-record`), key `"vcs"` (type `vcs-context`), key `"session"` (type `session-trace`).

## 3. session-trace (lines 1143–1152; collated 1939–1948)
```
{
  ? format: tstr                       — e.g. "interactive" / "autonomous" / vendor string; informative only
  session-id: session-id   REQUIRED
  ? session-start: abstract-timestamp
  ? session-end: abstract-timestamp
  agent-meta: agent-meta   REQUIRED
  ? environment: environment
  entries: [* entry]       REQUIRED    — ordered array; may be empty
  * tstr => any
}
```

### agent-meta (lines 1193–1200)
```
{
  model-id: tstr        REQUIRED  — provider naming, e.g. "claude-opus-4-5-20251101"
  model-provider: tstr  REQUIRED  — e.g. "anthropic", "google", "openai"
  ? models: [* tstr]              — all models used (multi-model sessions)
  ? cli-name: tstr                — e.g. "claude-code", "gemini-cli", "codex-cli"
  ? cli-version: tstr
  * tstr => any
}
```

### recording-agent (lines 1242–1246)
`{ name: tstr REQUIRED, ? version: tstr, * tstr => any }`

### environment (lines 1264–1269)
`{ working-dir: tstr REQUIRED, ? vcs: vcs-context, ? sandboxes: [* tstr], * tstr => any }`

### vcs-context (lines 1301–1307)
`{ type: tstr REQUIRED ("git"/"jj"/"hg"/"svn" are examples, not a closed enum), ? revision: tstr (commit SHA), ? branch: tstr, ? repository: tstr (URL), * tstr => any }`

## 4. Entry types (union at lines 1333–1337)
`entry = message-entry / tool-call-entry / tool-result-entry / reasoning-entry / event-entry`. Discriminated by the `type` member. All five support optional `children: [* entry]` for hierarchical nesting and `* tstr => any` (lines 1328–1331).

### message-entry (lines 1354–1364; collated 1994–2004)
```
{
  type: "user" / "assistant"   REQUIRED  — the ONLY two values; there is no separate "role" key
  ? content: any               — plain string, array of typed content parts, or ABSENT when content lives in children
  ? timestamp: abstract-timestamp
  ? id: entry-id
  ? model-id: tstr             — assistant entries only; absent on user entries
  ? parent-id: entry-id        — reference to parent entry, enabling tree-structured conversations
  ? token-usage: token-usage
  ? children: [* entry]
  * tstr => any
}
```

### tool-call-entry (lines 1410–1419; collated 2006–2023)
```
{
  type: "tool-call"   REQUIRED (fixed literal)
  name: tstr          REQUIRED  — tool name, e.g. "Bash", "Edit", "Read", "apply_patch"
  input: any          REQUIRED  — arguments in native structure
  ? call-id: tstr               — links call <-> result
  ? timestamp / ? id / ? children / * tstr => any
}
```
NOTE: no canonical `parent-id` member (only message-entry has one).

### tool-result-entry (lines 1461–1471; collated 2025–2035)
```
{
  type: "tool-result"   REQUIRED (fixed literal)
  output: any           REQUIRED  — native-structure tool output
  ? call-id: tstr                 — pairs with the tool-call-entry's call-id (lines 1474–1476)
  ? status: tstr                  — free string; "success"/"error"/"completed" cited as examples, NOT an enum
  ? is-error: bool                — present when execution failed
  ? timestamp / ? id / ? children / * tstr => any
}
```

### reasoning-entry (lines 1517–1526; collated 2037–2046)
```
{
  type: "reasoning"   REQUIRED (fixed literal)
  content: any        REQUIRED  — may be "" (empty string) when only encrypted content is available (lines 1539–1540)
  ? encrypted: tstr             — provider-encrypted CoT
  ? subject: tstr               — topic label
  ? timestamp / ? id / ? children / * tstr => any
}
```

### event-entry (lines 1573–1581; collated 2048–2056) — the extension escape hatch
```
{
  type: "system-event"   REQUIRED (fixed literal; note the map is named event-entry but the discriminator is "system-event")
  event-type: tstr       REQUIRED  — deliberately NOT enumerated (e.g. "session-start", "session-end", "token-count", "permission-change", or vendor-specific; lines 1592–1595)
  ? data: { * tstr => any }        — free-form JSON object payload, structure varies by event-type
  ? timestamp / ? id / ? children / * tstr => any
}
```
Extension mechanism = two layers: (a) new event kinds via arbitrary `event-type` + `data`; (b) every entry map's trailing `* tstr => any` lets any entry carry arbitrary extra string-keyed members preserving native agent fields.

## 5. Nesting / id semantics
- `id` on every entry type is an `entry-id` string, unique within the session (lines 1077–1079).
- Nesting is expressed two ways: **containment** via `children: [* entry]` on any entry (e.g. tool calls or reasoning blocks embedded inside an assistant message, lines 1393–1395), and **reference** via `parent-id: entry-id` (canonical on message-entry only, lines 1388–1389). Tool call/result pairing uses `call-id` (a plain tstr, NOT an entry-id), matching a tool-result-entry to its tool-call-entry.
- `entries` itself is a flat ordered array; trees hang off it via children/parent-id.

## 6. token-usage (lines 1609–1617; collated 2058–2066)
All members optional (different agents report different subsets, lines 1631–1633):
`{ ? input: uint, ? output: uint, ? cached: uint, ? reasoning: uint, ? total: uint, ? cost: number (US dollars), * tstr => any }`
An empty object `{}` is schema-valid.

## 7. file-attribution (lines 1666–1806; collated 2068–2108) — spec'd but "not yet validated against real session data" (lines 1655–1657)
- `file-attribution-record = { files: [* file] }` — only member, required, may be `[]`. No extension point.
- `file = { path: tstr REQUIRED (repo-root-relative), conversations: [* conversation] REQUIRED }`
- `conversation = { ? url: tstr (must match uri-regexp, line 1926), ? contributor: contributor (default for all ranges), ranges: [* range] REQUIRED, ? related: [* resource] }`
- `range = { start-line: uint REQUIRED, end-line: uint REQUIRED (both 1-indexed, end inclusive), ? content-hash: tstr, ? content-hash-alg: tstr (default "sha-256"), ? contributor: contributor (per-range override) }`
- `contributor = { type: "human"/"ai"/"mixed"/"unknown" REQUIRED (closed enum), ? model-id: tstr }`
- `resource = { type: tstr REQUIRED (e.g. "issue", "pr", "documentation"), url: tstr REQUIRED (uri-regexp) }`

## 8. Out of scope for the JSON prototype (exists in draft, one line each)
- `signed-agent-record` (lines 2114–2119): COSE_Sign1 CBOR envelope (tag 18), protected/unprotected headers, detachable payload — skip for unsigned JSON.
- `trace-metadata` (lines 2152–2160): COSE unprotected-header summary map (session-id, agent-vendor, trace-format, timestamp-start required; timestamp-end, content-hash, content-hash-alg optional) at placeholder label 100 — only relevant when signing. `trace-format-id` known values incl. "ietf-vac-v3.0", "claude-jsonl" (lines 2162–2164).
- The draft contains NO telephony-recording or transfer structures; those do not appear anywhere in this document.
- Media type `application/agent-conversation`, file extension `.acr` (lines 2417–2454).

## 9. Worked minimal-plus example (every member verified against the collated CDDL)
```json
{
  "version": "3.0.0-draft",
  "id": "6f1c2a3e-9d4b-4c1e-8f2a-000000000001",
  "created": "2026-08-02T14:30:00Z",
  "session": {
    "format": "interactive",
    "session-id": "6b3d9e0a-7f21-4a4e-9c55-000000000002",
    "session-start": "2026-08-02T14:00:00Z",
    "session-end": "2026-08-02T14:25:00Z",
    "agent-meta": {
      "model-id": "claude-opus-4-5-20251101",
      "model-provider": "anthropic",
      "cli-name": "claude-code",
      "cli-version": "2.0.1"
    },
    "environment": {
      "working-dir": "/Users/dev/project",
      "vcs": { "type": "git", "branch": "dev", "revision": "1fbdc9e" }
    },
    "entries": [
      { "type": "user", "content": "List the files.", "timestamp": "2026-08-02T14:00:05Z", "id": "e1" },
      {
        "type": "assistant",
        "content": "Running ls.",
        "id": "e2",
        "parent-id": "e1",
        "model-id": "claude-opus-4-5-20251101",
        "token-usage": { "input": 120, "output": 15 },
        "children": [
          { "type": "reasoning", "content": "User wants a directory listing.", "id": "e2r" },
          { "type": "tool-call", "name": "Bash", "input": { "command": "ls" }, "call-id": "c1", "id": "e2t" }
        ]
      },
      { "type": "tool-result", "output": "README.md\nsrc\n", "call-id": "c1", "status": "success", "is-error": false, "id": "e3" },
      { "type": "system-event", "event-type": "session-end", "data": { "reason": "user-exit" }, "id": "e4" }
    ]
  },
  "recording-agent": { "name": "mechanician-exporter", "version": "0.1.0" }
}
```
Absolute minimum valid record: `{"version":"3.0.0-draft","id":"<uuid>","session":{"session-id":"<uuid>","agent-meta":{"model-id":"<m>","model-provider":"<p>"},"entries":[]}}`.

## Trap notes
- Timestamp epoch-unit contradiction inside the draft: the normative collated CDDL comment says 'RFC 3339 string OR epoch milliseconds' (line 1913) and section 3.1 says 'numeric epoch milliseconds' (lines 1069-1070), but the REQ-2 compliance prose says 'POSIX Seconds since Epoch' (lines 472-473). Emit RFC 3339 strings (the SHOULD) to sidestep the ambiguity entirely.
- All JSON keys are hyphenated exactly as in the CDDL (session-id, model-id, is-error, event-type, call-id, working-dir, file-attribution). Do not camelCase or snake_case anything.
- There is no 'role' key. Message direction is folded into the discriminator: type is "user" or "assistant" on message-entry; the other fixed type values are "tool-call", "tool-result", "reasoning", "system-event" (note: the event map is named event-entry but its type literal is "system-event", not "event").
- parent-id is a canonical member ONLY of message-entry. tool-call/tool-result/reasoning/event entries have no canonical parent-id; their nesting is via containment in a children array (extra parent-id keys would only be legal as * tstr => any extension data).
- Required members that are easy to omit: tool-call-entry.name and .input are REQUIRED; tool-result-entry.output is REQUIRED; reasoning-entry.content is REQUIRED (use "" when only encrypted content exists); event-entry.event-type is REQUIRED. Conversely message-entry.content is OPTIONAL.
- call-id (plain tstr, distinct from entry-id) is the call<->result pairing mechanism and is optional on both sides; the prototype should still always emit matching call-id pairs since it is the only correlation field.
- status on tool-result-entry is a free tstr; "success"/"error"/"completed" are examples, not an enum. Same for session-trace.format, vcs-context.type, and event-type. The ONLY closed enums are message-entry.type (user/assistant) and contributor.type (human/ai/mixed/unknown).
- verifiable-agent-record top-level: only version, id, session are required; created, file-attribution, vcs, recording-agent are optional. JSON key names differ from type names: key "session" -> session-trace, key "vcs" -> vcs-context, key "file-attribution" -> file-attribution-record.
- agent-meta requires BOTH model-id and model-provider; models/cli-name/cli-version are optional. session-trace additionally requires session-id and entries (entries may be an empty array); session-start/session-end are optional.
- token-usage members are ALL optional; input/output/cached/reasoning/total must be non-negative integers (uint), cost may be a float (number).
- Extension escape hatch: nearly every map ends with '* tstr => any', so unknown extra string keys are valid everywhere EXCEPT the closed file-attribution family maps (file-attribution-record, file, conversation, range, contributor, resource) and trace-metadata.
- abstract-timestamp string form must match the full RFC 3339 regexp (line 1923): date T time with Z or +/-HH:MM offset; no date-only or space-separated forms.
- session-id CDDL allows tstr / bstr, but in JSON emit a string; entry-id is always a string, unique within the session.
- The draft has no telephony-recording or transfer structures at all; nothing to encode there.
- file-attribution section is explicitly flagged 'not yet validated against real session data. Implementation is pending' (lines 1655-1657) - low evidentiary weight at a decision gate.
- Records generated incrementally MUST only be signed after the conversation concludes or at defined checkpoints (lines 6.1, ~2310-2312) - only relevant if the prototype ever signs.

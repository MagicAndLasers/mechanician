# Agent Session binding onto a vCon — encoder spec
Source: the pinned IETF draft `draft-howe-vcon-agent-session-00.txt`. Cross-checked against pinned `draft-ietf-vcon-vcon-core-03.txt` (core -03) and `draft-birkholz-verifiable-agent-conversations-00.txt` (VAC) in the same directory. All line numbers below are from the agent-session draft unless prefixed `core:` or `vac:`.

## 0. Extension declaration
- Extension token: `"agent_session"` registered in the vCon Extensions Names Registry (L237-240).
- Classification: Compatible Extension — no new top-level fields; new values only for party `role`, attachment `purpose`, analysis `type` (L212-218).
- Declaration: vCons with agent-session data **SHOULD** include `"agent_session"` in the top-level `extensions` array; **SHOULD** also put it in `critical` if downstream consumers MUST process the trace (e.g. the only record of an authorizing tool call lives there) (L250-254). `critical` is otherwise not required (L233-235).
- Timestamps anywhere in the document: RFC 3339 Internet date-time strings (L181-183).

## 1. Agent party (parties[] entry)
Each distinct agent **MUST** be a single `parties[]` entry with `role` set to `"agent"` (L258-260). Multiple agents (orchestrator + sub-agent) **MUST** each be a distinct party; other entries reference them by index (L317-319).

Keys (example L285-301):
| key | req | value |
|---|---|---|
| `name` | example only | e.g. `"Claude Opus 4.6"` (L286) |
| `role` | REQUIRED by this binding | `"agent"` (L259-260, L287) — **NOT in core -03** (see §6) |
| `validation` | example only | `"system"` (L288) — key exists in core -03 §4.2.7; value `"system"` is not among core's suggested values |
| `meta` | MAY (L260-261) | object — **NOT in core -03** (see §6) |
| `meta.agent_session.model_id` | string, REQUIRED (L305) | vendor model identifier, e.g. `"claude-opus-4-6"` (L291) |
| `meta.agent_session.provider` | string, REQUIRED (L307-308) | org providing the model, e.g. `"anthropic"`, `"openai"`, `"google"` |
| `meta.agent_session.recording_agent` | string, RECOMMENDED (L310-311) | harness/IDE/CLI, e.g. `"claude-code/1.2.0"` |
| `meta.agent_session.environment` | object, OPTIONAL (L313) | runtime context; members shown: `cwd`, `vcs_branch`, `vcs_commit` (L294-298). When the session edited a source repo, `vcs_branch` and `vcs_commit` SHOULD be set (L314-315) |

Note: the party identity is asserted, not cryptographic evidence (L550-555).

## 2. Agent dialog turns
User prompts / assistant replies are ordinary `dialog[]` entries; no new dialog type (L323-327). Single-agent reply: the dialog entry's `parties` field **MUST** reference the agent party; multi-agent reply: `parties` MAY list all contributing agents (L328-331).

## 3. agent_trace analysis entry
One analysis entry per session **SHOULD** span all its dialog turns, full trace as a JSON-encoded VAC record in `body` (L345-347). Shape (example L351-359):

| key | value | mandate |
|---|---|---|
| `type` | `"agent_trace"` | MUST (L361-363); registered in the vCon analysis type registry (L571-574) |
| `dialog` | array of dialog indices the trace applies to, e.g. `[0, 1]` | MUST (L365) |
| `vendor` | model provider — mirrors `parties[i].meta.agent_session.provider`, e.g. `"anthropic"` | MUST (L367-368) |
| `product` | model identifier — mirrors `model_id`, e.g. `"claude-opus-4-6"` | MUST (L370) |
| `schema` | URL of the VAC specification (or specific version), e.g. its canonical datatracker URL | MUST (L372-374) |
| `encoding` | `"json"` | MUST (L376) |
| `body` | a JSON-encoded verifiable-agent-record per the VAC schema | MUST (L378) |

**Body quirk (L358):** the draft's example shows `body` as a *string containing serialized JSON*: `"body": "{\"version\":\"1.0\",\"session-trace\":...}"`. Core -03 (core:L535-537) defines `encoding: "json"` to mean the body IS a JSON value (object/array). Encoder must pick a side and record the deviation. (Technically a string is a JSON value, so a stringified body does not violate core, but it defeats the point; the attachment example in this same draft uses a real object body.)

**Key-name mismatch (L358 vs L379 vs VAC):** the example body uses top-level key `"session-trace"` (L358) and the prose says "The CDDL-defined structure - session-trace.entries[]" (L379-380). But VAC's actual CDDL member is `session: session-trace` (vac:L1085-1094) — `session` is the key, `session-trace` is the type. A VAC-conformant body is `{"version":..., "id":..., "session": {..., "entries": [...]}}`. Pick a side; record the deviation.

Body semantics: the CDDL structure — `session-trace` entries with `message-entry`, `tool-call-entry`, `tool-result-entry`, `reasoning-entry`, and `event-entry` variants — preserved verbatim; `parent-id` / `children` tree relationships retained (L379-382).

## 4. Granularity options (§6.2, L384-409)
- Whole-session: one analysis entry spanning all dialog turns (L345-347). "The whole-session form is RECOMMENDED for archival." (L407)
- "*Per-tool-call*: one analysis entry per tool invocation, each referencing the specific dialog turn it served." Enables fine-grained redaction (e.g. removing a single reasoning entry containing PII) via the lifecycle extension, but produces more analysis entries (L397-402). "The per-tool-call form is RECOMMENDED when granular redaction or selective disclosure is anticipated." (L407-409)
- "*Per-branch*: one analysis entry per sub-agent branch in a multi-agent session." (L404-405)

CBOR variant (§6.3, one line): MAY set `encoding` to `"base64url"` with base64url CBOR body and `schema` qualified by `?encoding=cbor`; consumers MUST examine the schema URL to determine encoding (L411-418). Not needed for our corpus.

## 5. Attachments — purpose registry and body
Each file/artifact change **SHOULD** be an `attachments[]` entry with `purpose: "agent_file_change"` (or more specific) (L423-426). Example (L428-441):

```json
{
  "purpose": "agent_file_change",
  "party": 1,
  "dialog": 5,
  "encoding": "json",
  "body": {
    "path": "src/foo.py",
    "contributor": "agent",
    "line_range": [10, 25],
    "operation": "edit",
    "commit": "abc123",
    "content_hash": "sha512-..."
  }
}
```
- `party` index **MUST** identify the agent party that made the change (L453).
- `dialog` index **SHOULD** identify the dialog turn whose tool call effected the change, or the closing assistant turn for summary-level changes (L454-456).
- `body` members shown (all by example only — no per-member REQUIRED/OPTIONAL text): `path`, `contributor` (`"agent"`), `line_range` (2-int array `[start, end]`), `operation` (`"edit"` in example), `commit`, `content_hash` (`"sha512-..."` prefix form) (L434-439).
- Binary/large content: **SHOULD** use vCon's external media pattern (`url` + `content_hash`) instead of inlining `body` (L458-460).

Registered purposes (L467-473, IANA list L579-587):
- `agent_file_change` — "source file modified by the agent" (L467)
- `agent_artifact` — "non-file artifact generated by the agent (e.g. a database write, an API call payload, a generated document)" (L469-470)
- `agent_environment` — "snapshot of relevant agent environment state (working directory listing, package manifest, etc.)" (L472-473)
- `scitt_receipt` and `agent_trace_cose_sign1` — SCITT receipt and original COSE_Sign1 envelope MAY be carried as attachments (L487-489). Telephony/transfer structures: not defined by this draft at all; core -03 covers them — irrelevant to our corpus, existence noted only.

Lawful basis (exists, one paragraph): sessions processing personal data MUST have a documented lawful basis; SHOULD include a `lawful_basis` attachment with `purpose_grants` covering `agent_session_recording`, `agent_session_analysis`, and where applicable `agent_session_redistribution` (L495-513). Tool args/results MUST be scrubbed/redacted before distribution outside the grant (L541-544). Reasoning bodies may be JWE-encrypted with `encoding: "jwe"` (L533-534) — also not a core -03 encoding enum value.

## 6. Divergences from core -03 (encoder must pick a side, record each)
Core -03 Party Object keys are exactly: `tel, sip, stir, mailto, name, did, validation, gmlpos, civicaddress, uuid, type, org, dept` (core -03 §4.2.1-4.2.13). Therefore:
1. **`role` does not exist in core -03.** Core -03 has `type` instead (§4.2.11, optional, SHOULD be one of `"person"`, `"bot"`, `"organization"`). The draft's L214-217 claim to define "new values for the role field" is stale against -03 (draft was written against core-02, L603-606). Options: (a) emit `role:"agent"` as the extension specifies (unknown key, Compatible-extension-safe), (b) emit core `type` (but `"agent"` is not an enumerated value), or (c) both. Record whichever.
2. **`meta` does not exist in core -03** as a Party Object key. It is an extension-added key; Compatible-extension rules permit unknown keys, but it must be recorded as a deviation from the core key set.
3. **`validation: "system"`**: `validation` exists in core -03 (§4.2.7) but `"system"` is not a listed value ("none" or enterprise-specific). Example-only in the draft; safe to omit or record.
4. **`encoding: "json"` semantics**: core -03 enum is `["base64url","json","none"]`; `"json"` = body is a JSON value. The agent_trace example's stringified body (L358) conflicts in spirit (see §3).
5. **`encoding: "jwe"`** (L534) is not in core -03's encoding enum.
Everything else the binding uses (`purpose`, `party`, `dialog`, `body`, `encoding`, `url`, `content_hash` on attachments; `type`, `dialog`, `vendor`, `product`, `schema`, `body`, `encoding` on analysis) exists in core -03 (§4.4, §4.5).

## 7. Worked minimal example
```json
{
  "vcon": "0.3.0",
  "uuid": "<uuid8>",
  "created_at": "2026-08-02T12:00:00Z",
  "extensions": ["agent_session"],                       // L250-251 (SHOULD)
  "parties": [
    { "name": "Alex Rivera", "type": "person" },         // core -03 §4.2.11
    {
      "name": "Claude Opus 4.6",                          // L286
      "role": "agent",                                    // L259-260, L287 — NOT in core -03; recorded deviation
      "meta": {                                           // L260-261 — NOT in core -03; recorded deviation
        "agent_session": {                                // L290
          "model_id": "claude-opus-4-6",                  // L291, REQUIRED L305
          "provider": "anthropic",                        // L292, REQUIRED L307
          "recording_agent": "claude-code/1.2.0",         // L293, RECOMMENDED L310
          "environment": {                                // L294, OPTIONAL L313
            "cwd": "/Users/example/project",              // L295
            "vcs_branch": "main",                         // L296, SHOULD-when-repo L314-315
            "vcs_commit": "abc123def456"                  // L297
          }
        }
      }
    }
  ],
  "dialog": [
    { "type": "text", "parties": [0], "body": "Fix the bug in foo.py", "encoding": "none" },
    { "type": "text", "parties": [1], "body": "Done — edited src/foo.py.", "encoding": "none" }   // MUST reference agent party, L329-330
  ],
  "analysis": [
    {
      "type": "agent_trace",                              // L352, MUST L363; IANA L574
      "dialog": [0, 1],                                   // L353, MUST L365
      "vendor": "anthropic",                              // L354, MUST L367 (mirrors provider)
      "product": "claude-opus-4-6",                       // L355, MUST L370 (mirrors model_id)
      "schema": "https://datatracker.ietf.org/doc/draft-birkholz-verifiable-agent-conversations/",  // L356, MUST L372-374
      "encoding": "json",                                 // L357, MUST L376
      "body": "{\"version\":\"1.0\",\"id\":\"sess-1\",\"session\":{\"session-id\":\"sess-1\",\"entries\":[]}}"
      // ^ draft example is stringified with key "session-trace" (L358); VAC CDDL key is "session" (vac L1088).
      //   Encoder decision + recorded deviation required either way.
    }
  ],
  "attachments": [
    {
      "purpose": "agent_file_change",                     // L429, registry L467/L579
      "party": 1,                                         // L430, MUST be the agent party L453
      "dialog": 1,                                        // L431, SHOULD be effecting/closing turn L454-456
      "encoding": "json",                                 // L432 (body is a real object here, matching core -03 "json")
      "body": {
        "path": "src/foo.py",                             // L434
        "contributor": "agent",                           // L435
        "line_range": [10, 25],                           // L436
        "operation": "edit",                              // L437
        "commit": "abc123",                               // L438
        "content_hash": "sha512-..."                      // L439
      }
    }
  ]
}
```

## Trap notes
- Party key is `role` (value "agent"), not core -03's `type` — `role` does not exist anywhere in core -03's Party Object (core has type: person|bot|organization). The draft was written against core-02; the encoder must pick role, type, or both, and record the deviation.
- `meta` is also not a core -03 Party Object key — it comes only from this extension. Emitting it is Compatible-extension-legal but must be logged as a core-key-set deviation.
- agent_trace body quirk (L358): the example puts STRINGIFIED JSON in `body` while declaring `encoding:"json"`; core -03 defines encoding "json" as body-IS-a-JSON-value. The attachment example in the same draft uses a real object body. Decide once, record it.
- Key mismatch L358/L379 vs VAC: the draft writes `"session-trace":...` in the body and prose, but VAC's CDDL member is `session: session-trace` — the JSON key in a conformant verifiable-agent-record is `session` (with `version` and `id` also required at top level, per VAC L1085-1094).
- `vendor` and `product` on the analysis entry are NOT free-form: they MUST mirror meta.agent_session.provider and model_id respectively (L367-370). Easy to fill with harness name by mistake.
- All seven analysis keys (type/dialog/vendor/product/schema/encoding/body) are individually MUST ("The analysis entry MUST set:", L361) — schema is mandatory, not optional as in core -03.
- extensions[] gets "agent_session" at SHOULD level; `critical` only if consumers MUST process the trace (L250-254). Don't put it in critical by default.
- Attachment `party` MUST point at the agent party index (L453) — not the human; `dialog` SHOULD point at the turn whose tool call made the change, else the closing assistant turn (L454-456).
- attachment body members (path/contributor/line_range/operation/commit/content_hash) are defined only by example — no per-member REQUIRED markers exist; content_hash uses the "sha512-..." prefix string form; line_range is a 2-element [start,end] array.
- `validation:"system"` (L288) is example-only and "system" is not a core -03 validation value; safe to omit.
- Multiple agents: one parties[] entry PER distinct agent is MUST (L258-260, L317-319) — never collapse orchestrator+subagent into one party.
- Large/binary file content: SHOULD use url+content_hash external pattern, not inline body (L458-460).
- Purposes registered: agent_file_change, agent_artifact, agent_environment, scitt_receipt, agent_trace_cose_sign1 (L579-587). The last two are for COSE/SCITT lanes only — one-line existence note is enough for our corpus.
- All timestamps RFC 3339 (L181-183).

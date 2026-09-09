# Minimal valid unsigned vCon — encoding spec (draft-ietf-vcon-vcon-core-03)

Source: the pinned IETF draft `draft-ietf-vcon-vcon-core-03.txt` (all line refs below are into
that file). The pinned `.txt` copy is not in this repository, so the line numbers below cannot be
checked from a clone alone; the draft itself is public at datatracker.ietf.org.

## 0. Global rules

- **Mandatory-by-default**: "All parameters are assumed to be mandatory unless other wise noted." (l.486). Every key below marked (optional) is quoting the draft's own marker; everything else is required.
- **Omit empties**: "Objects or arrays with no or null values MAY be excluded from the vCon." (l.488-489). Do not emit `"analysis": []`, `"attachments": []`, `"redacted": {}` — omit the keys.
- **snake_case** for all parameter names (extension convention, l.608-609); names are case-sensitive (l.833-834).
- **Date type** = RFC3339 date string per JMAP §1.4 (l.405-406). Draft examples use millisecond precision with numeric offset: `"2022-06-21T17:53:26.000+00:00"` (l.3872) and `"2026-06-29T23:03:01.095+00:00"` (l.4249). Use that exact shape.
- **Inline content rule** (l.493-497): any object carrying inline data MUST have `body` + `encoding`. `encoding` MUST be one of exactly three strings (l.530-541): `"base64url"`, `"json"`, `"none"` ("none" = payload is already a valid JSON string). External alternative: `url` (HTTPS, l.567-569) + `content_hash` (`"ContentHash" | "ContentHash[]"`); ContentHash token = `sha512-<Base64Url(SHA-512 digest)>` (l.453-461; example l.4453-4454). `content_hash` MUST accompany `url` wherever url is used for prior-vCon refs (l.938, l.1043).

## 1. Top-level object (unsigned form, §4/§4.1)

Complete key registry (Table 1, l.2873-2928): `vcon, uuid, extensions, critical, created_at, updated_at, subject, redacted, amended, group (reserved), parties, dialog, analysis, attachments`.

| key | req? | type / constraint |
|---|---|---|
| `vcon` | DEPRECATED — omit | If present MUST be `"0.4.0"` (l.762, l.770-773) |
| `uuid` | REQUIRED (no optional marker, l.789) | String; MUST be globally unique (l.779). SHOULD be UUID **version 8**: generated like v7 except rand_b/custom_c = high 62 bits of SHA-1 of the FQHN string, variant/version set per v8 (l.791-799); DNS name SHOULD match the signing-cert FQHN or subdomain (l.801-804). **Cost of plain UUIDv4**: violates only this SHOULD — the vCon stays valid; you lose the v7-style time-ordering and the domain-of-uniqueness correlation with a signing cert. Real examples: `"019f155a-5131-80ec-b9a2-279e0d16bc46"` (l.4098) |
| `created_at` | REQUIRED — "MUST be present, and should not change" (l.830-832) | Date |
| `parties` | REQUIRED (l.1109, no optional marker) | `Party[]` (§4.2) |
| `updated_at` | optional (MAY, l.848) | Date |
| `subject` | optional (l.865) | free-form String |
| `extensions` | optional; SHOULD list names of all extensions used beyond core (l.809-813) | `String[]` |
| `critical` | conditionally REQUIRED: incompatible extensions MUST be listed here (l.817-819) | `String[]`; consumers not supporting a listed extension MUST NOT process except reject/notify (l.821-824, l.694-697) |
| `redacted` | optional; mutually exclusive with `amended` (l.915-916) | Redacted object (§4.1.8.1) |
| `amended` | optional; mutually exclusive with `redacted` (l.1029-1030) | Amended object (§4.1.9.1) |
| `dialog` | optional (l.1130) | `Dialog[]`; array order = insertion order, NOT chronological (l.1133-1136); never reorder — indices elsewhere point into it (l.1526-1529) |
| `analysis` | optional (l.1143) | `Analysis[]` |
| `attachments` | optional (l.1155) | `Attachment[]` |

Minimal valid vCon = `uuid` + `created_at` + `parties` only.

## 2. Party object (§4.2)

Full key set (Table 2 l.2973-3014 + §4.2 text): `tel, sip, stir, mailto, name, did, validation, gmlpos, civicaddress, uuid, type, org, dept`. **There is NO `role` key.** All party keys are optional; an empty Party Object `{}` is legal (l.1166-1170). Parties are identified positionally — "distinct by the order or index in the Party Object array" (l.1169-1170).

Keys we use:
- `name`: String (optional, l.1227); free-form; `"anonymous"` is the privacy convention (l.1240-1241).
- `type`: String (optional, l.1382); value SHOULD be one of exactly: `"person"`, `"bot"`, `"organization"` (l.1384-1385). Human user → `"person"`; software agent → `"bot"`.
- `uuid`: String (optional, l.1373); stable participant id across interactions (agent correlation, l.1367-1371).
- `validation`: String — "(SHOULD be provided if name parameter is provided)" (l.1282-1283); value MAY be `"none"` or a domain-defined token (l.1293-1294); must NOT contain the validating data itself (l.1276-1277).
- `mailto`: String (optional, l.1215); bare address or mailto URL, scheme prefix optional (l.1217-1220).
- `org` / `dept`: free-form Strings (optional, l.1392, l.1411).
- `tel`, `sip`, `stir`, `did`, `gmlpos`, `civicaddress`: telephony/location keys, optional — exist but unused by our corpus (l.1186, 1195, 1205, 1254, 1303, 1314).

## 3. Dialog object, type "text" (§4.3)

Full dialog key registry (Table 3, l.3036-3144): `type, start, duration, parties, originator, mediatype, filename, body, encoding, url, content_hash, disposition, session_id, party_history, transferee, transferor, transfer_target, original, consultation, target_dialog, application, message_id, recordings, recording_set`.

For a `"text"` dialog entry:
- `type`: String, REQUIRED. MUST be one of exactly: `"recording"`, `"recording-set"`, `"text"`, `"transfer"`, `"incomplete"` (l.1482-1485).
- `start`: Date, REQUIRED (l.1531, no optional marker). Time party started typing, or if unknown, time the text was sent (l.1520-1522).
- `parties`: REQUIRED (l.1553-1554). Type `"UnsignedInt" | "UnsignedInt[]" | ("UnsignedInt"|"UnsignedInt[]")[]` — values are **zero-based indices into the top-level parties array** (l.1556-1559; examples use `[0, 1]`, l.4128-4131). First listed party is the implied originator (l.1604-1605); for email, From-header party first, then To/Cc/Bcc order (l.1631-1635).
- `originator`: UnsignedInt (optional, l.1649) — index into parties array; "only provided if the first party of the dialog Object parties list is NOT the originator" (l.1645-1647).
- `mediatype`: Mediatype string `type "/" subtype` (l.420-423). "MUST be provided for inline dialog files" (l.1688-1689) — so REQUIRED for our inline text; SHOULD be from the list at l.1696-1712 (`"text/plain"` is first; audio/video/multipart values exist for recordings).
- Dialog Content (§4.3.10, l.1726-1751): SHOULD contain `body`+`encoding` (inline) OR `url`+`content_hash` (external); for inline: `body: "*"`, `encoding: "String"` — one of `"base64url" | "json" | "none"` (l.530-541). Plain UTF-8 text → `"encoding": "none"`, body is the literal string (example: l.4125-4135 uses type "text", encoding "none", inline body).
- `duration`: UnsignedInt|UnsignedFloat seconds (optional, l.1544); email example uses `"duration": 0` (l.4127).
- `message_id`: String (optional, l.2010) — dedupe/cross-reference id; `application`: String (optional, l.1996) — source app/channel.
- Not for text type: `disposition` is required only for `"incomplete"` and SHOULD NOT appear otherwise (l.1765-1766); `recordings`/`recording_set` MUST NOT appear outside recording-set scenarios (l.1663-1664, l.1676); `transferee/transferor/transfer_target/original/consultation/target_dialog` are transfer-metadata keys (§4.3.14) — exist, unused by us; `party_history` (§4.3.13) and `session_id` (§4.3.12) are telephony-oriented optionals.

## 4. Analysis object (§4.5)

- `type`: String, REQUIRED (l.2152). Value SHOULD be one of: `"report"`, `"sentiment"`, `"summary"`, `"transcript"`, `"translation"`, `"tts"` (l.2154-2166) — SHOULD, so other labels are legal.
- `dialog`: `"UnsignedInt" | "UnsignedInt[]"` — "(optional only if the analysis was not derived from any of the dialog)" (l.2174-2175); index/indices into the dialog array (l.2177-2179). If your analysis derives from dialog, include it.
- `attachment`: same shape, for analyses of attachments (l.2195-2196); optional unless derived from attachments.
- `vendor`: String, REQUIRED (l.2234, no optional marker) — vendor or product name of the generating software.
- `product`: String (optional, l.2254).
- `schema`: String (optional, l.2263) — **free-form**: "a token or label for the data format or schema" (l.2265-2266); no registry, no constrained syntax.
- `mediatype`: optional for external refs (l.2207); include for inline.
- Content (§4.5.9, l.2273-2289): `body`+`encoding` or `url`+`content_hash`, same rules as dialog. JSON analysis payload → `"encoding": "json"` with body as a raw JSON value (spec l.535-537; example l.5474-5477: `"encoding": "json", "vendor": "deepgram", "schema": "deepgram_prerecorded", "product": "transcription"`).
- `filename`: String (optional, l.2219).

## 5. Attachment object (§4.4)

- `start`: Date, REQUIRED (l.2046, no optional marker) — time the attachment was sent/exchanged.
- `party`: UnsignedInt, REQUIRED — "To provide provenance for the attachment, the party index MUST be specified" (l.2054-2055, l.2062). The contributing party need not be a conversation participant, but SHOULD be represented as a Party Object (l.2056-2060).
- `dialog`: UnsignedInt, REQUIRED (l.2084, no optional marker) — index of the dialog the attachment is part of.
- `purpose`: String (optional, l.2035); `mediatype` (optional for external, l.2091); `filename` (optional, l.2103).
- Content (§4.4.7, l.2110-2133): `body`+`encoding` or `url`+`content_hash`, same encoding enum.

## 6. Redaction / amendment references (§4.1.8, §4.1.9)

Both are single objects (not arrays) at top level, mutually exclusive.

`"redacted"` object (§4.1.8.1, l.918-942):
```json
"redacted": { "uuid": "<prior vCon uuid>", "type": "<what was redacted>",
              "url": "https://...", "content_hash": "sha512-..." }
```
- `uuid`: String — uuid of the unredacted/prior instance; absence means the less-redacted version is unavailable/nonexistent (l.922-927).
- `type`: String — kind of redaction performed (l.929-934).
- `url`/`content_hash` MAY be added; `content_hash` MUST be included if `url` is provided (l.936-942). URL access MUST be restricted (l.882-884).
- Redacting array elements: leave empty placeholder objects so indices don't shift (l.910-913).

`"amended"` object (§4.1.9.1, l.1032-1047):
```json
"amended": { "uuid": "<prior vCon uuid>" }
```
- `uuid`: String "(optional if inline or external reference provided)" (l.1036); `url` + `content_hash` MAY be included, `content_hash` MUST accompany `url` (l.1041-1047).
- Semantics: amended vCon is a NEW instance (new top-level uuid) that is a deep copy of the prior version plus the added data (l.1015-1022); prior SHOULD be referenced via its uuid (l.1024-1025).

## 7. extensions[] / critical[] semantics (§2.5, §4.1.3-4.1.4)

- `extensions: String[]` — SHOULD list registered names of all extensions whose parameters appear but aren't in core (l.809-813).
- `critical: String[]` — MUST list every incompatible ("disruptive") extension used (l.688-690, l.817-819); a reader lacking support for any listed name MUST NOT process the vCon except to reject/report (l.694-697, l.821-824). Compatible extensions can be safely ignored by non-supporting readers (l.650-653). For our sanitizing exporter: emit neither key unless we actually add non-core parameters; any custom key we invent is formally an unregistered extension.

## 8. Worked minimal example (every key verified against the sections cited above)

```json
{
  "uuid": "0198a7f2-4c31-8f6e-b1d4-9e2a77c31f05",
  "created_at": "2026-08-02T17:00:00.000+00:00",
  "subject": "Fix the flaky launch test",
  "parties": [
    { "name": "Alex Rivera", "type": "person", "mailto": "alex@example.com", "validation": "none" },
    { "name": "Claude (Mechanician)", "type": "bot", "org": "Magic & Lasers",
      "uuid": "0198a7f2-9a10-8c4b-b1d4-9e2a77c31f05" }
  ],
  "dialog": [
    { "type": "text",
      "start": "2026-08-02T17:00:05.000+00:00",
      "parties": [0, 1],
      "mediatype": "text/plain",
      "encoding": "none",
      "body": "The launch test is flaky again. Can you look?" },
    { "type": "text",
      "start": "2026-08-02T17:00:41.000+00:00",
      "parties": [1, 0],
      "mediatype": "text/plain",
      "encoding": "none",
      "body": "Found it. The sidebar paint races the corpus decode. Fixing." }
  ],
  "analysis": [
    { "type": "summary",
      "dialog": [0, 1],
      "vendor": "Magic & Lasers",
      "product": "Mechanician",
      "schema": "mechanician-turn-summary-v1",
      "mediatype": "text/plain",
      "encoding": "none",
      "body": "User reported a flaky launch test; agent identified a paint/decode race and began a fix." }
  ]
}
```
Verification notes: top-level carries only registered keys with the three REQUIRED ones present; no `vcon` key (deprecated); no empty arrays/objects; both dialogs put the originator first so `originator` is correctly omitted (l.1645-1647); party indices are 0-based positions in `parties`; `encoding: "none"` is legal because each body is a plain JSON string (l.539-541); analysis has REQUIRED `type` + `vendor` and its `dialog` indices reference existing dialog entries; the parties/uuid/created_at shapes match the draft's own Appendix A examples (l.3850-3860, l.4249-4252). uuid values shown are v7-shaped placeholders — generate real UUIDv8 (or accept the SHOULD-violation with v4).

## Trap notes
- The media type key is `mediatype`, NOT `mimetype` — `mimetype` is the pre-0.0.2 name (renamed at l.3616). Similarly `critical` was `must_support` and `amended` was `appended` (l.3596-3599); older blog/example code uses the dead names.
- Do NOT emit a `vcon` version key: it is DEPRECATED (l.762). If you must emit it, the only legal value is "0.4.0" (l.772-773).
- Appendix example A.1 omits `created_at` entirely (object ends l.4093-4099) and A.2 emits `"redacted": {}` and empty `"analysis": []`/`"attachments": []` and an unregistered `"group": []` (l.4112, l.4247-4250) — the draft's own examples violate the created_at MUST (l.830-831) and the omit-empties guidance (l.488-489). Do not copy the examples' habits; follow the normative text.
- Party has NO `role` key. The full registered set is tel, sip, stir, mailto, name, validation, gmlpos, civicaddress, uuid, type, org, dept (Table 2, l.2973-3014) plus `did` (§4.2.6, l.1249 — defined in text but missing from the registry table). Role-like data must go in name/org/dept or an extension.
- Party `type` recommended values are exactly "person", "bot", "organization" (l.1384-1385) — 'bot' not 'agent'/'assistant'.
- `encoding` is a closed enum: base64url | json | none (l.530-541). "none" means the payload is already a valid JSON string; a JSON-object analysis body takes encoding "json" with the body as a raw JSON value, not a stringified blob.
- `originator` is only emitted when the FIRST entry of the dialog's `parties` list is NOT the originator (l.1645-1647); the first-listed party is otherwise the implied originator (l.1604-1605). Easiest: always list the originator first and omit the key.
- Dialog/attachment arrays are insertion-ordered, not chronological, and MUST NOT be reordered after the fact — analysis.dialog / attachment.dialog / attachment.party are positional indices into them (l.1133-1136, l.1526-1529, l.2041-2044).
- Attachment `party` and `dialog` are both REQUIRED UnsignedInt indices (party MUST be specified for provenance, l.2054-2055; dialog has no optional marker, l.2084) — an attachment cannot float free of a dialog in core schema.
- Analysis `vendor` is REQUIRED (l.2234 has no optional marker under the l.486 mandatory-by-default rule) — easy to forget for self-generated analyses; `schema` is a free-form label with no registry (l.2263-2266).
- `validation` SHOULD accompany any party `name` (l.1282-1283); "none" is an explicitly sanctioned value (l.1293). The draft's own examples skip it; emitting "none" is the cheap way to honor the SHOULD.
- uuid: UUIDv8 (v7 layout with rand_b = high 62 bits of SHA-1 of your FQHN) is a SHOULD, not MUST (l.791-799). Plain UUIDv4 keeps the vCon valid; the cost is losing time-ordering and the FQHN/signing-domain correlation (l.801-804) — acceptable for a throwaway prototype, note it at the gate.
- `redacted` and `amended` are mutually exclusive single objects (l.915-916, l.1029-1030); in both, `content_hash` becomes MUST the moment `url` is present (l.938, l.1043). An amended vCon is a NEW instance (fresh top-level uuid) deep-copying the prior one (l.1017-1022).
- When redacting elements out of any array, leave empty-object placeholders so downstream indices don't shift (l.910-913).
- Date strings: RFC3339 per JMAP §1.4 (l.405-406); draft examples consistently use millisecond precision with +00:00 numeric offset (l.3872, l.4249) — prefer that exact shape over 'Z' for byte-level consistency with reference tooling.
- Any custom key you add outside the registered sets is formally an extension: it SHOULD be named in extensions[] (l.809-813), and MUST be in critical[] only if misreading it breaks interpretation (l.688-690) — putting a compatible extension in critical[] forces conforming readers to reject the vCon (l.821-824).

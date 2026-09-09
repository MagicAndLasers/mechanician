import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { randomUUID } from 'node:crypto'

const DEFAULT_INLINE_EVENT_BYTES = 4096
const DEFAULT_MAX_SUMMARY_BYTES = 1024 * 1024

function boundedUTF8(value, maxBytes) {
  const encoded = Buffer.from(value, 'utf8')
  if (encoded.length <= maxBytes) return { text: value, truncated: false }

  // A UTF-8 scalar is at most four bytes. Decode fatally while backing off that tiny suffix so a
  // genuine U+FFFD at the boundary is retained instead of mistaken for decoder repair.
  const decoder = new TextDecoder('utf-8', { fatal: true })
  for (let end = maxBytes; end >= Math.max(0, maxBytes - 3); end -= 1) {
    try { return { text: decoder.decode(encoded.subarray(0, end)), truncated: true } }
    catch {}
  }
  return { text: '', truncated: true }
}

// Convert the Claude Agent SDK's supported PostCompact hook payload into Mechanician's
// provider-neutral turn event. Subagent compaction is deliberately excluded: its context is not
// the root conversation epoch represented by the transcript boundary.
//
// stdout is a control bus with a measured ~6 KiB single-line failure floor. The complete bounded
// summary therefore stays inline only when the serialized event fits below 4 KiB; otherwise a
// random temp-file handoff carries the payload and the event carries only its locator.
export function claudeCompactionSummaryEvent(
  turnID,
  input,
  {
    compactionSequence,
    inlineEventBytes = DEFAULT_INLINE_EVENT_BYTES,
    maxSummaryBytes = DEFAULT_MAX_SUMMARY_BYTES,
    tempDirectory = os.tmpdir(),
  } = {},
) {
  if (typeof turnID !== 'string' || !turnID) return null
  if (input?.hook_event_name !== 'PostCompact' || input.agent_id) return null
  if (typeof input.compact_summary !== 'string' || !input.compact_summary.trim()) return null
  if (!Number.isSafeInteger(compactionSequence) || compactionSequence <= 0) return null
  if (!Number.isSafeInteger(inlineEventBytes) || inlineEventBytes <= 0) return null
  if (!Number.isSafeInteger(maxSummaryBytes) || maxSummaryBytes <= 0) return null

  const summary = boundedUTF8(input.compact_summary, maxSummaryBytes)
  const base = {
    type: 'compaction_summary',
    id: turnID,
    trigger: input.trigger === 'manual' ? 'manual' : 'auto',
    compactionSequence,
    summarySource: 'claude_post_compact',
    summaryTruncated: summary.truncated,
    summaryBytes: Buffer.byteLength(summary.text, 'utf8'),
    sessionId: typeof input.session_id === 'string' && input.session_id
      ? input.session_id
      : null,
    promptId: typeof input.prompt_id === 'string' && input.prompt_id
      ? input.prompt_id
      : null,
  }
  const inline = { ...base, summary: summary.text }
  if (Buffer.byteLength(JSON.stringify(inline), 'utf8') + 1 <= inlineEventBytes) return inline

  const summaryPath = path.join(
    tempDirectory,
    `mechanician-compaction-${randomUUID()}.summary`,
  )
  try {
    fs.writeFileSync(summaryPath, summary.text, { encoding: 'utf8', flag: 'wx', mode: 0o600 })
  } catch {
    // Compaction itself must never fail because its optional visibility handoff could not be
    // written. The streamed compact_boundary still gives the app a truthful opaque boundary.
    return null
  }
  return { ...base, summaryPath }
}

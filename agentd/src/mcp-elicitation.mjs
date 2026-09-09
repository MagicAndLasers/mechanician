// MCP elicitation — letting a mounted MCP server ask the user a question mid-turn.
//
// Elicitation is a standard part of MCP: a server can pause and ask for input it could not know in
// advance. agentd used to answer every one of these with `{ action: 'decline' }`, which was honest
// about having no surface but meant EVERY server that elicits was unusable in Mechanician,
// regardless of provider. Codex's `sites` plugin is the visible casualty; it is not the only one.
//
// Shape is the app-server's own, read from the generated schema rather than guessed:
//   request  { threadId, turnId|null, serverName, mode, message, ... }
//     mode "form"        -> requestedSchema: a typed MCP object schema (string/number/boolean/enum)
//     mode "openai/form" -> requestedSchema: opaque JSON, OpenAI's own richer form
//     mode "url"         -> url + elicitationId; the user visits a page instead of filling a form
//   response { action: "accept"|"decline"|"cancel", content: JSON|null, _meta: JSON|null }
//
// `decline` means "the person said no to this prompt"; `cancel` means "the prompt is going away".
// The difference matters to a server deciding whether to retry, so it is preserved rather than
// collapsed.

/// A question we can actually render. Everything the app needs to draw a form, normalised out of
/// the four schema dialects the protocol allows — untitled enums, titled `oneOf` enums, titled
/// `anyOf` multi-selects, and the legacy `enum` + `enumNames` pairing.
function normaliseField(name, schema) {
  if (!schema || typeof schema !== 'object') return null
  const base = {
    name,
    title: typeof schema.title === 'string' ? schema.title : name,
    description: typeof schema.description === 'string' ? schema.description : '',
  }

  // Multi-select: an array whose items enumerate their options.
  if (schema.type === 'array') {
    const items = schema.items || {}
    const options = enumOptions(items)
    if (!options.length) return null
    return {
      ...base,
      kind: 'multiSelect',
      options,
      defaultValue: Array.isArray(schema.default) ? schema.default : [],
      minItems: Number.isFinite(schema.minItems) ? Number(schema.minItems) : null,
      maxItems: Number.isFinite(schema.maxItems) ? Number(schema.maxItems) : null,
    }
  }

  const options = enumOptions(schema)
  if (options.length) {
    return {
      ...base,
      kind: 'select',
      options,
      defaultValue: typeof schema.default === 'string' ? schema.default : null,
    }
  }

  switch (schema.type) {
    case 'string':
      return {
        ...base,
        kind: 'string',
        format: typeof schema.format === 'string' ? schema.format : null,
        minLength: Number.isFinite(schema.minLength) ? Number(schema.minLength) : null,
        maxLength: Number.isFinite(schema.maxLength) ? Number(schema.maxLength) : null,
        defaultValue: typeof schema.default === 'string' ? schema.default : '',
      }
    case 'number':
    case 'integer':
      return {
        ...base,
        kind: 'number',
        integer: schema.type === 'integer',
        minimum: Number.isFinite(schema.minimum) ? Number(schema.minimum) : null,
        maximum: Number.isFinite(schema.maximum) ? Number(schema.maximum) : null,
        defaultValue: Number.isFinite(schema.default) ? Number(schema.default) : null,
      }
    case 'boolean':
      return { ...base, kind: 'boolean', defaultValue: schema.default === true }
    default:
      return null
  }
}

/// `{const,title}` pairs from whichever of the four dialects this schema speaks.
function enumOptions(schema) {
  if (!schema || typeof schema !== 'object') return []
  const titled = (list) => (Array.isArray(list) ? list : [])
    .filter((o) => o && typeof o.const === 'string')
    .map((o) => ({ value: o.const, label: typeof o.title === 'string' ? o.title : o.const }))

  if (Array.isArray(schema.oneOf)) return titled(schema.oneOf)
  if (Array.isArray(schema.anyOf)) return titled(schema.anyOf)
  if (Array.isArray(schema.enum)) {
    // Legacy pairing: `enum` carries values, optional `enumNames` carries their labels.
    const names = Array.isArray(schema.enumNames) ? schema.enumNames : []
    return schema.enum
      .filter((v) => typeof v === 'string')
      .map((v, i) => ({ value: v, label: typeof names[i] === 'string' ? names[i] : v }))
  }
  return []
}

/**
 * Turn an elicitation request into something the app can render, or explain why it cannot.
 *
 * Returns `{ renderable: false, reason }` rather than throwing: an unrenderable elicitation must
 * still be answered, and a server left waiting for a reply wedges the whole lane.
 */
export function describeElicitation(params) {
  const mode = String(params?.mode || '')
  const message = typeof params?.message === 'string' ? params.message : ''
  const serverName = String(params?.serverName || 'An extension')
    .replace(/[\r\n\t]/g, ' ').slice(0, 160)

  if (mode === 'url') {
    const url = typeof params?.url === 'string' ? params.url : ''
    // Only web URLs. A server naming a `file://` or custom-scheme target is asking us to open
    // something it should not be able to choose.
    if (!/^https:\/\//i.test(url)) {
      return { renderable: false, reason: 'asked to open a link that is not https', serverName }
    }
    return { renderable: true, mode: 'url', serverName, message, url, fields: [] }
  }

  if (mode !== 'form' && mode !== 'openai/form') {
    return { renderable: false, reason: `used an unsupported prompt type (${mode})`, serverName }
  }

  // `openai/form` is an opaque JSON value in the protocol — OpenAI's own richer form format. When
  // it happens to be an ordinary object schema, the same renderer handles it; when it is something
  // else, say so rather than showing a blank sheet.
  const schema = params?.requestedSchema
  const properties = schema && typeof schema === 'object' ? schema.properties : null
  if (!properties || typeof properties !== 'object') {
    return { renderable: false, reason: 'sent a form this version cannot display', serverName }
  }

  // An elicitation with NO properties is not a form — it is a yes/no question. Codex uses this
  // shape for its own approvals ("Allow the X server to run tool Y?", marked with
  // `_meta.codex_approval_kind`), and MCP servers use it for plain confirmations. Refusing it as an
  // "empty form" declines the approval and fails the tool call, which is how this was found.
  if (!Object.keys(properties).length) {
    return {
      renderable: true,
      mode: 'confirm',
      serverName,
      message,
      fields: [],
      approvalKind: typeof params?._meta?.codex_approval_kind === 'string'
        ? params._meta.codex_approval_kind : null,
    }
  }

  const required = new Set(Array.isArray(schema.required) ? schema.required : [])
  const fields = []
  for (const [name, property] of Object.entries(properties)) {
    const field = normaliseField(name, property)
    // One unrenderable field makes the whole answer wrong, because a required field we cannot show
    // cannot be filled in. Refuse the form rather than submit a partial one.
    if (!field) {
      return { renderable: false, reason: `sent a form field this version cannot display (${name})`, serverName }
    }
    fields.push({ ...field, required: required.has(name) })
  }
  return { renderable: true, mode: 'form', serverName, message, fields }
}

/// The reply for something we cannot render. `decline` rather than `cancel`: the prompt is not
/// going away, we are answering it in the negative, and a server that distinguishes the two should
/// see the truthful one.
export function declineReply() {
  return { action: 'decline', content: null, _meta: null }
}

/**
 * The same answer, shaped for the MCP SDK rather than for Codex's app-server.
 *
 * Codex accepts (and this module has always produced) explicit nulls for `content` and `_meta`.
 * MCP's own `ElicitResultSchema` does NOT: `_meta` is an OPTIONAL OBJECT and `content` an optional
 * record, so `null` fails validation rather than reading as "absent". Sending the Codex shape down
 * the Claude lane would therefore be rejected by the schema after the user had already answered —
 * the worst place to fail. Drop the nulls instead of teaching every caller two dialects.
 */
export function toMCPElicitResult(reply) {
  const result = { action: reply?.action === 'accept' || reply?.action === 'cancel'
    ? reply.action : 'decline' }
  if (reply?.content && typeof reply.content === 'object' && !Array.isArray(reply.content)) {
    result.content = reply.content
  }
  if (reply?._meta && typeof reply._meta === 'object' && !Array.isArray(reply._meta)) {
    result._meta = reply._meta
  }
  return result
}

/**
 * Coerce the app's answers into the JSON the server expects.
 *
 * Types matter to the receiving server — a number field answered with the string "3" is a protocol
 * violation, not a formatting quirk — so each field is converted according to its own schema rather
 * than passed through as typed.
 */
export function buildContent(fields, answers) {
  const content = {}
  for (const field of fields || []) {
    const raw = answers?.[field.name]
    if (raw === undefined || raw === null) continue
    switch (field.kind) {
      case 'boolean':
        content[field.name] = raw === true || raw === 'true'
        break
      case 'number': {
        const value = typeof raw === 'number' ? raw : Number(String(raw).trim())
        if (!Number.isFinite(value)) continue
        content[field.name] = field.integer ? Math.trunc(value) : value
        break
      }
      case 'multiSelect':
        content[field.name] = Array.isArray(raw) ? raw.filter((v) => typeof v === 'string') : []
        break
      default: {
        const value = String(raw)
        // An empty optional string is an absent answer, not an empty one.
        if (!value && !field.required) continue
        content[field.name] = value
      }
    }
  }
  return content
}

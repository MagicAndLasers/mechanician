import assert from 'node:assert/strict'
import test from 'node:test'

import {
  buildContent, declineReply, describeElicitation, toMCPElicitResult,
} from '../src/mcp-elicitation.mjs'

const form = (properties, required = []) => ({
  mode: 'form',
  serverName: 'sites',
  message: 'Pick a design',
  requestedSchema: { type: 'object', properties, required },
})

test('a plain form becomes renderable fields with their constraints', () => {
  const d = describeElicitation(form({
    name: { type: 'string', title: 'Site name', minLength: 2, maxLength: 40 },
    pages: { type: 'integer', minimum: 1, maximum: 20, default: 5 },
    dark: { type: 'boolean', description: 'Dark theme', default: true },
  }, ['name']))

  assert.equal(d.renderable, true)
  assert.equal(d.mode, 'form')
  const byName = Object.fromEntries(d.fields.map((f) => [f.name, f]))
  assert.equal(byName.name.kind, 'string')
  assert.equal(byName.name.title, 'Site name')
  assert.equal(byName.name.required, true)
  assert.equal(byName.pages.kind, 'number')
  assert.equal(byName.pages.integer, true)
  assert.equal(byName.pages.defaultValue, 5)
  assert.equal(byName.pages.required, false)
  assert.equal(byName.dark.kind, 'boolean')
  assert.equal(byName.dark.defaultValue, true)
})

// The protocol allows four ways to express a choice. A renderer that understands one of them shows
// an empty picker for the other three, so all four normalise to {value,label} here.
test('all four enum dialects normalise to the same options', () => {
  const d = describeElicitation(form({
    untitled: { type: 'string', enum: ['a', 'b'] },
    titled: { type: 'string', oneOf: [{ const: 'a', title: 'Alpha' }, { const: 'b', title: 'Beta' }] },
    legacy: { type: 'string', enum: ['a', 'b'], enumNames: ['Alpha', 'Beta'] },
    multi: { type: 'array', items: { anyOf: [{ const: 'a', title: 'Alpha' }] }, default: ['a'] },
  }))

  const byName = Object.fromEntries(d.fields.map((f) => [f.name, f]))
  assert.deepEqual(byName.untitled.options, [{ value: 'a', label: 'a' }, { value: 'b', label: 'b' }])
  assert.deepEqual(byName.titled.options, [{ value: 'a', label: 'Alpha' }, { value: 'b', label: 'Beta' }])
  assert.deepEqual(byName.legacy.options, [{ value: 'a', label: 'Alpha' }, { value: 'b', label: 'Beta' }])
  assert.equal(byName.untitled.kind, 'select')
  assert.equal(byName.multi.kind, 'multiSelect')
  assert.deepEqual(byName.multi.defaultValue, ['a'])
})

// A required field we cannot draw cannot be filled in, so submitting the rest would send the server
// an answer that is wrong rather than incomplete.
test('one unrenderable field refuses the whole form rather than submitting a partial one', () => {
  const d = describeElicitation(form({
    ok: { type: 'string' },
    weird: { type: 'object', properties: {} },
  }))

  assert.equal(d.renderable, false)
  assert.match(d.reason, /weird/)
})

test('a malformed schema is refused, not shown blank', () => {
  assert.equal(describeElicitation({ mode: 'form', requestedSchema: null }).renderable, false)
  assert.equal(describeElicitation({ mode: 'form', requestedSchema: 'nope' }).renderable, false)
})

// An elicitation with no properties is a yes/no question, not an empty form. Refusing it as
// "empty" declines the approval and FAILS the tool call — which is exactly how this was found.
test('a property-less elicitation is a confirmation, not an empty form', () => {
  const d = describeElicitation({
    mode: 'form', serverName: 'elicit-demo',
    message: 'Allow the elicit-demo MCP server to run tool "pick_flavour"?',
    requestedSchema: { type: 'object', properties: {} },
    _meta: { codex_approval_kind: 'mcp_tool_call' },
  })

  assert.equal(d.renderable, true)
  assert.equal(d.mode, 'confirm')
  assert.deepEqual(d.fields, [])
  // The approval marker is surfaced so Full access can answer it the way `never` used to.
  assert.equal(d.approvalKind, 'mcp_tool_call')
})

test("a server's own confirmation carries no approval kind, so it always reaches the user", () => {
  const d = describeElicitation({
    mode: 'form', serverName: 'acme', message: 'Overwrite the file?',
    requestedSchema: { type: 'object', properties: {} },
  })

  assert.equal(d.mode, 'confirm')
  assert.equal(d.approvalKind, null)
})

test('an unknown prompt mode is refused with its name, not silently', () => {
  const d = describeElicitation({ mode: 'hologram', serverName: 'x' })
  assert.equal(d.renderable, false)
  assert.match(d.reason, /hologram/)
})

// A server choosing the URL is a server choosing what the app opens. https only.
test('url mode accepts https and refuses anything else', () => {
  assert.equal(describeElicitation({ mode: 'url', url: 'https://example.com/x' }).renderable, true)
  for (const url of ['file:///etc/passwd', 'http://example.com', 'javascript:alert(1)', 'x-thing://go', '']) {
    assert.equal(describeElicitation({ mode: 'url', url }).renderable, false, url)
  }
})

test('openai/form renders when it is an ordinary object schema and refuses when it is not', () => {
  const ordinary = describeElicitation({
    mode: 'openai/form', serverName: 'sites', message: 'Pick',
    requestedSchema: { type: 'object', properties: { a: { type: 'string' } } },
  })
  assert.equal(ordinary.renderable, true)

  const opaque = describeElicitation({
    mode: 'openai/form', serverName: 'sites', requestedSchema: { widgets: ['carousel'] },
  })
  assert.equal(opaque.renderable, false)
})

test('the server name is sanitised, because it reaches a log line and a dialog', () => {
  const d = describeElicitation({ mode: 'url', url: 'https://x.test',
                                  serverName: 'evil\nINFO: everything is fine' })
  assert.ok(!d.serverName.includes('\n'))
})

// Types matter to the receiving server: a number answered with "3" is a protocol violation.
test('answers are coerced to the types the schema declared', () => {
  const fields = [
    { name: 'title', kind: 'string', required: true },
    { name: 'count', kind: 'number', integer: true },
    { name: 'ratio', kind: 'number', integer: false },
    { name: 'dark', kind: 'boolean' },
    { name: 'tags', kind: 'multiSelect' },
  ]
  const content = buildContent(fields, {
    title: 'Site', count: '7.9', ratio: '0.5', dark: 'true', tags: ['a', 2, 'b'],
  })

  assert.deepEqual(content, {
    title: 'Site', count: 7, ratio: 0.5, dark: true, tags: ['a', 'b'],
  })
})

test('an unanswered optional string is absent, not an empty string', () => {
  const fields = [
    { name: 'optional', kind: 'string', required: false },
    { name: 'mandatory', kind: 'string', required: true },
  ]
  const content = buildContent(fields, { optional: '', mandatory: '' })

  assert.ok(!('optional' in content))
  assert.equal(content.mandatory, '')
})

test('an unparseable number is omitted rather than sent as NaN', () => {
  const content = buildContent([{ name: 'n', kind: 'number' }], { n: 'not a number' })
  assert.deepEqual(content, {})
})

test('decline carries no content, because content would claim the user answered', () => {
  assert.deepEqual(declineReply(), { action: 'decline', content: null, _meta: null })
})

// --- The Claude lane's reply shape (FR-116) -----------------------------------------------------
//
// Elicitation worked under Codex and silently failed under Claude: the SDK declines every request
// when `Options.onElicitation` is absent, so the machinery in this module was wired to exactly one
// provider. Wiring the callback is most of the fix; the rest is that the two providers do not
// accept the same reply.

test('an MCP result drops the nulls Codex tolerates', () => {
  // MCP's ElicitResultSchema types `_meta` as an OPTIONAL OBJECT and `content` as an optional
  // record. The Codex-shaped `{ content: null, _meta: null }` fails that validation rather than
  // reading as absent — after the user has already answered, which is the worst place to fail.
  const mcp = toMCPElicitResult(declineReply())
  assert.deepStrictEqual(mcp, { action: 'decline' })
  assert.ok(!('content' in mcp), 'a null content must be absent, not null')
  assert.ok(!('_meta' in mcp), 'a null _meta must be absent, not null')
})

test('an accepted answer keeps its content', () => {
  assert.deepStrictEqual(
    toMCPElicitResult({ action: 'accept', content: { site: 'blue' }, _meta: null }),
    { action: 'accept', content: { site: 'blue' } },
  )
})

test('cancel is preserved and never collapsed into decline', () => {
  // The server decides whether to retry based on which one it got.
  assert.strictEqual(toMCPElicitResult({ action: 'cancel', content: null }).action, 'cancel')
})

test('an unrecognized action fails closed to decline', () => {
  assert.strictEqual(toMCPElicitResult({ action: 'yes-please' }).action, 'decline')
  assert.strictEqual(toMCPElicitResult(null).action, 'decline')
  assert.strictEqual(toMCPElicitResult({}).action, 'decline')
})

test('a non-object content is dropped rather than sent as-is', () => {
  assert.ok(!('content' in toMCPElicitResult({ action: 'accept', content: 'plain string' })))
  assert.ok(!('content' in toMCPElicitResult({ action: 'accept', content: ['a'] })))
})

test('the SDK request shape is already what describeElicitation reads', () => {
  // No translation layer: the SDK's ElicitationRequest names its fields serverName/message/mode/
  // url/requestedSchema, which is exactly this module's input. That is why the Claude lane needed
  // wiring rather than a port.
  const sdkShaped = {
    serverName: 'sites',
    message: 'Which design?',
    mode: 'form',
    requestedSchema: {
      type: 'object',
      properties: { design: { type: 'string', enum: ['blue', 'green'] } },
      required: ['design'],
    },
  }
  const described = describeElicitation(sdkShaped)
  assert.strictEqual(described.renderable, true)
  assert.strictEqual(described.serverName, 'sites')
  assert.strictEqual(described.fields.length, 1)
  assert.strictEqual(described.fields[0].kind, 'select')
})

test('a url elicitation from the SDK is still held to https', () => {
  assert.strictEqual(
    describeElicitation({ serverName: 's', mode: 'url', url: 'http://plain.example' }).renderable,
    false)
  assert.strictEqual(
    describeElicitation({ serverName: 's', mode: 'url', url: 'https://ok.example' }).renderable,
    true)
})

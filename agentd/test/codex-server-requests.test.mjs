import assert from 'node:assert/strict'
import test from 'node:test'

import { unattendedCodexReply } from '../src/codex-server-requests.mjs'

/// Elicitation is no longer answered here. It used to be auto-declined, which made every
/// elicitation-using MCP server unusable; it now goes to the person (FR-116). Falling through is
/// what routes it there, so this asserts the absence deliberately rather than by omission.
test('an MCP elicitation is NOT answered unattended — it needs a person', () => {
  assert.equal(unattendedCodexReply('mcpServer/elicitation/request'), null)
})

test('permission requests still grant no implicit sandbox expansion', () => {
  assert.deepEqual(
    unattendedCodexReply('item/permissions/requestApproval'),
    { permissions: {}, scope: 'turn' })
})

/// Anything needing a real decision must fall through so the caller can route or refuse it —
/// returning a reply here would silently answer for the user.
test('methods that need real handling are not answered here', () => {
  for (const method of [
    'item/tool/call',
    'item/commandExecution/requestApproval',
    'item/fileChange/requestApproval',
    'mcpServer/elicitation/request',
    'somethingNew/inAFutureCodex',
  ]) {
    assert.equal(unattendedCodexReply(method), null, method)
  }
})

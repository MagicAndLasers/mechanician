import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  MCP_BOUNDARY_APPEND,
  mcpConnectionsAppend,
} from '../src/mcp-agent-guidance.mjs'

test('MCP guidance treats the callable inventory as truth and prefers direct lookup tools', () => {
  const guidance = `${MCP_BOUNDARY_APPEND}\n${mcpConnectionsAppend([{
    name: 'VICE',
    status: 'connected',
    tools: 4,
  }])}`

  assert.match(guidance, /callable tool list/i)
  assert.match(guidance, /call it directly|direct mcp__/i)
  assert.match(guidance, /do not spawn a subagent/i)
  assert.match(guidance, /prefer search excerpts or a section-scoped fetch/i)
  assert.match(guidance, /VICE=connected:4-tools/)
  assert.doesNotMatch(guidance, /\bToolSearch\b/)
  assert.doesNotMatch(guidance, /tools are deferred/i)
})

test('MCP guidance makes discovery conditional and preserves truthful readiness states', () => {
  const guidance = mcpConnectionsAppend([
    { name: 'needs auth', status: 'needs-auth' },
    { name: 'failed/server', status: 'failed' },
    { name: 'forged\nname', status: 'invented', tools: 999 },
  ])

  assert.match(guidance, /discovery primitive.*present in the callable tool list/i)
  assert.match(guidance, /needs-auth/)
  assert.match(guidance, /needs-auth=needs-auth/)
  assert.match(guidance, /failed-server=failed/)
  assert.match(guidance, /forged-name=unverified/)
  assert.doesNotMatch(guidance, /999-tools/)
})

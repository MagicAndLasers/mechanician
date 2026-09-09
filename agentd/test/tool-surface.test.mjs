import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  TOOL_SURFACE_ADAPTER_REVISION,
  TOOL_SURFACE_COVERAGE,
  TOOL_SURFACE_MAX_NAME_BYTES,
  TOOL_SURFACE_MAX_TOOLS,
  toolSurfaceEvent,
} from '../src/tool-surface.mjs'

const base = {
  id: 'turn-1',
  lane: 'openai',
  toolProfile: 'standard',
  permissionMode: 'default',
  coverage: TOOL_SURFACE_COVERAGE.complete,
  provenance: 'mechanician-api-request',
}

test('tool surface is turn scoped, deterministic, and preserves raw names', () => {
  const event = toolSurfaceEvent({
    ...base,
    tools: [
      { name: 'Bash' },
      { name: 'mcp__github__create_pull_request' },
      { name: 'Bash' },
    ],
  })
  assert.deepEqual(event, {
    type: 'tool_surface',
    id: 'turn-1',
    lane: 'openai',
    toolProfile: 'standard',
    permissionMode: 'default',
    coverage: 'complete',
    provenance: 'mechanician-api-request',
    adapterRevision: TOOL_SURFACE_ADAPTER_REVISION,
    tools: ['Bash', 'mcp__github__create_pull_request'],
  })
})

test('Codex can state only the Mechanician-supplied portion of its surface', () => {
  const event = toolSurfaceEvent({
    ...base,
    lane: 'codex',
    coverage: TOOL_SURFACE_COVERAGE.mechanicianSupplied,
    provenance: 'mechanician-codex-thread',
    toolProfile: 'help-expert',
    permissionMode: 'plan',
    tools: [{ name: 'SearchMechanicianHelp' }],
  })
  assert.equal(event.coverage, 'mechanician-supplied')
  assert.deepEqual(event.tools, ['SearchMechanicianHelp'])
})

test('malformed identity and unsupported enum values fail closed', () => {
  for (const override of [
    { id: '' },
    { lane: 'other' },
    { toolProfile: 'future-profile' },
    { permissionMode: 'trust-me' },
    { coverage: 'probably-complete' },
    { provenance: 'unknown' },
  ]) {
    assert.equal(toolSurfaceEvent({ ...base, ...override, tools: ['Read'] }), null)
  }
})

test('an explicit empty surface differs from missing or malformed evidence', () => {
  assert.deepEqual(toolSurfaceEvent({ ...base, tools: [] })?.tools, [])
  assert.equal(toolSurfaceEvent({ ...base, tools: null }), null)
  assert.equal(toolSurfaceEvent({ ...base, tools: [''] }), null)
  assert.equal(toolSurfaceEvent({ ...base, tools: [' Read '] }), null)
  assert.equal(toolSurfaceEvent({ ...base, tools: ['Read\nWrite'] }), null)
  assert.equal(toolSurfaceEvent({
    ...base,
    tools: ['x'.repeat(TOOL_SURFACE_MAX_NAME_BYTES + 1)],
  }), null)
})

test('tool count and serialized event bytes are bounded without truncation', () => {
  assert.equal(toolSurfaceEvent({
    ...base,
    tools: Array.from({ length: TOOL_SURFACE_MAX_TOOLS + 1 }, (_, i) => `tool-${i}`),
  }), null)
  assert.equal(toolSurfaceEvent({
    ...base,
    tools: Array.from(
      { length: TOOL_SURFACE_MAX_TOOLS },
      (_, i) => `${String(i).padStart(4, '0')}-${'x'.repeat(500)}`,
    ),
  }), null)
})

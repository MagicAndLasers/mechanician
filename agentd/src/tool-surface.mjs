// One bounded, turn-scoped description of the callable tool names actually presented to a
// provider. This is advisory product evidence, never authorization: the ordinary approval,
// sandbox, TCC, and tool-execution gates remain authoritative for every invocation.

export const TOOL_SURFACE_ADAPTER_REVISION = 'mechanician-tool-surface-v1'

export const TOOL_SURFACE_COVERAGE = Object.freeze({
  complete: 'complete',
  mechanicianSupplied: 'mechanician-supplied',
})

const LANES = new Set(['claude', 'openai', 'codex'])
const PROFILES = new Set(['standard', 'help-expert'])
const PERMISSION_MODES = new Set(['default', 'acceptEdits', 'plan', 'bypassPermissions'])
const PROVENANCE = new Set([
  'provider-init',
  'mechanician-api-request',
  'mechanician-codex-thread',
])
const COVERAGE = new Set(Object.values(TOOL_SURFACE_COVERAGE))

export const TOOL_SURFACE_MAX_TOOLS = 512
export const TOOL_SURFACE_MAX_NAME_BYTES = 512
export const TOOL_SURFACE_MAX_EVENT_BYTES = 64 * 1024

function toolName(value) {
  const candidate = typeof value === 'string' ? value : value?.name
  if (typeof candidate !== 'string') return null
  // Preserve the provider's exact identifier. Trimming here would let a malformed name such as
  // ` Read ` acquire the authority of the app-owned `Read` alias during Swift projection.
  if (!candidate || candidate !== candidate.trim() || /[\u0000-\u001F\u007F]/u.test(candidate)
      || Buffer.byteLength(candidate, 'utf8') > TOOL_SURFACE_MAX_NAME_BYTES) return null
  return candidate
}

/**
 * Construct the only accepted `tool_surface` wire shape. Invalid or oversized evidence returns
 * null rather than publishing a partial list that could be mistaken for a complete capability
 * boundary.
 */
export function toolSurfaceEvent({
  id,
  lane,
  toolProfile,
  permissionMode = 'default',
  tools,
  coverage,
  provenance,
}) {
  if (typeof id !== 'string' || !id || !LANES.has(lane)
      || !PROFILES.has(toolProfile) || !PERMISSION_MODES.has(permissionMode)
      || !COVERAGE.has(coverage) || !PROVENANCE.has(provenance)
      || !Array.isArray(tools) || tools.length > TOOL_SURFACE_MAX_TOOLS) return null

  const names = []
  for (const value of tools) {
    const name = toolName(value)
    if (!name) return null
    names.push(name)
  }
  const unique = [...new Set(names)].sort()
  const event = {
    type: 'tool_surface',
    id,
    lane,
    toolProfile,
    permissionMode,
    coverage,
    provenance,
    adapterRevision: TOOL_SURFACE_ADAPTER_REVISION,
    tools: unique,
  }
  if (Buffer.byteLength(JSON.stringify(event), 'utf8') > TOOL_SURFACE_MAX_EVENT_BYTES) return null
  return event
}

// Write Mechanician's MCP servers into the Codex config file without owning that file.
//
// `$CODEX_HOME/config.toml` is app-owned (agentd forces CODEX_HOME to a directory under our support
// dir) but it is not OURS: Codex itself appends `[projects."…"] trust_level` entries and stores
// other settings there, and clobbering it is a proven data-loss path. There is no TOML dependency
// in agentd, and hand-parsing someone else's TOML to merge into it is a worse risk than the problem
// it solves — so we rewrite exactly one delimited region and leave every other byte untouched.
//
// The region is idempotent: rewriting it with the same servers produces an identical file, so a
// no-op reload does not churn the file that Codex watches.

export const BLOCK_BEGIN = '# >>> mechanician managed MCP servers — do not edit >>>'
export const BLOCK_END = '# <<< mechanician managed MCP servers <<<'

function tomlString(value) {
  // TOML basic strings accept JSON's escapes for quote, backslash, and every ASCII control except
  // slash (which JSON does not escape in modern runtimes). JSON.stringify therefore avoids raw CR,
  // tab, NUL, and registry-supplied controls making the complete shared config unparsable.
  return JSON.stringify(String(value))
}

/// TOML bare keys are `[A-Za-z0-9_-]+`; anything else has to be quoted. Server names and header
/// names both reach this, and a header like `X-Client` is legal bare while `Content Type` is not.
function tomlKey(key) {
  return /^[A-Za-z0-9_-]+$/.test(key) ? key : tomlString(key)
}

function tomlValue(value) {
  if (Array.isArray(value)) return `[${value.map(tomlValue).join(', ')}]`
  if (value && typeof value === 'object') {
    const inner = Object.entries(value)
      .map(([k, v]) => `${tomlKey(k)} = ${tomlValue(v)}`)
      .join(', ')
    return `{ ${inner} }`
  }
  if (typeof value === 'boolean' || typeof value === 'number') return String(value)
  return tomlString(value)
}

/**
 * Render the managed region. `exclusions` are the credential variables that must not leak into the
 * environment Codex gives the shell commands it runs for the model.
 */
export function renderManagedCodexConfig(servers, { exclusions = [] } = {}) {
  const lines = [BLOCK_BEGIN]
  if (exclusions.length) {
    lines.push(
      '',
      '# Credentials are handed to the app-server as environment variables so they never sit in',
      '# this file. Exclude them again here or every command the model runs would inherit them.',
      '[shell_environment_policy]',
      `exclude = ${tomlValue(exclusions)}`,
    )
  }
  for (const name of Object.keys(servers).sort()) {
    const table = servers[name]
    lines.push('', `[mcp_servers.${tomlKey(name)}]`)
    for (const [key, value] of Object.entries(table)) {
      if (value === undefined || value === null) continue
      lines.push(`${tomlKey(key)} = ${tomlValue(value)}`)
    }
  }
  lines.push(BLOCK_END)
  return lines.join('\n')
}

/// Read the exclusion names from our existing managed region. Every Mechanician window owns a
/// separate App Server process but shares this config file, so a writer must preserve exclusions
/// installed by an older sibling generation it cannot prove has exited. The renderer emits a
/// single-line JSON-compatible string array; a malformed hand-edited value is ignored here but the
/// caller can still add every name known by its own old/new process generations.
export function managedCodexExclusions(existing) {
  const text = String(existing ?? '')
  const start = text.indexOf(BLOCK_BEGIN)
  if (start === -1) return []
  const end = text.indexOf(BLOCK_END, start)
  const region = text.slice(start, end === -1 ? text.length : end)
  const policy = region.match(/(?:^|\n)\s*\[shell_environment_policy\]\s*\r?\n([\s\S]*?)(?=\r?\n\s*\[|$)/)
  const encoded = policy?.[1]?.match(/(?:^|\n)\s*exclude\s*=\s*(\[[^\r\n]*\])/)?.[1]
  if (!policy) return []
  if (!encoded) {
    throw new Error('Mechanician’s managed Codex shell exclusion policy is malformed.')
  }
  try {
    const parsed = JSON.parse(encoded)
    if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== 'string' || !item)) {
      throw new Error('invalid exclusion array')
    }
    return [...new Set(parsed)].sort()
  } catch {
    throw new Error('Mechanician’s managed Codex shell exclusion policy is malformed.')
  }
}

function withoutTomlComment(line) {
  let quote = null
  let escaped = false
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index]
    if (quote === '"') {
      if (escaped) escaped = false
      else if (character === '\\') escaped = true
      else if (character === '"') quote = null
      continue
    }
    if (quote === "'") {
      if (character === "'") quote = null
      continue
    }
    if (character === '"' || character === "'") quote = character
    else if (character === '#') return line.slice(0, index)
  }
  return line
}

function parseTomlKeyPath(source) {
  const text = String(source ?? '')
  const keys = []
  let index = 0
  const whitespace = () => { while (/\s/.test(text[index] || '')) index += 1 }
  while (true) {
    whitespace()
    let key = ''
    if (text[index] === '"') {
      const start = index
      index += 1
      let escaped = false
      while (index < text.length) {
        const character = text[index++]
        if (escaped) escaped = false
        else if (character === '\\') escaped = true
        else if (character === '"') break
      }
      if (text[index - 1] !== '"') throw new Error('Unterminated TOML key string.')
      try { key = JSON.parse(text.slice(start, index)) }
      catch { throw new Error('Unsupported TOML key escape.') }
    } else if (text[index] === "'") {
      index += 1
      const end = text.indexOf("'", index)
      if (end < 0) throw new Error('Unterminated TOML literal key.')
      key = text.slice(index, end)
      index = end + 1
    } else {
      const match = text.slice(index).match(/^[A-Za-z0-9_-]+/)
      if (!match) throw new Error('Invalid TOML key.')
      key = match[0]
      index += key.length
    }
    if (!key) throw new Error('Empty TOML key.')
    keys.push(key)
    whitespace()
    if (index === text.length) return keys
    if (text[index] !== '.') throw new Error('Invalid TOML dotted key.')
    index += 1
  }
}

function findUnquoted(text, target, start = 0) {
  let quote = null
  let escaped = false
  for (let index = start; index < text.length; index += 1) {
    const character = text[index]
    if (quote === '"') {
      if (escaped) escaped = false
      else if (character === '\\') escaped = true
      else if (character === '"') quote = null
      continue
    }
    if (quote === "'") {
      if (character === "'") quote = null
      continue
    }
    if (character === '"' || character === "'") quote = character
    else if (character === target) return index
  }
  return -1
}

/// Targeted TOML lexical scan for semantic key collisions. This is deliberately not a value
/// parser: only table headers and assignment keys can define the two namespaces Mechanician adds.
/// Quoted/literal/dotted keys and trailing comments are decoded so alternate valid spellings cannot
/// evade collision detection and leave Codex with duplicate semantic tables.
function tomlDefinitions(existing, { includeManagedRegion = false } = {}) {
  const definitions = []
  let table = []
  const source = includeManagedRegion
    ? String(existing ?? '')
    : stripManagedRegion(String(existing ?? ''))
  for (const rawLine of source.split(/\r?\n/)) {
    const line = withoutTomlComment(rawLine).trim()
    if (!line) continue
    if (line.startsWith('[')) {
      const array = line.startsWith('[[')
      const openLength = array ? 2 : 1
      const close = array ? ']]' : ']'
      let closeIndex = -1
      for (let cursor = openLength; cursor < line.length; cursor += 1) {
        if (line.startsWith(close, cursor) && findUnquoted(line, ']', openLength) === cursor) {
          closeIndex = cursor
          break
        }
      }
      if (closeIndex < 0 || line.slice(closeIndex + close.length).trim()) {
        throw new Error('Codex config contains an unsupported TOML table header.')
      }
      table = parseTomlKeyPath(line.slice(openLength, closeIndex).trim())
      definitions.push({ kind: array ? 'arrayTable' : 'table', path: table })
      continue
    }
    const equals = findUnquoted(line, '=')
    if (equals < 0) continue
    const key = parseTomlKeyPath(line.slice(0, equals).trim())
    definitions.push({ kind: 'assignment', path: [...table, ...key] })
  }
  return definitions
}

/// A second TOML table with this name invalidates the entire Codex config. We never rewrite a
/// user/Codex-owned table without a TOML parser, so callers must fail safely instead of adding our
/// managed policy alongside it.
export function hasForeignShellEnvironmentPolicy(existing) {
  return tomlDefinitions(existing).some((definition) =>
    definition.path[0] === 'shell_environment_policy')
}

/// Server names already declared OUTSIDE our region. TOML rejects a duplicate table, so ours must
/// stand aside rather than produce a config file Codex refuses to load in its entirety.
export function foreignServerNames(existing) {
  const names = new Set()
  for (const definition of tomlDefinitions(existing)) {
    if (definition.path[0] !== 'mcp_servers') continue
    if (definition.path.length >= 2) names.add(definition.path[1])
    else if (definition.kind === 'assignment') {
      throw new Error('Codex config defines mcp_servers as a value and cannot be merged safely.')
    }
  }
  return names
}

/// Every MCP name Codex can read from the complete shared file, including Mechanician's managed
/// region. Restricted per-thread profiles must disable this set rather than the current process's
/// extension snapshot: another window or an older generation may own a still-live managed entry.
export function configuredServerNames(existing) {
  const names = new Set()
  for (const definition of tomlDefinitions(existing, { includeManagedRegion: true })) {
    if (definition.path[0] !== 'mcp_servers') continue
    if (definition.path.length >= 2) names.add(definition.path[1])
    else if (definition.kind === 'assignment') {
      throw new Error('Codex config defines mcp_servers as a value and cannot be read safely.')
    }
  }
  return names
}

function stripManagedRegion(text) {
  const start = text.indexOf(BLOCK_BEGIN)
  if (start === -1) return text
  const end = text.indexOf(BLOCK_END, start)
  if (end === -1) return text.slice(0, start)
  return text.slice(0, start) + text.slice(end + BLOCK_END.length)
}

/**
 * Replace (or append) the managed region in `existing`. Returns the full file text.
 */
export function mergeManagedCodexConfig(existing, block) {
  const text = existing ?? ''
  const start = text.indexOf(BLOCK_BEGIN)
  if (start !== -1) {
    const end = text.indexOf(BLOCK_END, start)
    if (end !== -1) {
      return `${text.slice(0, start)}${block}${text.slice(end + BLOCK_END.length)}`
    }
    // A truncated region (interrupted write, hand-edit) is replaced wholesale rather than nested.
    return `${text.slice(0, start)}${block}\n`
  }
  const prefix = text.length === 0 ? '' : text.endsWith('\n') ? `${text}\n` : `${text}\n\n`
  return `${prefix}${block}\n`
}

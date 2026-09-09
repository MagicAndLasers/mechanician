import fs from 'node:fs'
import path from 'node:path'

const MAX_SKILL_BYTES = 128 * 1024
const MAX_DESCRIPTION_CHARACTERS = 1_000
const SAFE_SKILL_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const SAFE_REPORTED_SKILL_NAME = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/
const SKILLS_LIST_TIMEOUT_MS = 30_000

function scalar(value) {
  const trimmed = String(value || '').trim()
  if (!trimmed) return ''
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try { return JSON.parse(trimmed) } catch {}
  }
  if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.slice(1, -1).replaceAll("''", "'")
  }
  return trimmed
}

function frontmatter(text) {
  const lines = String(text || '').replaceAll('\r\n', '\n').split('\n')
  if (lines[0]?.trim() !== '---') return {}
  const end = lines.slice(1).findIndex((line) => line.trim() === '---')
  if (end < 0) return {}
  const fields = {}
  for (const line of lines.slice(1, end + 1)) {
    const match = /^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$/.exec(line)
    if (match && !Object.hasOwn(fields, match[1])) fields[match[1]] = scalar(match[2])
  }
  return fields
}

function regularSkillFile(directory) {
  const file = path.join(directory, 'SKILL.md')
  try {
    const stat = fs.lstatSync(file)
    return stat.isFile() && !stat.isSymbolicLink() && stat.size > 0
      && stat.size <= MAX_SKILL_BYTES ? file : null
  } catch {
    return null
  }
}

function childDirectories(directory) {
  try {
    return fs.readdirSync(directory, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && !entry.isSymbolicLink())
      .map((entry) => path.join(directory, entry.name))
  } catch {
    return []
  }
}

function skillDirectories(skillsRoot) {
  const ordinary = childDirectories(skillsRoot).filter(
    (directory) => path.basename(directory) !== '.system')
  const system = childDirectories(path.join(skillsRoot, '.system'))
  // User-installed skills win a duplicate name, matching Codex's normal override semantics.
  return [...system, ...ordinary]
}

/**
 * Startup placeholder used before App Server can answer its authoritative skills/list request.
 * Read only bounded SKILL.md frontmatter under $CODEX_HOME/skills; repository and plugin skills
 * arrive in the provider-owned inventory once initialization completes.
 */
export function discoverCodexSkills(codexHome) {
  const byName = new Map()
  for (const directory of skillDirectories(path.join(codexHome, 'skills'))) {
    const file = regularSkillFile(directory)
    if (!file) continue
    try {
      const fields = frontmatter(fs.readFileSync(file, 'utf8'))
      const name = fields.name || path.basename(directory)
      if (!SAFE_SKILL_NAME.test(name)) continue
      byName.set(name, {
        name,
        description: String(fields.description || '').slice(0, MAX_DESCRIPTION_CHARACTERS),
        argumentHint: '',
        invocationPrefix: '$',
      })
    } catch {
      // A malformed optional skill must not make the provider lane unavailable.
    }
  }
  return [...byName.values()].sort(
    (left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: 'base' }))
}

/**
 * Convert App Server's cwd-scoped inventory into the provider-neutral command shape the app uses.
 *
 * `skills/list` is authoritative for every source Codex actually enables: system and user skills,
 * repository `.agents/skills`, and namespaced skills supplied by enabled plugins. The older local
 * scanner above remains only as a startup placeholder before the provider is ready.
 */
export function codexCommandsFromSkillsList(result, requestedCwd) {
  const data = Array.isArray(result?.data) ? result.data : []
  const row = data.find((entry) => entry?.cwd === requestedCwd)
    || (data.length === 1 ? data[0] : null)
  if (!row || !Array.isArray(row.skills)) {
    throw new Error(`Codex skills/list returned no inventory for ${requestedCwd}.`)
  }

  const byName = new Map()
  for (const skill of row.skills) {
    const name = typeof skill?.name === 'string' ? skill.name.trim() : ''
    if (skill?.enabled === false || !SAFE_REPORTED_SKILL_NAME.test(name)) continue
    // The composer invokes a skill by name, so two same-name rows cannot be represented honestly.
    // Keep App Server's first (highest-precedence) row instead of rendering duplicate SwiftUI ids.
    if (byName.has(name)) continue
    const description = typeof skill.description === 'string'
      ? skill.description
      : (typeof skill.interface?.shortDescription === 'string'
          ? skill.interface.shortDescription
          : '')
    byName.set(name, {
      name,
      description: description.slice(0, MAX_DESCRIPTION_CHARACTERS),
      argumentHint: '',
      invocationPrefix: '$',
    })
  }

  return {
    commands: [...byName.values()].sort(
      (left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: 'base' })),
    errors: Array.isArray(row.errors) ? row.errors : [],
    cwd: typeof row.cwd === 'string' && row.cwd ? row.cwd : requestedCwd,
  }
}

export async function requestCodexSkills(
  app,
  { cwd, forceReload = true, timeoutMs = SKILLS_LIST_TIMEOUT_MS } = {},
) {
  if (!app || typeof app.request !== 'function') {
    throw new Error('Codex App Server is not running.')
  }
  if (typeof cwd !== 'string' || !cwd) {
    throw new Error('Codex skills/list requires a working directory.')
  }
  const result = await app.request('skills/list', {
    cwds: [cwd],
    forceReload,
  }, timeoutMs)
  return codexCommandsFromSkillsList(result, cwd)
}

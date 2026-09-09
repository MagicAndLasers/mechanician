import fs from 'node:fs'
import path from 'node:path'

const IGNORED_DIRECTORIES = new Set([
  '.git', '.build', '.swiftpm', 'DerivedData', 'node_modules', 'build',
])

let atomicWriteCounter = 0

// Replace a text file atomically from a temporary sibling. The sibling keeps
// rename on the same filesystem; fsync closes the crash window before publish.
export function atomicWriteText(filePath, content) {
  let destination = path.resolve(filePath)
  try {
    if (fs.lstatSync(destination).isSymbolicLink()) destination = fs.realpathSync(destination)
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
  const parent = path.dirname(destination)
  fs.mkdirSync(parent, { recursive: true })
  let mode = 0o644
  try { mode = fs.statSync(destination).mode & 0o777 }
  catch (error) { if (error?.code !== 'ENOENT') throw error }
  const temporary = path.join(
    parent,
    `.${path.basename(destination)}.${process.pid}.${++atomicWriteCounter}.tmp`,
  )
  let descriptor = null
  try {
    descriptor = fs.openSync(temporary, 'wx', mode)
    fs.writeFileSync(descriptor, String(content), 'utf8')
    fs.fsyncSync(descriptor)
    fs.closeSync(descriptor)
    descriptor = null
    fs.renameSync(temporary, destination)
    // Directory fsync makes the rename itself durable where the platform permits it.
    try {
      const directory = fs.openSync(parent, 'r')
      try { fs.fsyncSync(directory) } finally { fs.closeSync(directory) }
    } catch {}
  } catch (error) {
    if (descriptor !== null) try { fs.closeSync(descriptor) } catch {}
    try { fs.unlinkSync(temporary) } catch {}
    throw error
  }
}

// Responses requests use store:false, so every follow-up must carry the complete
// local conversation: prior input, the model's output (including reasoning/tool
// calls), and the corresponding function results.
export function continueResponsesInput(input, outputItems, toolOutputs) {
  return [
    ...(Array.isArray(input) ? input : []),
    ...(Array.isArray(outputItems) ? outputItems : []),
    ...(Array.isArray(toolOutputs) ? toolOutputs : []),
  ]
}

// The app sends its canonical dialog history and the exact provider-bound current prompt
// separately. The latter may contain app-owned memory/media expansion that is deliberately absent
// from the persisted user row, so it must replace the final user turn rather than being ignored
// whenever history is non-empty.
export function openAIHistory(history, prompt) {
  const currentPrompt = typeof prompt === 'string' ? prompt : ''
  const turns = Array.isArray(history)
    ? history
      .filter((entry) => entry
        && (entry.role === 'user' || entry.role === 'assistant')
        && typeof entry.text === 'string')
      .map((entry) => ({
        role: entry.role,
        content: [{ type: 'input_text', text: entry.text }],
      }))
    : []
  if (!turns.length) {
    return [{ role: 'user', content: [{ type: 'input_text', text: currentPrompt }] }]
  }
  if (turns.at(-1)?.role === 'user') {
    turns[turns.length - 1] = {
      role: 'user',
      content: [{ type: 'input_text', text: currentPrompt }],
    }
  } else {
    turns.push({ role: 'user', content: [{ type: 'input_text', text: currentPrompt }] })
  }
  return turns
}

function globExpression(pattern) {
  if (typeof pattern !== 'string' || !pattern.length) return null
  if (pattern.length > 256) throw new Error('Search glob is too long.')
  let source = ''
  for (let i = 0; i < pattern.length; i += 1) {
    const character = pattern[i]
    if (character === '*') {
      if (pattern[i + 1] === '*') { source += '.*'; i += 1 }
      else source += '[^/]*'
    } else if (character === '?') source += '[^/]'
    else source += character.replace(/[|\\{}()[\]^$+?.]/g, '\\$&')
  }
  return new RegExp(`^${source}$`)
}

function matchesGlob(relativePath, expression, pattern) {
  if (!expression) return true
  const normalized = relativePath.split(path.sep).join('/')
  return expression.test(pattern.includes('/') ? normalized : path.posix.basename(normalized))
}

function candidateFiles(target, root, glob, limits) {
  const files = []
  let visited = 0
  const visit = (candidate) => {
    if (visited >= limits.maxFiles) return
    visited += 1
    let stat
    try { stat = fs.lstatSync(candidate) } catch { return }
    // Never follow workspace symlinks: openAIProjectPath validates the selected
    // target, but a descendant symlink could otherwise escape after that check.
    if (stat.isSymbolicLink()) return
    if (stat.isFile()) {
      const relative = path.relative(root, candidate) || path.basename(candidate)
      if (matchesGlob(relative, glob.expression, glob.pattern)) files.push({ path: candidate, relative, stat })
      return
    }
    if (!stat.isDirectory()) return
    let entries
    try { entries = fs.readdirSync(candidate, { withFileTypes: true }) } catch { return }
    entries.sort((a, b) => a.name.localeCompare(b.name))
    for (const entry of entries) {
      if (visited >= limits.maxFiles) break
      if (entry.name.startsWith('.') || IGNORED_DIRECTORIES.has(entry.name)) continue
      visit(path.join(candidate, entry.name))
    }
  }
  visit(target)
  return { files, visited, fileLimitReached: visited >= limits.maxFiles }
}

// A dependency-free, deliberately literal search. Literal matching avoids an
// untrusted regular expression blocking agentd through catastrophic backtracking.
// Work is bounded by file count, individual size, total bytes, and match count.
export function searchProjectText({
  root,
  target,
  query,
  glob = '',
  maxMatches = 100,
  maxFiles = 5_000,
  maxFileBytes = 2 * 1024 * 1024,
  maxTotalBytes = 32 * 1024 * 1024,
} = {}) {
  if (typeof query !== 'string' || !query.length) throw new Error('Search query must not be empty.')
  if (query.length > 4_096) throw new Error('Search query is too long.')
  const projectRoot = path.resolve(root)
  const searchTarget = path.resolve(target)
  const pattern = typeof glob === 'string' ? glob : ''
  const expression = globExpression(pattern)
  const limits = { maxFiles, maxFileBytes, maxTotalBytes }
  const candidates = candidateFiles(searchTarget, projectRoot, { pattern, expression }, limits)
  const results = []
  let bytesRead = 0
  let truncated = candidates.fileLimitReached

  for (const file of candidates.files) {
    if (results.length >= maxMatches) { truncated = true; break }
    if (file.stat.size > maxFileBytes) continue
    if (bytesRead + file.stat.size > maxTotalBytes) { truncated = true; break }
    let buffer
    try { buffer = fs.readFileSync(file.path) } catch { continue }
    bytesRead += buffer.length
    if (buffer.includes(0)) continue
    const lines = buffer.toString('utf8').split(/\r?\n/)
    for (let index = 0; index < lines.length; index += 1) {
      if (!lines[index].includes(query)) continue
      results.push(`${file.relative}:${index + 1}:${lines[index]}`)
      if (results.length >= maxMatches) { truncated = true; break }
    }
  }

  return {
    text: results.length ? results.join('\n') : '(no matches)',
    matches: results.length,
    filesVisited: candidates.visited,
    bytesRead,
    truncated,
  }
}

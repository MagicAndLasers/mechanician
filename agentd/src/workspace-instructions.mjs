// Provider-neutral workspace-instruction resolution for the headless scheduler.
//
// Interactive turns receive an immutable snapshot from Swift. ambientd can outlive the app, so it
// resolves app-owned state immediately before each scheduled run instead.
//
// Where that state lives depends on which library is authoritative. On a legacy library it is the
// `workspaces/` and `home-workspace.json` files this module has always read. Once SQLite owns the
// library those files are frozen at the cutover, and this daemon cannot open `library.db` — so the
// app writes `workspaces.json` beside `tasks.json` in the projection directory, on the same
// contract: disposable, written only after the authoritative commit, and preferred here when it
// exists. Without it a Workspace created after the cutover resolved to nothing and its task ran
// from the user's home directory.

import fs from 'node:fs'
import path from 'node:path'

const CLAUDE_ACCESSES = new Set([
  'anthropic_api',
  'claude_subscription',
  'claude_vertex',
  'claude_bedrock',
])

// Keep these fixed identities in sync with ReservedWorkspace.swift. Help is an interactive product
// surface with a closed foreground profile, never an unattended workspace.
//
// `3e3b9c4a-6a1e-4e9c-9c51-7b1d2a5f0e44` was the Memory workspace and is deliberately ABSENT. That
// row survives on existing installs as an ordinary Workspace, so a scheduled task pointing at it
// must run rather than be held for a repair that no longer has anything to repair.
const RESERVED_WORKSPACE_IDS = new Set([
  'd353f793-fc8a-497c-bf64-bd396ef2f367',
])

export function isReservedWorkspaceID(value) {
  return typeof value === 'string' && RESERVED_WORKSPACE_IDS.has(value.toLowerCase())
}

function trimmed(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return null
  }
}

export function readBoundedRootInstructions(
  cwd,
  filename = 'CLAUDE.md',
  maximumBytes = 256 * 1024,
) {
  const root = trimmed(cwd)
  if (!root) return null
  const file = path.join(root, filename)
  try {
    const stat = fs.lstatSync(file)
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > maximumBytes) return null
    const bytes = fs.readFileSync(file)
    if (bytes.length > maximumBytes || bytes.includes(0)) return null
    return trimmed(bytes.toString('utf8'))
  } catch {
    return null
  }
}

/// Resolve Home, a real Project, or a dangling workspace id without ever falling through between
/// them. The return value is safe to log except for `appText`, which is user-authored content.
export function readWorkspaceInstructionContext({
  supportDirectory,
  projectionDirectory = null,
  workspaceID = null,
  maximumBytes = 256 * 1024,
}) {
  // Absent unless SQLite owns the library, so a legacy install keeps reading its own files.
  const projection = projectionDirectory
    ? readJSON(path.join(projectionDirectory, 'workspaces.json'))
    : null

  if (!workspaceID) {
    const home = projection
      ? projection.home
      : readJSON(path.join(supportDirectory, 'home-workspace.json'))
    return {
      target: 'home',
      cwd: null,
      appText: trimmed(home?.instructions),
      claudeRepositoryText: null,
    }
  }

  const id = typeof workspaceID === 'string'
    && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i
      .test(workspaceID)
    ? workspaceID
    : null
  if (!id) {
    return {
      target: `unresolved:${String(workspaceID)}`,
      cwd: null,
      appText: null,
      claudeRepositoryText: null,
    }
  }
  if (isReservedWorkspaceID(id)) {
    return {
      target: `unresolved:${id}`,
      cwd: null,
      appText: null,
      claudeRepositoryText: null,
    }
  }
  // The projection is the whole live Workspace set, so its absence of an id is authoritative: no
  // falling back to a frozen file that would answer with the workspace as it stood at the cutover.
  const project = projection
    ? (Array.isArray(projection.workspaces)
      ? projection.workspaces.find(candidate =>
        typeof candidate?.id === 'string'
          && candidate.id.toLowerCase() === id.toLowerCase())
      : null)
    // `workspaces/` is canonical. The legacy fallback covers the short rolling-upgrade window before
    // the app atomically renames the old directory and installs `projects -> workspaces` for an
    // already-running previous daemon; it never overrides a canonical record.
    : (readJSON(path.join(
      supportDirectory, 'workspaces', `${id}.json`,
    )) || readJSON(path.join(
      supportDirectory, 'projects', `${id}.json`,
    )))
  if (!project
      || typeof project.id !== 'string'
      || project.id.toLowerCase() !== id.toLowerCase()) {
    return {
      target: `unresolved:${id}`,
      cwd: null,
      appText: null,
      claudeRepositoryText: null,
    }
  }
  const cwd = trimmed(project.cwd)
  return {
    target: `project:${id}`,
    cwd,
    appText: trimmed(project.instructions),
    claudeRepositoryText: cwd
      ? readBoundedRootInstructions(cwd, 'CLAUDE.md', maximumBytes)
      : null,
  }
}

export function effectiveWorkspaceInstructions(context, access) {
  if (!context) return null
  if (!CLAUDE_ACCESSES.has(access)) return context.appText || null
  const sections = [
    context.claudeRepositoryText
      ? `Repository instructions (CLAUDE.md):\n${context.claudeRepositoryText}`
      : null,
    context.appText
      ? `Workspace Instructions (Mechanician):\n${context.appText}`
      : null,
  ].filter(Boolean)
  return sections.length ? sections.join('\n\n') : null
}

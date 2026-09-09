// Pure-JS git reader (isomorphic-git) used ONLY when the git CLI is unavailable — i.e. a user
// without Apple's Command Line Tools installed. It lets the Changes panel show status and diffs
// with zero install, producing the SAME shapes the CLI path emits (see parsePorcelainV1Z /
// handleGit in agentd.mjs). Write ops (stage/commit/push) and the agent's own git stay on the CLI.
//
// Limitations vs the CLI (acceptable for the no-tools fallback): no rename detection (a rename
// reads as delete + add), and ahead/behind default to 0 (no upstream comparison).

import fs from 'node:fs'
import path from 'node:path'
import git from 'isomorphic-git'
import { createTwoFilesPatch } from 'diff'

/// Walk up from `startDir` to the nearest directory containing `.git` (dir for a normal repo,
/// file for a worktree/submodule). Returns the repo root, or null if none.
export function findRepoRoot(startDir) {
  let dir = path.resolve(startDir)
  for (let i = 0; i < 64; i++) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir
    const parent = path.dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return null
}

/// Map an isomorphic-git statusMatrix row [HEAD, WORKDIR, STAGE] to porcelain (x, y).
///   HEAD:    0 absent, 1 present
///   WORKDIR: 0 absent, 1 == HEAD, 2 != HEAD
///   STAGE:   0 absent, 1 == HEAD, 2 == WORKDIR, 3 != HEAD and != WORKDIR
export function porcelainXY(head, workdir, stage) {
  const untracked = head === 0 && stage === 0 && workdir === 2
  if (untracked) return { x: '?', y: '?', untracked: true }   // matches porcelain "??"

  // Staged side (x): HEAD → index.
  let x = ' '
  if (head === 0 && stage !== 0) x = 'A'          // added to the index
  else if (head === 1 && stage === 0) x = 'D'     // removed from the index
  else if (head === 1 && stage !== 0 && stage !== 1) x = 'M'  // index differs from HEAD

  // Unstaged side (y): index → worktree.
  let y = ' '
  if (workdir === 0 && stage !== 0) y = 'D'       // index has it; worktree does not
  else if (workdir === 2 && stage !== 2) y = 'M'              // worktree differs from the index

  return { x, y, untracked: false }
}

/// Status matching the CLI emit shape: { branch, ahead, behind, files:[{path,originalPath,paths,x,y,staged,untracked}] }.
export async function statusFallback(repoRoot) {
  const dir = repoRoot
  const matrix = await git.statusMatrix({ fs, dir })
  const files = []
  for (const [filepath, head, workdir, stage] of matrix) {
    if (head === 1 && workdir === 1 && stage === 1) continue   // unmodified — skip
    const { x, y, untracked } = porcelainXY(head, workdir, stage)
    if (x === ' ' && y === ' ') continue
    files.push({
      path: filepath,
      originalPath: null,          // isomorphic-git has no rename detection
      paths: [filepath],
      x, y,
      staged: x !== ' ' && x !== '?',
      untracked,
    })
  }
  let branch = ''
  try { branch = (await git.currentBranch({ fs, dir, fullname: false })) || '' } catch {}
  // No upstream comparison in the fallback path.
  return { branch, ahead: 0, behind: 0, files }
}

function validatedRepoPath(repoRoot, relPath) {
  if (typeof relPath !== 'string' || !relPath || relPath.includes('\0') || path.isAbsolute(relPath)) {
    throw new Error('Invalid repository-relative path.')
  }
  const normalized = path.posix.normalize(relPath)
  if (normalized === '.' || normalized === '..' || normalized.startsWith('../')
      || normalized === '.git' || normalized.startsWith('.git/')) {
    throw new Error('Path is outside the repository worktree.')
  }
  const root = path.resolve(repoRoot)
  const absolute = path.resolve(root, ...normalized.split('/'))
  if (!absolute.startsWith(`${root}${path.sep}`)) {
    throw new Error('Path is outside the repository worktree.')
  }
  return normalized
}

async function entryContent(entry, repoRoot) {
  if (!entry) return null
  const type = await entry.type()
  if (type === 'commit') return Buffer.from(`Subproject commit ${await entry.oid()}\n`)
  if (type !== 'blob' && type !== 'special') return null
  const content = await entry.content()
  if (content != null) return Buffer.from(content)
  // Index walker entries expose their object id but not content; read that blob explicitly.
  if (type === 'blob') {
    const oid = await entry.oid()
    if (oid) return Buffer.from((await git.readBlob({ fs, dir: repoRoot, oid })).blob)
  }
  return null
}

async function pathVersions(repoRoot, relPath) {
  let versions = [null, null, null]
  await git.walk({
    fs,
    dir: repoRoot,
    trees: [git.TREE({ ref: 'HEAD' }), git.STAGE(), git.WORKDIR({ refresh: false })],
    map: async (filepath, entries) => {
      if (filepath !== relPath) return undefined
      versions = await Promise.all(entries.map(entry => entryContent(entry, repoRoot)))
      return null // the selected path is a leaf; no need to descend further
    },
  })
  return versions
}

function isBinary(buffer) {
  return buffer?.subarray(0, 8_000).includes(0) ?? false
}

/// Unified diff of one path. A staged row compares HEAD → index; an unstaged row compares
/// index → worktree; an untracked row compares an empty file → worktree. This mirrors the CLI
/// contract used by handleGit rather than flattening mixed staged/unstaged changes into one diff.
export async function diffFallback(repoRoot, relPath, { staged = false, untracked = false } = {}) {
  const dir = repoRoot
  const filepath = validatedRepoPath(dir, relPath)
  const [head, index, worktree] = await pathVersions(dir, filepath)
  const oldBuffer = untracked ? null : (staged ? head : index)
  const newBuffer = staged ? index : worktree
  if ((oldBuffer && newBuffer && oldBuffer.equals(newBuffer)) || (!oldBuffer && !newBuffer)) return ''
  if (isBinary(oldBuffer) || isBinary(newBuffer)) {
    return `diff --git a/${filepath} b/${filepath}\nBinary files a/${filepath} and b/${filepath} differ\n`
  }
  const oldStr = oldBuffer?.toString('utf8') ?? ''
  const newStr = newBuffer?.toString('utf8') ?? ''
  if (oldStr === newStr) return ''
  // git-style header so the app's diff renderer sees familiar a/ b/ paths.
  const body = createTwoFilesPatch(`a/${filepath}`, `b/${filepath}`, oldStr, newStr, '', '', { context: 3 })
  return `diff --git a/${filepath} b/${filepath}\n${body}`
}

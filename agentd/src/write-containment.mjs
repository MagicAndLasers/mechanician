import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

// Where a file write is allowed to land.
//
// Edit/Write/NotebookEdit always carry an absolute path — measured at 100% of 4321 such calls in
// this machine's transcripts — so unlike Bash their target is structurally knowable before the
// write happens. This is the userspace stand-in for the OS sandbox other agent tools rely on:
// Seatbelt cannot wrap `swift build` (it does not nest, verified directly) and Linux containers
// cannot run Xcode, so the boundary has to sit at the tool call rather than around the process.
//
// Deliberately NOT attempted for Bash. A shell command reaches the same file through $HOME, a
// variable, or a path recorded turns earlier. A gate a careless agent routes around by accident is
// not a gate, and claiming otherwise would be worse than an honest gap.

/// Tool name -> the input field naming the file it writes.
export const WRITE_PATH_TOOLS = new Map([
  ['Edit', 'file_path'],
  ['Write', 'file_path'],
  ['NotebookEdit', 'notebook_path'],
])

/// Resolve symlinks as far up the chain as exists, then re-append the part that does not.
/// A `Write` to a new file has no realpath of its own, and resolving only the literal string would
/// let `<workspace>/../other/file` through.
export function resolveExistingAncestor(target) {
  const absolute = path.resolve(target)
  let current = absolute
  for (;;) {
    try {
      const real = fs.realpathSync(current)
      if (current === absolute) return real
      return path.join(real, path.relative(current, absolute))
    } catch {
      const parent = path.dirname(current)
      if (parent === current) return absolute
      current = parent
    }
  }
}

/// True when `target` is `root` or sits beneath it. The separator matters: `/a/b-c` must not count
/// as inside `/a/b`.
export function pathContains(root, target) {
  if (root === target) return true
  return target.startsWith(root.endsWith(path.sep) ? root : `${root}${path.sep}`)
}

/// Every root a turn may write to without being asked, besides the workspace itself.
///
/// `os.tmpdir()` is NOT sufficient on macOS and that gap was user-visible. There it returns the
/// PER-USER temp directory ($TMPDIR, `/var/folders/<...>/T`), while `/tmp` — the directory people
/// and agents actually mean by "temp" — is a symlink to `/private/tmp` and lives under neither the
/// workspace nor $TMPDIR. A `Write` to `/tmp/notes.txt` was therefore classified as an escaping
/// write and prompted, in EVERY permission mode including bypassPermissions, because containment
/// deliberately runs ahead of the mode check. That is exactly the case this allowance exists to
/// avoid: it is not the user's work, and prompting for it buries the cases that matter.
///
/// `/var/tmp` is included for the same reason; it is the other POSIX system temp root.
export const SYSTEM_TEMPORARY_DIRECTORIES = Object.freeze(['/tmp', '/var/tmp'])

/// The resolved target when a file write lands outside every root this turn may write to,
/// otherwise null.
///
/// The system temp directories are always allowed: agents scratch there constantly, it is not the
/// user's work, and prompting for it would bury the cases that matter.
export function escapingWriteTarget(toolName, input, workspaceRoot, {
  temporaryDirectories = [os.tmpdir(), ...SYSTEM_TEMPORARY_DIRECTORIES],
} = {}) {
  const field = WRITE_PATH_TOOLS.get(toolName)
  if (!field) return null
  const raw = input?.[field]
  if (typeof raw !== 'string' || !raw) return null
  const target = resolveExistingAncestor(raw)
  const roots = [workspaceRoot, ...temporaryDirectories]
    .filter((root) => typeof root === 'string' && root)
    .map(resolveExistingAncestor)
  return roots.some((root) => pathContains(root, target)) ? null : target
}

/// Grants are remembered per containing folder, not per file. Over this machine's whole history
/// that turns 1076 escaping writes into 31 one-time decisions.
export function writeEscapeAllowKey(target) {
  return `write-outside:${path.dirname(target)}`
}

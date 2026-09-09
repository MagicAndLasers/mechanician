// Cross-process advisory locking for files that live in a shared CODEX_HOME.
//
// Every Mechanician window owns a daemon while all Codex lanes share one CODEX_HOME, so any file in
// that home has several writers in unrelated processes. Pathname locks cannot safely reclaim a dead
// owner: POSIX has no compare-and-unlink primitive, so a stale reaper can delete a successor between
// its inode check and its unlink. macOS provides the right primitive in open(2): O_EXLOCK acquires
// an advisory exclusive lock tied to the returned file description, and the kernel releases it
// automatically when the holder exits. The persistent path is never unlinked.
//
// Extracted from the MCP managed-config lock so the account-refresh lease can reuse exactly the
// same acquisition and validation rules rather than growing a second, subtly different one.

import fs from 'node:fs'

// Darwin <sys/fcntl.h>. Node does not expose the BSD lock flags through fs.constants, but passes
// numeric open(2) flags through libuv unchanged on macOS.
const DARWIN_O_EXLOCK = 0x20

export const LOCK_UNAVAILABLE_CODES = Object.freeze(['EAGAIN', 'EWOULDBLOCK'])

export function openExclusiveLock(lockPath) {
  const flags = fs.constants.O_CREAT
    | fs.constants.O_RDWR
    | fs.constants.O_NONBLOCK
    | (fs.constants.O_NOFOLLOW ?? 0)
    | DARWIN_O_EXLOCK
  return fs.openSync(lockPath, flags, 0o600)
}

/// A lock is only a lock if nothing else can substitute the file underneath it. Reject a symlink
/// target, a hard-linked path, another user's file, or group/world-accessible permissions.
export function validateLockDescriptor(descriptor, label) {
  const status = fs.fstatSync(descriptor)
  if (!status.isFile() || status.nlink !== 1) {
    throw new Error(`${label} is not a private regular file.`)
  }
  if (typeof process.geteuid === 'function' && status.uid !== process.geteuid()) {
    throw new Error(`${label} has the wrong owner.`)
  }
  if ((status.mode & 0o077) !== 0) {
    throw new Error(`${label} has unsafe permissions.`)
  }
  return status
}

export function isLockHeldElsewhere(error) {
  return LOCK_UNAVAILABLE_CODES.includes(error?.code)
}

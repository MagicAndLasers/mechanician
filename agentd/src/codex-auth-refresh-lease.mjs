// Elect ONE proactive Codex token refresh per CODEX_HOME.
//
// `account/read { refreshToken: true }` is documented as requesting a *proactive* refresh, and the
// ChatGPT grant it rotates is single-use: the reply carries a new refresh token and retires the one
// that was presented. Mechanician runs several daemons against one CODEX_HOME (one per window, plus
// bounded local workers and rented plugin servers), and every provider start asked for that
// proactive refresh. When three daemons started together — the ordinary case when the app restarts a
// lane — three of them rotated the same grant within ~100 ms and the losers got back
//
//     401 refresh_token_reused: "Your refresh token has already been used to generate a new access
//     token. Please try signing in again."
//
// which the daemon reported as `loggedIn=false`. Every Codex sign-out recorded in this machine's
// logs was that race, never a real sign-out.
//
// The refresh is proactive, so skipping it is safe: omitting the flag still returns the account, and
// the runtime refreshes on its own when a token actually expires. This lease therefore lets the
// first daemon to ask do the rotation and tells the rest to read the account without forcing one.
//
// The timestamp lives INSIDE the lock file rather than beside it. The file is never unlinked, so the
// value cannot be read from a path that a concurrent writer has already replaced.

import fs from 'node:fs'
import path from 'node:path'

import {
  isLockHeldElsewhere, openExclusiveLock, validateLockDescriptor,
} from './codex-home-lock.mjs'

const LEASE_NAME = '.mechanician-auth-refresh.lock'
const LEASE_LABEL = 'Codex account refresh lease'
// Long enough that every daemon in one app launch shares a single rotation, short enough that a lane
// which genuinely needs a fresh token gets one on its next start rather than on its next hour.
export const CODEX_PROACTIVE_REFRESH_INTERVAL_MS = 5 * 60 * 1000
// A lease file is one small JSON object. Anything larger is not ours; read a bounded prefix so a
// corrupted or hostile home cannot turn a startup check into an unbounded read.
const MAX_LEASE_BYTES = 4096

function readLeaseTimestamp(descriptor) {
  const buffer = Buffer.alloc(MAX_LEASE_BYTES)
  let read = 0
  try {
    read = fs.readSync(descriptor, buffer, 0, MAX_LEASE_BYTES, 0)
  } catch {
    return 0
  }
  if (!read) return 0
  try {
    const value = JSON.parse(buffer.subarray(0, read).toString('utf8'))?.refreshedAt
    return Number.isSafeInteger(value) && value > 0 ? value : 0
  } catch {
    return 0
  }
}

function writeLeaseTimestamp(descriptor, refreshedAt) {
  const bytes = Buffer.from(`${JSON.stringify({ refreshedAt })}\n`, 'utf8')
  fs.ftruncateSync(descriptor, 0)
  fs.writeSync(descriptor, bytes, 0, bytes.byteLength, 0)
}

/// Claim the right to ask this Codex App Server for a proactive token refresh.
///
/// Returns `true` when this caller should send `refreshToken: true`, `false` when another daemon
/// already holds the lease or refreshed recently and this caller should read the account without
/// forcing a rotation. Never throws for lock contention: a caller that cannot claim the lease still
/// has a working account read, so contention must degrade to "do not force", not to a failed start.
export function claimCodexProactiveRefresh(codexHome, {
  now = Date.now,
  minimumIntervalMs = CODEX_PROACTIVE_REFRESH_INTERVAL_MS,
} = {}) {
  // agentd ships on macOS only, where O_EXLOCK exists. Anywhere else there is no shared home to
  // contend for either, so fail OPEN and keep the historical behaviour rather than silently
  // disabling refresh on a platform this lease was never needed on.
  if (process.platform !== 'darwin') return true
  let descriptor = null
  try {
    fs.mkdirSync(codexHome, { recursive: true })
    descriptor = openExclusiveLock(path.join(codexHome, LEASE_NAME))
    validateLockDescriptor(descriptor, LEASE_LABEL)
    const at = now()
    const refreshedAt = readLeaseTimestamp(descriptor)
    // A timestamp from the future is a clock change or a corrupted write, not a recent refresh.
    // Treating it as recent would suppress every proactive refresh until real time caught up.
    if (refreshedAt && refreshedAt <= at && at - refreshedAt < minimumIntervalMs) return false
    writeLeaseTimestamp(descriptor, at)
    return true
  } catch (error) {
    // Held right now by another daemon: it is mid-refresh, so this caller must not rotate too.
    if (isLockHeldElsewhere(error)) return false
    // Any other failure is about the lease file, not the account. Preserve the ability to refresh.
    return true
  } finally {
    if (descriptor !== null) {
      try { fs.closeSync(descriptor) } catch {}
    }
  }
}

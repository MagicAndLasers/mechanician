import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'

export const MANAGED_PLUGIN_LIMITS = Object.freeze({
  compressedBytes: 64 * 1024 * 1024,
  expandedBytes: 256 * 1024 * 1024,
  manifestBytes: 1024 * 1024,
  pathBytes: 4096,
  pathSegmentBytes: 255,
  files: 4096,
  redirects: 5,
  timeoutMilliseconds: 60_000,
})

export function describeManagedArchiveError(error) {
  const detail = String(error?.message || error || '').trim()
  return (detail || 'The managed plugin operation failed.').slice(0, 1_000)
}

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308])
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/
const MANIFEST_SUFFIX = '/.claude-plugin/plugin.json'
const MUTATION_LOCK_NAME = '.mutation-lock'
const MUTATION_CANDIDATE_PREFIX = '.mutation-candidate-'
const MUTATION_RECLAIM_PREFIX = '.mutation-reclaim-'
const LEASES_DIRECTORY_NAME = '.leases'
const LEASE_CANDIDATE_PREFIX = '.candidate-'
const LEASE_TOKEN_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const SLEEP_WORD = new Int32Array(new SharedArrayBuffer(4))

function cleanRequiredText(value, label, maximum = 256) {
  if (typeof value !== 'string' || !value || value !== value.trim()
      || value.length > maximum || CONTROL_CHARACTERS.test(value)) {
    throw new Error(`Managed plugin ${label} is invalid.`)
  }
  return value
}

function normalizedSourceID(value) {
  const sourceID = cleanRequiredText(value, 'source ID')
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(sourceID)) {
    throw new Error('Managed plugin source ID is invalid.')
  }
  return sourceID.toLowerCase()
}

function normalizedDigest(value) {
  if (value === undefined || value === null || String(value).trim() === '') return null
  const digest = String(value).trim().replace(/^sha256:/i, '').toLowerCase()
  if (!/^[0-9a-f]{64}$/.test(digest)) {
    throw new Error('Managed plugin archive SHA-256 is invalid.')
  }
  return digest
}

function normalizedLeaseToken(value) {
  const token = cleanRequiredText(value, 'lease token', 64).toLowerCase()
  if (!LEASE_TOKEN_PATTERN.test(token)) {
    throw new Error('Managed plugin lease token is invalid.')
  }
  return token
}

function safeHTTPSURL(value, label) {
  let url
  try { url = new URL(value) } catch {
    throw new Error(`Managed plugin ${label} is not a valid URL.`)
  }
  if (url.protocol !== 'https:') {
    throw new Error(`Managed plugin ${label} must use HTTPS.`)
  }
  if (url.username || url.password) {
    throw new Error(`Managed plugin ${label} must not contain credentials.`)
  }
  if (url.hash) {
    throw new Error(`Managed plugin ${label} must not contain a fragment.`)
  }
  return url
}

function parseOctalField(buffer, start, length, label) {
  const bytes = buffer.subarray(start, start + length)
  // Base-256 tar numeric fields begin with the high bit. Supporting them would make the accepted
  // archive grammar larger without helping these small, intentionally portable plugin bundles.
  if (bytes[0] & 0x80) throw new Error(`Managed plugin archive ${label} is unsupported.`)
  const text = bytes.toString('ascii').replace(/\0.*$/, '').trim()
  if (!text) return 0
  if (!/^[0-7]+$/.test(text)) throw new Error(`Managed plugin archive ${label} is invalid.`)
  const value = Number.parseInt(text, 8)
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`Managed plugin archive ${label} is invalid.`)
  }
  return value
}

function tarText(buffer, start, length) {
  const field = buffer.subarray(start, start + length)
  const end = field.indexOf(0)
  const text = field.subarray(0, end < 0 ? field.length : end).toString('utf8')
  if (text.includes('\uFFFD')) throw new Error('Managed plugin archive contains invalid UTF-8 paths.')
  return text
}

function tarChecksum(header) {
  let checksum = 0
  for (let index = 0; index < header.length; index += 1) {
    checksum += index >= 148 && index < 156 ? 0x20 : header[index]
  }
  return checksum
}

function safeArchivePath(rawName) {
  if (!rawName || CONTROL_CHARACTERS.test(rawName) || rawName.includes('\\')) {
    throw new Error('Managed plugin archive contains an invalid path.')
  }
  const withoutTrailingSlash = rawName.replace(/\/+$/, '')
  if (!withoutTrailingSlash || withoutTrailingSlash.startsWith('/')
      || /^[A-Za-z]:/.test(withoutTrailingSlash)) {
    throw new Error('Managed plugin archive contains an absolute path.')
  }
  const segments = withoutTrailingSlash.split('/')
  if (segments.some((segment) => !segment || segment === '.' || segment === '..')) {
    throw new Error('Managed plugin archive contains path traversal.')
  }
  if (Buffer.byteLength(withoutTrailingSlash, 'utf8') > MANAGED_PLUGIN_LIMITS.pathBytes
      || segments.some(
        (segment) => Buffer.byteLength(segment, 'utf8')
          > MANAGED_PLUGIN_LIMITS.pathSegmentBytes,
      )) {
    throw new Error('Managed plugin archive contains an overlong path.')
  }
  const normalized = path.posix.normalize(withoutTrailingSlash)
  if (normalized !== withoutTrailingSlash || normalized.startsWith('../')) {
    throw new Error('Managed plugin archive contains path traversal.')
  }
  return normalized
}

function parsePAX(content, recordLimit) {
  const values = new Map()
  let offset = 0
  let recordCount = 0
  while (offset < content.length) {
    recordCount += 1
    if (recordCount > recordLimit) {
      throw new Error(`Managed plugin archive contains more than ${recordLimit} PAX records.`)
    }
    const space = content.indexOf(0x20, offset)
    if (space < 0) throw new Error('Managed plugin archive has invalid PAX metadata.')
    const lengthText = content.subarray(offset, space).toString('ascii')
    if (!/^[1-9][0-9]*$/.test(lengthText)) {
      throw new Error('Managed plugin archive has invalid PAX metadata.')
    }
    const length = Number(lengthText)
    const end = offset + length
    if (!Number.isSafeInteger(length) || end > content.length || content[end - 1] !== 0x0a) {
      throw new Error('Managed plugin archive has invalid PAX metadata.')
    }
    const record = content.subarray(space + 1, end - 1)
    const equals = record.indexOf(0x3d)
    if (equals <= 0) throw new Error('Managed plugin archive has invalid PAX metadata.')
    const key = record.subarray(0, equals).toString('ascii')
    if (!/^[\x21-\x3c\x3e-\x7e]+$/.test(key) || values.has(key)) {
      throw new Error('Managed plugin archive has invalid PAX metadata.')
    }
    values.set(key, record.subarray(equals + 1))
    offset = end
  }
  return values
}

function paxUTF8(values, key) {
  const bytes = values.get(key)
  if (!bytes) return null
  const value = bytes.toString('utf8')
  if (value.includes('\uFFFD') || CONTROL_CHARACTERS.test(value)) {
    throw new Error(`Managed plugin archive PAX ${key} is invalid.`)
  }
  return value
}

function paxSize(values) {
  const raw = paxUTF8(values, 'size')
  if (raw === null) return null
  if (!/^(0|[1-9][0-9]*)$/.test(raw)) {
    throw new Error('Managed plugin archive PAX size is invalid.')
  }
  const value = Number(raw)
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error('Managed plugin archive PAX size is invalid.')
  }
  return value
}

function parseTar(buffer, { expandedByteLimit, fileCountLimit }) {
  const entries = []
  const collisionKeys = new Set()
  let offset = 0
  let payloadBytes = 0
  let reachedEnd = false
  let headerCount = 0
  let localPAX = null

  while (offset < buffer.length) {
    if (buffer.length - offset < 512) {
      throw new Error('Managed plugin archive has a truncated tar header.')
    }
    const header = buffer.subarray(offset, offset + 512)
    if (header.every((byte) => byte === 0)) {
      reachedEnd = true
      if (!buffer.subarray(offset).every((byte) => byte === 0)) {
        throw new Error('Managed plugin archive has data after its end marker.')
      }
      break
    }
    headerCount += 1
    if (headerCount > fileCountLimit) {
      throw new Error(`Managed plugin archive contains more than ${fileCountLimit} entries.`)
    }

    const expectedChecksum = parseOctalField(header, 148, 8, 'checksum')
    if (tarChecksum(header) !== expectedChecksum) {
      throw new Error('Managed plugin archive has an invalid tar checksum.')
    }
    const name = tarText(header, 0, 100)
    const prefix = tarText(header, 345, 155)
    const headerPath = safeArchivePath(prefix ? `${prefix}/${name}` : name)
    const headerSize = parseOctalField(header, 124, 12, 'entry size')
    const mode = parseOctalField(header, 100, 8, 'entry mode')
    const typeByte = header[156]
    const isLocalPAX = typeByte === 0x78
    const isGlobalPAX = typeByte === 0x67
    const size = localPAX && !isLocalPAX && !isGlobalPAX
      ? (paxSize(localPAX) ?? headerSize) : headerSize
    const contentStart = offset + 512
    const paddedSize = Math.ceil(size / 512) * 512
    const nextOffset = contentStart + paddedSize
    if (nextOffset > buffer.length) {
      throw new Error('Managed plugin archive contains a truncated file.')
    }
    payloadBytes += size
    if (payloadBytes > expandedByteLimit) {
      throw new Error(`Managed plugin archive expands beyond ${expandedByteLimit} bytes.`)
    }

    if (isLocalPAX || isGlobalPAX) {
      if (localPAX) {
        throw new Error('Managed plugin archive contains nested PAX metadata.')
      }
      const values = parsePAX(buffer.subarray(contentStart, contentStart + size), fileCountLimit)
      // Sparse-file extensions change the meaning of the following regular-file payload and are
      // intentionally outside this small archive grammar.
      if ([...values.keys()].some(
        (key) => key.startsWith('GNU.sparse') || key === 'SCHILY.realsize',
      )) {
        throw new Error('Managed plugin archive contains unsupported sparse-file metadata.')
      }
      if (isGlobalPAX) {
        if (values.has('path') || values.has('size') || values.has('linkpath')) {
          throw new Error('Managed plugin archive contains unsafe global PAX metadata.')
        }
      } else {
        localPAX = values
      }
      offset = nextOffset
      continue
    }

    const archivePath = safeArchivePath(paxUTF8(localPAX ?? new Map(), 'path') ?? headerPath)
    localPAX = null
    const collisionKey = archivePath.normalize('NFC').toLowerCase()
    if (!collisionKeys.add(collisionKey)) {
      throw new Error(`Managed plugin archive contains a duplicate path: ${archivePath}`)
    }

    const type = typeByte === 0 || typeByte === 0x30 ? 'file'
      : typeByte === 0x35 ? 'directory' : 'unsafe'
    if (type === 'unsafe') {
      const kind = String.fromCharCode(typeByte || 0)
      throw new Error(
        `Managed plugin archive contains an unsupported link, device, or metadata entry (${kind}).`,
      )
    }
    if (type === 'directory' && size !== 0) {
      throw new Error('Managed plugin archive contains a directory with file data.')
    }
    entries.push({
      archivePath,
      type,
      mode,
      content: type === 'file' ? buffer.subarray(contentStart, contentStart + size) : null,
    })
    offset = nextOffset
  }

  if (!reachedEnd || entries.length === 0) {
    throw new Error('Managed plugin archive is empty or has no tar end marker.')
  }
  if (localPAX) throw new Error('Managed plugin archive ends with unapplied PAX metadata.')
  return entries
}

function inspectPlugin(entries, expectedName, expectedVersion) {
  const roots = new Set(entries.map((entry) => entry.archivePath.split('/')[0]))
  if (roots.size !== 1) {
    throw new Error('Managed plugin archive must contain exactly one top-level plugin directory.')
  }
  const [rootName] = roots
  const rootEntry = entries.find((entry) => entry.archivePath === rootName)
  if (rootEntry && rootEntry.type !== 'directory') {
    throw new Error('Managed plugin archive top-level root must be a directory.')
  }
  const manifestPath = `${rootName}${MANIFEST_SUFFIX}`
  const manifestCandidates = entries.filter(
    (entry) => entry.archivePath.endsWith(MANIFEST_SUFFIX),
  )
  if (manifestCandidates.length !== 1
      || manifestCandidates[0].archivePath !== manifestPath
      || manifestCandidates[0].type !== 'file') {
    throw new Error(
      'Managed plugin archive must contain exactly one regular .claude-plugin/plugin.json.',
    )
  }
  if (manifestCandidates[0].content.byteLength > MANAGED_PLUGIN_LIMITS.manifestBytes) {
    throw new Error(
      `Managed plugin manifest exceeds ${MANAGED_PLUGIN_LIMITS.manifestBytes} bytes.`,
    )
  }

  let manifest
  try {
    const json = new TextDecoder('utf-8', { fatal: true }).decode(manifestCandidates[0].content)
    manifest = JSON.parse(json)
  } catch {
    throw new Error('Managed plugin manifest is not valid UTF-8 JSON.')
  }
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)
      || manifest.name !== expectedName) {
    throw new Error(`Managed plugin manifest name must be "${expectedName}".`)
  }
  if (expectedVersion !== null && manifest.version !== expectedVersion) {
    throw new Error(`Managed plugin manifest version must be "${expectedVersion}".`)
  }
  if (manifest.version !== undefined) {
    try { cleanRequiredText(manifest.version, 'manifest version', 128) } catch {
      throw new Error('Managed plugin manifest version is invalid.')
    }
  }
  return { rootName, manifest }
}

async function boundedResponseBytes(response, limit) {
  const declared = Number(response.headers?.get?.('content-length'))
  if (Number.isFinite(declared) && declared > limit) {
    throw new Error(`Managed plugin archive exceeds ${limit} compressed bytes.`)
  }
  if (response.body?.getReader) {
    const reader = response.body.getReader()
    const chunks = []
    let total = 0
    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        const bytes = value instanceof Uint8Array ? value : new Uint8Array(value)
        total += bytes.byteLength
        if (total > limit) {
          try { await reader.cancel() } catch {}
          throw new Error(`Managed plugin archive exceeds ${limit} compressed bytes.`)
        }
        chunks.push(bytes)
      }
    } finally {
      try { reader.releaseLock?.() } catch {}
    }
    return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), total)
  }
  throw new Error('Managed plugin archive response did not provide a readable byte stream.')
}

async function cancelResponseBody(response) {
  try {
    if (typeof response?.body?.cancel === 'function') {
      await response.body.cancel()
      return
    }
    if (typeof response?.body?.getReader === 'function') {
      const reader = response.body.getReader()
      try { await reader.cancel() } finally {
        try { reader.releaseLock?.() } catch {}
      }
    }
  } catch {}
}

async function downloadArchive({
  archiveURL,
  catalogURL,
  authentication,
  fetchImpl,
  getIdentityToken,
  compressedByteLimit,
  redirectLimit,
  timeoutMilliseconds,
}) {
  const catalog = safeHTTPSURL(catalogURL, 'catalog URL')
  let current = safeHTTPSURL(archiveURL, 'archive URL')

  let token = null
  if (authentication === 'googleIdentity') {
    if (current.origin !== catalog.origin) {
      throw new Error(
        'Authenticated managed plugin archive URL must have the same origin as its signed catalog.',
      )
    }
    const identityToken = await getIdentityToken?.()
    if (typeof identityToken !== 'string' || !identityToken
        || identityToken !== identityToken.trim() || CONTROL_CHARACTERS.test(identityToken)) {
      throw new Error('Google identity is unavailable for the managed plugin archive.')
    }
    token = identityToken
  } else if (authentication !== undefined && authentication !== null) {
    throw new Error('Managed plugin archive authentication is unsupported.')
  }

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMilliseconds)
  try {
    for (let redirects = 0; ; redirects += 1) {
      const headers = { Accept: 'application/gzip, application/octet-stream' }
      if (token) headers.Authorization = `Bearer ${token}`
      const response = await fetchImpl(current.href, {
        method: 'GET',
        headers,
        redirect: 'manual',
        signal: controller.signal,
      })
      if (REDIRECT_STATUSES.has(response?.status)) {
        await cancelResponseBody(response)
        if (redirects >= redirectLimit) {
          throw new Error(`Managed plugin archive exceeded ${redirectLimit} redirects.`)
        }
        const location = response.headers?.get?.('location')
        if (!location) throw new Error('Managed plugin archive redirect omitted its location.')
        let next
        try { next = safeHTTPSURL(new URL(location, current).href, 'redirect URL') } catch (error) {
          throw error
        }
        if (token && next.origin !== catalog.origin) {
          throw new Error(
            'Authenticated managed plugin archive redirect left the signed catalog origin.',
          )
        }
        current = next
        continue
      }
      if (!response?.ok) {
        await cancelResponseBody(response)
        throw new Error(
          `Managed plugin archive download failed (${response?.status || 'unknown status'}).`,
        )
      }
      return await boundedResponseBytes(response, compressedByteLimit)
    }
  } catch (error) {
    if (error?.name === 'AbortError') {
      throw new Error('Managed plugin archive download timed out.')
    }
    throw error
  } finally {
    clearTimeout(timer)
  }
}

function ensurePrivateDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 })
  const status = fs.lstatSync(directory)
  if (!status.isDirectory() || status.isSymbolicLink()) {
    throw new Error('Managed plugin install root must be a real directory.')
  }
  fs.chmodSync(directory, 0o700)
}

function directorySync(directory) {
  try {
    const descriptor = fs.openSync(directory, 'r')
    try { fs.fsyncSync(descriptor) } finally { fs.closeSync(descriptor) }
  } catch {}
}

function defaultProcessIsAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    if (error?.code === 'ESRCH') return false
    // EPERM and unexpected inspection failures are not proof that the owner is gone.
    return true
  }
}

function privateJSONCandidate(directory, prefix, value, identifier = crypto.randomUUID()) {
  const candidate = path.join(directory, `${prefix}${identifier}`)
  let descriptor = null
  try {
    descriptor = fs.openSync(candidate, 'wx', 0o600)
    fs.writeFileSync(descriptor, `${JSON.stringify(value)}\n`)
    fs.fsyncSync(descriptor)
    fs.closeSync(descriptor)
    descriptor = null
    fs.chmodSync(candidate, 0o600)
    return candidate
  } catch (error) {
    if (descriptor !== null) try { fs.closeSync(descriptor) } catch {}
    try { fs.unlinkSync(candidate) } catch {}
    throw error
  }
}

function readPrivateJSONFile(file, label, { allowSecondLink = false } = {}) {
  let descriptor
  try {
    descriptor = fs.openSync(
      file,
      fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0),
    )
  } catch (error) {
    if (error?.code === 'ENOENT') return null
    throw error
  }
  try {
    const before = fs.fstatSync(descriptor)
    if (allowSecondLink && before.nlink === 0) return null
    if (!before.isFile()
        || (before.nlink !== 1 && !(allowSecondLink && before.nlink === 2))) {
      throw new Error(`Managed plugin ${label} is not a private regular file.`)
    }
    verifyOwnerOnly(before, 0o600)
    const bytes = fs.readFileSync(descriptor, 'utf8')
    const after = fs.fstatSync(descriptor)
    if (allowSecondLink && after.nlink === 0) return null
    if (after.dev !== before.dev || after.ino !== before.ino
        || !after.isFile()
        || (after.nlink !== 1 && !(allowSecondLink && after.nlink === 2))) {
      throw new Error(`Managed plugin ${label} is not a private regular file.`)
    }
    verifyOwnerOnly(after, 0o600)
    try {
      return { value: JSON.parse(bytes), status: after }
    } catch {
      throw new Error(`Managed plugin ${label} is corrupt.`)
    }
  } finally {
    fs.closeSync(descriptor)
  }
}

function acquireMutationReclaimClaim(root, lockToken, {
  now,
  processIsAlive,
  staleMilliseconds,
}) {
  const claimPath = path.join(root, `${MUTATION_RECLAIM_PREFIX}${lockToken}`)
  const claimToken = crypto.randomUUID()
  const candidateIdentifier = `reclaim-${claimToken}`
  const candidateName = `${MUTATION_CANDIDATE_PREFIX}${candidateIdentifier}`
  const candidate = privateJSONCandidate(root, MUTATION_CANDIDATE_PREFIX, {
    claimToken,
    lockToken,
    pid: process.pid,
    createdAt: now(),
    candidateName,
  }, candidateIdentifier)
  try {
    fs.linkSync(candidate, claimPath)
    try { fs.unlinkSync(candidate) } catch {}
    directorySync(root)
    return { claimPath, claimToken, candidate }
  } catch (error) {
    try { fs.unlinkSync(candidate) } catch {}
    if (error?.code !== 'EEXIST') throw error
  }

  const existing = readPrivateJSONFile(
    claimPath, 'mutation reclaim claim', { allowSecondLink: true },
  )
  if (!existing) return null
  const existingClaimToken = String(existing.value?.claimToken || '')
  const existingLockToken = String(existing.value?.lockToken || '')
  const existingCandidateName = String(existing.value?.candidateName || '')
  const age = now() - Number(existing.value?.createdAt)
  const pid = Number(existing.value?.pid)
  if (!LEASE_TOKEN_PATTERN.test(existingClaimToken)
      || existingLockToken !== lockToken
      || existingCandidateName !== `${MUTATION_CANDIDATE_PREFIX}reclaim-${existingClaimToken}`
      || !Number.isFinite(age)) {
    throw new Error('Managed plugin mutation reclaim claim is corrupt.')
  }
  if (age >= staleMilliseconds && !processIsAlive(pid)) {
    // Retiring a stale claim does not authorize touching the well-known lock. Every contender loops
    // back through the deterministic no-overwrite link; exactly one of them can become the next
    // claimant even on filesystems where concurrent unlink calls may all report success.
    try { fs.unlinkSync(claimPath) } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }
    try { fs.unlinkSync(path.join(root, existingCandidateName)) } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }
    directorySync(root)
  } else {
    Atomics.wait(SLEEP_WORD, 0, 0, 25)
  }
  return null
}

function releaseMutationReclaimClaim(root, claim) {
  const existing = readPrivateJSONFile(
    claim.claimPath, 'mutation reclaim claim', { allowSecondLink: true },
  )
  if (existing?.value?.claimToken === claim.claimToken
      && existing.value?.pid === process.pid) {
    try { fs.unlinkSync(claim.claimPath) } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }
  }
  try { fs.unlinkSync(claim.candidate) } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
  directorySync(root)
}

function acquireMutationLock(root, {
  now,
  processIsAlive,
  waitMilliseconds,
  staleMilliseconds,
}) {
  ensurePrivateDirectory(root)
  const lockPath = path.join(root, MUTATION_LOCK_NAME)
  const deadline = now() + waitMilliseconds
  let attempted = false
  while (true) {
    if (attempted && now() >= deadline) {
      throw new Error('Managed plugin filesystem mutation lock timed out.')
    }
    attempted = true
    const token = crypto.randomUUID()
    const candidateName = `${MUTATION_CANDIDATE_PREFIX}${token}`
    const candidate = privateJSONCandidate(root, MUTATION_CANDIDATE_PREFIX, {
      token,
      pid: process.pid,
      createdAt: now(),
      candidateName,
    }, token)
    try {
      fs.linkSync(candidate, lockPath)
      directorySync(root)
      // Keep the token-specific candidate as a second hard link for the lock's lifetime. A stale
      // reclaimer must atomically claim that exact link before it may unlink the well-known path,
      // so two reclaimers cannot accidentally remove a newer process's lock.
      return { lockPath, candidate, token }
    } catch (error) {
      try { fs.unlinkSync(candidate) } catch {}
      if (error?.code !== 'EEXIST') throw error
    }

    const existing = readPrivateJSONFile(
      lockPath, 'mutation lock', { allowSecondLink: true },
    )
    if (!existing) continue
    const age = now() - Number(existing.value?.createdAt)
    const pid = Number(existing.value?.pid)
    const stale = Number.isFinite(age) && age >= staleMilliseconds
      && !processIsAlive(pid)
    if (stale) {
      const existingToken = String(existing.value?.token || '')
      const existingCandidateName = String(existing.value?.candidateName || '')
      if (!LEASE_TOKEN_PATTERN.test(existingToken)
          || existingCandidateName !== `${MUTATION_CANDIDATE_PREFIX}${existingToken}`) {
        throw new Error('Managed plugin mutation lock is corrupt.')
      }
      const claim = acquireMutationReclaimClaim(root, existingToken, {
        now, processIsAlive, staleMilliseconds,
      })
      if (!claim) continue
      try {
        // A contender may have observed the stale lock long before it won the deterministic claim.
        // Re-read through an fd and compare the exact inode and token before the one authorized
        // unlink; a successor is never retired on the strength of an old observation.
        const current = readPrivateJSONFile(
          lockPath, 'mutation lock', { allowSecondLink: true },
        )
        if (!current
            || current.value?.token !== existingToken
            || current.status.dev !== existing.status.dev
            || current.status.ino !== existing.status.ino) {
          continue
        }
        const currentAge = now() - Number(current.value?.createdAt)
        if (!Number.isFinite(currentAge) || currentAge < staleMilliseconds
            || processIsAlive(Number(current.value?.pid))) {
          continue
        }
        fs.unlinkSync(lockPath)
        try { fs.unlinkSync(path.join(root, existingCandidateName)) } catch (error) {
          if (error?.code !== 'ENOENT') throw error
        }
        directorySync(root)
      } finally {
        releaseMutationReclaimClaim(root, claim)
      }
      continue
    }
    Atomics.wait(SLEEP_WORD, 0, 0, 25)
  }
}

function releaseMutationLock(root, lock) {
  const existing = readPrivateJSONFile(
    lock.lockPath, 'mutation lock', { allowSecondLink: true },
  )
  if (!existing || existing.value?.token !== lock.token
      || existing.value?.pid !== process.pid) {
    throw new Error('Managed plugin filesystem mutation lock ownership was lost.')
  }
  fs.unlinkSync(lock.lockPath)
  try { fs.unlinkSync(lock.candidate) } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
  directorySync(root)
}

function withMutationLock(root, options, work) {
  const lock = acquireMutationLock(root, options)
  try {
    return work()
  } finally {
    releaseMutationLock(root, lock)
  }
}

function relativeEntryPath(entry, rootName) {
  if (entry.archivePath === rootName) return ''
  const prefix = `${rootName}/`
  if (!entry.archivePath.startsWith(prefix)) {
    throw new Error('Managed plugin archive escaped its plugin root.')
  }
  return entry.archivePath.slice(prefix.length)
}

function extractEntries(entries, rootName, destination) {
  for (const entry of entries) {
    const relative = relativeEntryPath(entry, rootName)
    if (!relative) continue
    const target = path.join(destination, ...relative.split('/'))
    const resolvedRelative = path.relative(destination, target)
    if (!resolvedRelative || resolvedRelative === '..'
        || resolvedRelative.startsWith(`..${path.sep}`) || path.isAbsolute(resolvedRelative)) {
      throw new Error('Managed plugin archive escaped its staging directory.')
    }
    if (entry.type === 'directory') {
      fs.mkdirSync(target, { recursive: true, mode: 0o700 })
      fs.chmodSync(target, 0o700)
      continue
    }
    const parent = path.dirname(target)
    fs.mkdirSync(parent, { recursive: true, mode: 0o700 })
    const mode = entry.mode & 0o111 ? 0o700 : 0o600
    let descriptor = null
    try {
      descriptor = fs.openSync(target, 'wx', mode)
      fs.writeFileSync(descriptor, entry.content)
      fs.fsyncSync(descriptor)
      fs.closeSync(descriptor)
      descriptor = null
      fs.chmodSync(target, mode)
    } catch (error) {
      if (descriptor !== null) try { fs.closeSync(descriptor) } catch {}
      throw error
    }
  }
  directorySync(destination)
}

function expectedTree(entries, rootName) {
  const expected = new Map()
  const addParents = (relative) => {
    let parent = path.posix.dirname(relative)
    while (parent && parent !== '.') {
      if (!expected.has(parent)) expected.set(parent, { type: 'directory' })
      parent = path.posix.dirname(parent)
    }
  }
  for (const entry of entries) {
    const relative = relativeEntryPath(entry, rootName)
    if (!relative) continue
    addParents(relative)
    expected.set(relative, entry)
  }
  return expected
}

function expectedMode(entry) {
  if (entry.type === 'directory') return 0o700
  return entry.mode & 0o111 ? 0o700 : 0o600
}

function verifyOwnerOnly(status, mode) {
  if ((status.mode & 0o777) !== mode) {
    throw new Error('Existing managed plugin install has unsafe filesystem permissions.')
  }
  if (typeof process.getuid === 'function' && status.uid !== process.getuid()) {
    throw new Error('Existing managed plugin install has an unexpected filesystem owner.')
  }
}

function verifyExistingTree(directory, entries, rootName) {
  const status = fs.lstatSync(directory)
  if (!status.isDirectory() || status.isSymbolicLink()) {
    throw new Error('Existing managed plugin install is not a real directory.')
  }
  verifyOwnerOnly(status, 0o700)
  const expected = expectedTree(entries, rootName)
  const actual = new Set()
  const walk = (current, prefix = '') => {
    for (const item of fs.readdirSync(current, { withFileTypes: true })) {
      const relative = prefix ? `${prefix}/${item.name}` : item.name
      const target = path.join(current, item.name)
      const itemStatus = fs.lstatSync(target)
      if (itemStatus.isSymbolicLink() || (!itemStatus.isDirectory() && !itemStatus.isFile())) {
        throw new Error('Existing managed plugin install contains an unsafe filesystem entry.')
      }
      actual.add(relative)
      const wanted = expected.get(relative)
      if (!wanted || (wanted.type === 'directory') !== itemStatus.isDirectory()) {
        throw new Error('Existing managed plugin install does not match its archive.')
      }
      verifyOwnerOnly(itemStatus, expectedMode(wanted))
      if (itemStatus.isDirectory()) {
        walk(target, relative)
      } else if (itemStatus.nlink !== 1
          || itemStatus.size !== wanted.content.byteLength
          || !fs.readFileSync(target).equals(wanted.content)) {
        throw new Error('Existing managed plugin install does not match its archive.')
      }
    }
  }
  walk(directory)
  if (actual.size !== expected.size || [...expected.keys()].some((item) => !actual.has(item))) {
    throw new Error('Existing managed plugin install does not match its archive.')
  }
}

function versionLabel(version) {
  const label = String(version || 'unversioned')
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48)
  return label || 'unversioned'
}

function managedPaths(installRoot, sourceID, pluginName, version, digest) {
  const key = (value) => crypto.createHash('sha256')
    .update(value, 'utf8').digest('hex').slice(0, 24)
  const sourceDirectory = path.join(installRoot, `source-${key(sourceID)}`)
  const ownerDirectory = path.join(sourceDirectory, `plugin-${key(pluginName)}`)
  const versionDirectory = path.join(
    ownerDirectory,
    `v-${versionLabel(version)}-${digest.slice(0, 16)}`,
  )
  return { sourceDirectory, ownerDirectory, versionDirectory }
}

/// Fail-closed guard used immediately before deletion. Disabled plugins still count as mounted:
/// the user can re-enable them without another install.
export function isManagedPluginPathMounted({ extensionsFile, installPath }) {
  const file = path.resolve(cleanRequiredText(extensionsFile, 'extensions file', 4096))
  const target = path.resolve(cleanRequiredText(installPath, 'install path', 4096))
  let config
  try {
    config = JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    if (error?.code === 'ENOENT') return false
    throw new Error('Managed plugin mounts could not be verified before deletion.')
  }
  if (!config || !Array.isArray(config.plugins)) {
    throw new Error('Managed plugin mounts could not be verified before deletion.')
  }
  return config.plugins.some(
    (plugin) => plugin?.path && path.resolve(String(plugin.path)) === target,
  )
}

function normalizedManagedIdentity({
  installRoot,
  sourceId,
  pluginName,
  version = null,
  sha256,
  installPath,
}) {
  const root = path.resolve(cleanRequiredText(installRoot, 'install root', 4096))
  const normalizedSource = normalizedSourceID(sourceId)
  const normalizedName = cleanRequiredText(pluginName, 'name')
  const normalizedVersion = version === undefined || version === null
    ? null : cleanRequiredText(version, 'version', 128)
  const digest = normalizedDigest(sha256)
  if (!digest) throw new Error('Managed plugin uninstall SHA-256 is required.')
  const target = path.resolve(cleanRequiredText(installPath, 'install path', 4096))
  const expectedTarget = managedPaths(
    root, normalizedSource, normalizedName, normalizedVersion, digest,
  ).versionDirectory
  if (target !== expectedTarget) {
    throw new Error('Managed plugin uninstall identity does not match its installed path.')
  }
  const relative = path.relative(root, target)
  const parts = relative.split(path.sep)
  if (parts.length !== 3
      || !/^source-[0-9a-f]{24}$/.test(parts[0])
      || !/^plugin-[0-9a-f]{24}$/.test(parts[1])
      || !/^v-[A-Za-z0-9._-]+-[0-9a-f]{16}$/.test(parts[2])
      || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('Managed plugin uninstall path is not an exact installed version.')
  }
  const ownerDirectory = path.dirname(target)
  const sourceDirectory = path.dirname(ownerDirectory)
  return {
    root,
    sourceId: normalizedSource,
    pluginName: normalizedName,
    version: normalizedVersion,
    sha256: digest,
    installPath: target,
    ownerDirectory,
    sourceDirectory,
  }
}

function sameManagedIdentity(first, second) {
  return first.root === second.root
    && first.sourceId === second.sourceId
    && first.pluginName === second.pluginName
    && first.version === second.version
    && first.sha256 === second.sha256
    && first.installPath === second.installPath
}

function removeManagedPluginIdentity(identity) {
  const {
    root,
    installPath: target,
    ownerDirectory,
    sourceDirectory,
  } = identity
  for (const directory of [root, sourceDirectory, ownerDirectory]) {
    let directoryStatus
    try { directoryStatus = fs.lstatSync(directory) } catch (error) {
      if (error?.code === 'ENOENT') return false
      throw error
    }
    if (!directoryStatus.isDirectory() || directoryStatus.isSymbolicLink()) {
      throw new Error('Managed plugin uninstall parent is not a real directory.')
    }
    verifyOwnerOnly(directoryStatus, 0o700)
  }
  let status
  try { status = fs.lstatSync(target) } catch (error) {
    if (error?.code === 'ENOENT') return false
    throw error
  }
  if (!status.isDirectory() || status.isSymbolicLink()) {
    throw new Error('Managed plugin uninstall target is not a real directory.')
  }
  verifyOwnerOnly(status, 0o700)
  fs.rmSync(target, { recursive: true, force: false })
  try { fs.rmdirSync(ownerDirectory) } catch (error) {
    if (error?.code !== 'ENOTEMPTY' && error?.code !== 'ENOENT') throw error
  }
  try { fs.rmdirSync(sourceDirectory) } catch (error) {
    if (error?.code !== 'ENOTEMPTY' && error?.code !== 'ENOENT') throw error
  }
  directorySync(root)
  return true
}

export function uninstallManagedPlugin(request) {
  return removeManagedPluginIdentity(normalizedManagedIdentity(request))
}

function ensureLeaseDirectory(root) {
  const directory = path.join(root, LEASES_DIRECTORY_NAME)
  ensurePrivateDirectory(directory)
  return directory
}

function leaseFile(root, token) {
  return path.join(root, LEASES_DIRECTORY_NAME, `${token}.json`)
}

function createInstallLease(root, identity, now) {
  const directory = ensureLeaseDirectory(root)
  const token = crypto.randomUUID().toLowerCase()
  const createdAt = now()
  if (!Number.isSafeInteger(createdAt) || createdAt < 0) {
    throw new Error('Managed plugin lifecycle clock returned an invalid time.')
  }
  const record = {
    token,
    sourceId: identity.sourceId,
    pluginName: identity.pluginName,
    version: identity.version,
    sha256: identity.sha256,
    installPath: identity.installPath,
    createdAt,
    ownerPid: process.pid,
    // agentd is a direct child of the app. Keeping the client PID in the lease closes the narrow
    // case where agentd dies after delivering the result but before a suspended app commits it.
    clientPid: process.ppid,
  }
  const candidate = privateJSONCandidate(directory, LEASE_CANDIDATE_PREFIX, record)
  const destination = leaseFile(root, token)
  let linked = false
  try {
    fs.linkSync(candidate, destination)
    linked = true
    try { fs.unlinkSync(candidate) } catch {}
    directorySync(directory)
  } catch (error) {
    try { fs.unlinkSync(candidate) } catch {}
    if (linked) try { fs.unlinkSync(destination) } catch {}
    throw error
  }
  return { token, file: destination, record, identity }
}

function readInstallLeases(root) {
  const directory = path.join(root, LEASES_DIRECTORY_NAME)
  let directoryStatus
  try {
    directoryStatus = fs.lstatSync(directory)
  } catch (error) {
    if (error?.code === 'ENOENT') return []
    throw error
  }
  if (!directoryStatus.isDirectory() || directoryStatus.isSymbolicLink()) {
    throw new Error('Managed plugin lease directory is not a real directory.')
  }
  verifyOwnerOnly(directoryStatus, 0o700)
  const leases = []
  for (const name of fs.readdirSync(directory)) {
    const file = path.join(directory, name)
    if (name.startsWith(LEASE_CANDIDATE_PREFIX)) {
      // A candidate is made durable before it is linked to its final name, and plugin publication
      // occurs only after that link. Under the mutation lock, any remaining candidate is therefore
      // crash debris rather than protection for a published path.
      const status = fs.lstatSync(file)
      if (!status.isFile() || status.isSymbolicLink()) {
        throw new Error('Managed plugin lease candidate is unsafe.')
      }
      verifyOwnerOnly(status, 0o600)
      fs.unlinkSync(file)
      continue
    }
    const match = /^([0-9a-f-]+)\.json$/.exec(name)
    if (!match || !LEASE_TOKEN_PATTERN.test(match[1])) {
      throw new Error('Managed plugin lease directory contains an unexpected entry.')
    }
    const loaded = readPrivateJSONFile(file, 'install lease')
    const record = loaded?.value
    const token = normalizedLeaseToken(record?.token)
    if (token !== match[1]
        || !Number.isSafeInteger(record?.createdAt) || record.createdAt < 0
        || !Number.isSafeInteger(record?.ownerPid) || record.ownerPid <= 0
        || !Number.isSafeInteger(record?.clientPid) || record.clientPid <= 0) {
      throw new Error('Managed plugin install lease is corrupt.')
    }
    const identity = normalizedManagedIdentity({
      installRoot: root,
      sourceId: record.sourceId,
      pluginName: record.pluginName,
      version: record.version,
      sha256: record.sha256,
      installPath: record.installPath,
    })
    leases.push({ token, file, record, identity })
  }
  directorySync(directory)
  return leases
}

function removeInstallLease(lease) {
  try {
    fs.unlinkSync(lease.file)
    directorySync(path.dirname(lease.file))
    return true
  } catch (error) {
    if (error?.code === 'ENOENT') return false
    throw error
  }
}

function installPathExists(installPath) {
  try {
    fs.lstatSync(installPath)
    return true
  } catch (error) {
    if (error?.code === 'ENOENT') return false
    throw error
  }
}

function leaseProtection(lease, { now, processIsAlive, leaseGraceMilliseconds }) {
  if (processIsAlive(lease.record.ownerPid) || processIsAlive(lease.record.clientPid)) {
    return { protected: true, retryAfterMilliseconds: null }
  }
  const remaining = leaseGraceMilliseconds - (now() - lease.record.createdAt)
  return {
    protected: remaining > 0,
    retryAfterMilliseconds: remaining > 0 ? Math.ceil(remaining) : null,
  }
}

function matchingInstallLeases(leases, identity) {
  return leases.filter((lease) => sameManagedIdentity(lease.identity, identity))
}

function reconcileInstallLeases({
  root,
  extensionsFile,
  now,
  processIsAlive,
  leaseGraceMilliseconds,
}) {
  const leases = readInstallLeases(root)
  const byPath = new Map()
  for (const lease of leases) {
    const group = byPath.get(lease.identity.installPath) ?? []
    group.push(lease)
    byPath.set(lease.identity.installPath, group)
  }
  let removedPaths = 0
  let removedLeases = 0
  let retryAfterMilliseconds = null
  for (const group of byPath.values()) {
    const identity = group[0].identity
    if (group.some((lease) => !sameManagedIdentity(identity, lease.identity))) {
      throw new Error('Managed plugin leases disagree about an installed path identity.')
    }
    const mounted = isManagedPluginPathMounted({
      extensionsFile,
      installPath: identity.installPath,
    })
    if (!installPathExists(identity.installPath)) {
      for (const lease of group) if (removeInstallLease(lease)) removedLeases += 1
      continue
    }
    const protections = group.map((lease) => ({
      lease,
      ...leaseProtection(lease, { now, processIsAlive, leaseGraceMilliseconds }),
    }))
    if (mounted) {
      // Durable configuration is the authority. Retain live leases so a concurrent uninstall
      // cannot erase another installer's commit gap, but discard dead-owner debris.
      for (const entry of protections.filter((item) => !item.protected)) {
        if (removeInstallLease(entry.lease)) removedLeases += 1
      }
      for (const entry of protections.filter((item) => item.protected)) {
        const retry = entry.retryAfterMilliseconds
        if (retry !== null
            && (retryAfterMilliseconds === null || retry < retryAfterMilliseconds)) {
          retryAfterMilliseconds = retry
        }
      }
      continue
    }
    const protectedEntries = protections.filter((item) => item.protected)
    if (protectedEntries.length > 0) {
      for (const entry of protections.filter((item) => !item.protected)) {
        if (removeInstallLease(entry.lease)) removedLeases += 1
      }
      for (const entry of protectedEntries) {
        const retry = entry.retryAfterMilliseconds
        if (retry !== null
            && (retryAfterMilliseconds === null || retry < retryAfterMilliseconds)) {
          retryAfterMilliseconds = retry
        }
      }
      continue
    }
    if (removeManagedPluginIdentity(identity)) removedPaths += 1
    for (const lease of group) if (removeInstallLease(lease)) removedLeases += 1
  }
  return { removedPaths, removedLeases, retryAfterMilliseconds }
}

export function createManagedPluginInstaller({
  fetchImpl = fetch,
  getIdentityToken = async () => null,
  installRoot,
  extensionsFile,
  compressedByteLimit = MANAGED_PLUGIN_LIMITS.compressedBytes,
  expandedByteLimit = MANAGED_PLUGIN_LIMITS.expandedBytes,
  fileCountLimit = MANAGED_PLUGIN_LIMITS.files,
  redirectLimit = MANAGED_PLUGIN_LIMITS.redirects,
  timeoutMilliseconds = MANAGED_PLUGIN_LIMITS.timeoutMilliseconds,
  leaseGraceMilliseconds = 2 * 60_000,
  lockWaitMilliseconds = 60_000,
  lockStaleMilliseconds = 5 * 60_000,
  now = () => Date.now(),
  processIsAlive = defaultProcessIsAlive,
} = {}) {
  const root = path.resolve(cleanRequiredText(installRoot, 'install root', 4096))
  const mountsFile = path.resolve(
    cleanRequiredText(extensionsFile, 'extensions file', 4096),
  )
  for (const [value, label] of [
    [compressedByteLimit, 'compressed-byte limit'],
    [expandedByteLimit, 'expanded-byte limit'],
    [fileCountLimit, 'file-count limit'],
    [redirectLimit, 'redirect limit'],
    [timeoutMilliseconds, 'timeout'],
    [lockWaitMilliseconds, 'lock wait'],
    [lockStaleMilliseconds, 'lock stale interval'],
  ]) {
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new Error(`Managed plugin ${label} is invalid.`)
    }
  }
  if (!Number.isSafeInteger(leaseGraceMilliseconds) || leaseGraceMilliseconds < 0) {
    throw new Error('Managed plugin lease grace interval is invalid.')
  }
  if (typeof now !== 'function' || typeof processIsAlive !== 'function') {
    throw new Error('Managed plugin lifecycle clock is invalid.')
  }
  const lockOptions = {
    now,
    processIsAlive,
    waitMilliseconds: lockWaitMilliseconds,
    staleMilliseconds: lockStaleMilliseconds,
  }
  const leaseOptions = { now, processIsAlive, leaseGraceMilliseconds }

  return {
    async install({
      sourceId,
      pluginName,
      version = null,
      archiveURL,
      sha256 = null,
      catalogURL,
      authentication = null,
    }) {
      const expectedSourceID = normalizedSourceID(sourceId)
      const expectedName = cleanRequiredText(pluginName, 'name')
      const expectedVersion = version === undefined || version === null
        ? null : cleanRequiredText(version, 'version', 128)
      const expectedDigest = normalizedDigest(sha256)
      const archive = await downloadArchive({
        archiveURL,
        catalogURL,
        authentication,
        fetchImpl,
        getIdentityToken,
        compressedByteLimit,
        redirectLimit,
        timeoutMilliseconds,
      })
      const actualDigest = crypto.createHash('sha256').update(archive).digest('hex')
      if (expectedDigest && !crypto.timingSafeEqual(
        Buffer.from(actualDigest, 'hex'), Buffer.from(expectedDigest, 'hex'),
      )) {
        throw new Error('Managed plugin archive did not match its expected SHA-256.')
      }
      if (archive.length < 2 || archive[0] !== 0x1f || archive[1] !== 0x8b) {
        throw new Error('Managed plugin archive is not gzip data.')
      }

      let tar
      try {
        tar = zlib.gunzipSync(archive, { maxOutputLength: expandedByteLimit })
      } catch (error) {
        if (error?.code === 'ERR_BUFFER_TOO_LARGE'
            || /larger than|too large|maxOutputLength/i.test(String(error?.message || ''))) {
          throw new Error(`Managed plugin archive expands beyond ${expandedByteLimit} bytes.`)
        }
        throw new Error('Managed plugin archive could not be decompressed.')
      }
      if (tar.byteLength > expandedByteLimit) {
        throw new Error(`Managed plugin archive expands beyond ${expandedByteLimit} bytes.`)
      }
      const entries = parseTar(tar, { expandedByteLimit, fileCountLimit })
      const { rootName, manifest } = inspectPlugin(entries, expectedName, expectedVersion)
      const actualVersion = manifest.version ?? expectedVersion

      const { sourceDirectory, ownerDirectory, versionDirectory } = managedPaths(
        root, expectedSourceID, expectedName, actualVersion, actualDigest,
      )
      const identity = normalizedManagedIdentity({
        installRoot: root,
        sourceId: expectedSourceID,
        pluginName: expectedName,
        version: actualVersion,
        sha256: actualDigest,
        installPath: versionDirectory,
      })
      return withMutationLock(root, lockOptions, () => {
        ensurePrivateDirectory(sourceDirectory)
        ensurePrivateDirectory(ownerDirectory)
        if (fs.existsSync(versionDirectory)) {
          verifyExistingTree(versionDirectory, entries, rootName)
          const lease = createInstallLease(root, identity, now)
          return {
            installPath: versionDirectory,
            sourceId: expectedSourceID,
            pluginName: expectedName,
            version: actualVersion ?? null,
            sha256: actualDigest,
            reused: true,
            leaseToken: lease.token,
          }
        }

        const staging = fs.mkdtempSync(path.join(ownerDirectory, '.staging-'))
        fs.chmodSync(staging, 0o700)
        let lease = null
        try {
          extractEntries(entries, rootName, staging)
          // The host filesystem is the final authority on name collisions. In particular, APFS
          // folds some Unicode names that JavaScript's lowercasing does not, so verify the
          // materialized staging tree before it reaches the atomic rename commit point.
          verifyExistingTree(staging, entries, rootName)
          // The lease becomes durable before publication. A cleanup on another provider lane sees
          // it under the same cross-process lock and cannot erase the path before Swift commits its
          // mount (or returns this exact token to abort the install).
          lease = createInstallLease(root, identity, now)
          try {
            fs.renameSync(staging, versionDirectory)
          } catch (error) {
            if (error?.code !== 'EEXIST' && error?.code !== 'ENOTEMPTY') throw error
            verifyExistingTree(versionDirectory, entries, rootName)
            fs.rmSync(staging, { recursive: true, force: true })
          }
          // Rename is the commit point. The staging directory already has its final owner-only
          // mode; post-commit durability housekeeping must not turn a successful publish into a
          // reported failure that leaves callers believing there is no installed directory.
          try { fs.chmodSync(versionDirectory, 0o700) } catch {}
          directorySync(ownerDirectory)
        } catch (error) {
          if (lease) {
            try { removeInstallLease(lease) } catch {}
          }
          try { fs.rmSync(staging, { recursive: true, force: true }) } catch {}
          throw error
        }
        return {
          installPath: versionDirectory,
          sourceId: expectedSourceID,
          pluginName: expectedName,
          version: actualVersion ?? null,
          sha256: actualDigest,
          reused: false,
          leaseToken: lease.token,
        }
      })
    },

    uninstall(request) {
      const identity = normalizedManagedIdentity({ installRoot: root, ...request })
      const suppliedToken = request.leaseToken === undefined || request.leaseToken === null
        ? null : normalizedLeaseToken(request.leaseToken)
      return withMutationLock(root, lockOptions, () => {
        const leases = readInstallLeases(root)
        const exactLeases = matchingInstallLeases(leases, identity)
        const mounted = isManagedPluginPathMounted({
          extensionsFile: mountsFile,
          installPath: identity.installPath,
        })
        if (suppliedToken) {
          const tokenLease = leases.find((lease) => lease.token === suppliedToken)
          if (tokenLease && !sameManagedIdentity(tokenLease.identity, identity)) {
            throw new Error('Managed plugin lease identity does not match this uninstall.')
          }
          if (tokenLease) removeInstallLease(tokenLease)
          // Finalization and durable unmount can cross in flight. A token already consumed by
          // finalization is idempotent; continue through the mounted and remaining-lease guards
          // instead of stranding an otherwise deletable exact path.
        }
        if (mounted) {
          return {
            status: 'mounted',
            removed: false,
            retryAfterMilliseconds: null,
          }
        }

        let protectedByInstall = false
        let retryAfterMilliseconds = []
        for (const lease of exactLeases) {
          if (lease.token === suppliedToken) continue
          const protection = leaseProtection(lease, leaseOptions)
          if (protection.protected) {
            protectedByInstall = true
            retryAfterMilliseconds.push(protection.retryAfterMilliseconds ?? 1_000)
          } else {
            removeInstallLease(lease)
          }
        }
        if (protectedByInstall) {
          return {
            status: 'protected',
            removed: false,
            retryAfterMilliseconds: Math.max(250, Math.min(...retryAfterMilliseconds)),
          }
        }
        const removed = removeManagedPluginIdentity(identity)
        return {
          status: removed ? 'removed' : 'missing',
          removed,
          retryAfterMilliseconds: null,
        }
      })
    },

    finalize(request) {
      const identity = normalizedManagedIdentity({ installRoot: root, ...request })
      const suppliedToken = normalizedLeaseToken(request.leaseToken)
      return withMutationLock(root, lockOptions, () => {
        if (!isManagedPluginPathMounted({
          extensionsFile: mountsFile,
          installPath: identity.installPath,
        })) {
          throw new Error('Managed plugin install cannot be finalized before its mount is saved.')
        }
        const leases = readInstallLeases(root)
        const tokenLease = leases.find((lease) => lease.token === suppliedToken)
        if (!tokenLease) return false
        if (!sameManagedIdentity(tokenLease.identity, identity)) {
          throw new Error('Managed plugin lease identity does not match this finalization.')
        }
        return removeInstallLease(tokenLease)
      })
    },

    reconcile() {
      return withMutationLock(root, lockOptions, () => reconcileInstallLeases({
        root,
        extensionsFile: mountsFile,
        ...leaseOptions,
      }))
    },
  }
}

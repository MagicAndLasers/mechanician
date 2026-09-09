import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { gzipSync } from 'node:zlib'

import {
  createManagedPluginInstaller,
  describeManagedArchiveError,
  isManagedPluginPathMounted,
  MANAGED_PLUGIN_LIMITS,
  uninstallManagedPlugin,
} from '../src/managed-plugin-installer.mjs'

const CATALOG_URL = 'https://plugins.example/registry.json'
const ARCHIVE_URL = 'https://plugins.example/archives/operations.tar.gz'
const SOURCE_ID = '11111111-1111-4111-8111-111111111111'

test('managed archive failures preserve specific guidance and stay bounded', () => {
  assert.equal(
    describeManagedArchiveError(new Error('Managed plugin archive download timed out.')),
    'Managed plugin archive download timed out.',
  )
  assert.equal(
    describeManagedArchiveError(new Error('x'.repeat(2_000))).length,
    1_000,
  )
  assert.equal(describeManagedArchiveError(null), 'The managed plugin operation failed.')
})

function writeField(header, offset, length, value) {
  const bytes = Buffer.from(value, 'utf8')
  assert.ok(bytes.length <= length, `fixture field is too long: ${value}`)
  bytes.copy(header, offset)
}

function writeOctal(header, offset, length, value) {
  const encoded = value.toString(8).padStart(length - 1, '0')
  writeField(header, offset, length, `${encoded}\0`)
}

function tarHeader({ name, type = 'file', content = Buffer.alloc(0), mode, linkname = '' }) {
  const header = Buffer.alloc(512)
  writeField(header, 0, 100, name)
  writeOctal(header, 100, 8, mode ?? (type === 'directory' ? 0o755 : 0o644))
  writeOctal(header, 108, 8, 0)
  writeOctal(header, 116, 8, 0)
  writeOctal(header, 124, 12, type === 'file' || type === 'pax' ? content.length : 0)
  writeOctal(header, 136, 12, 0)
  header.fill(0x20, 148, 156)
  const typeFlag = {
    file: '0',
    hardlink: '1',
    symlink: '2',
    character: '3',
    block: '4',
    directory: '5',
    fifo: '6',
    pax: 'x',
  }[type]
  assert.ok(typeFlag, `unknown fixture type ${type}`)
  writeField(header, 156, 1, typeFlag)
  writeField(header, 157, 100, linkname)
  writeField(header, 257, 6, 'ustar\0')
  writeField(header, 263, 2, '00')
  let checksum = 0
  for (const byte of header) checksum += byte
  writeField(header, 148, 8, `${checksum.toString(8).padStart(6, '0')}\0 `)
  return header
}

function tarGz(entries) {
  const parts = []
  for (const raw of entries) {
    const content = Buffer.isBuffer(raw.content)
      ? raw.content : Buffer.from(raw.content ?? '', 'utf8')
    const entry = { ...raw, content }
    parts.push(tarHeader(entry))
    if ((entry.type ?? 'file') === 'file' || entry.type === 'pax') {
      parts.push(content)
      const padding = (512 - (content.length % 512)) % 512
      if (padding) parts.push(Buffer.alloc(padding))
    }
  }
  parts.push(Buffer.alloc(1024))
  return gzipSync(Buffer.concat(parts))
}

function paxRecord(key, value) {
  const body = `${key}=${value}\n`
  let length = Buffer.byteLength(body) + 2
  while (true) {
    const record = `${length} ${body}`
    const actual = Buffer.byteLength(record)
    if (actual === length) return record
    length = actual
  }
}

function pluginEntries({
  name = 'operations',
  version = '1.0.0',
  manifest,
  extra = [],
} = {}) {
  return [
    { name: 'operations/', type: 'directory' },
    { name: 'operations/.claude-plugin/', type: 'directory' },
    {
      name: 'operations/.claude-plugin/plugin.json',
      content: manifest ?? JSON.stringify({ name, version }),
    },
    {
      name: 'operations/skills/search/SKILL.md',
      content: '# Search\n',
    },
    ...extra,
  ]
}

function archive(options) {
  return tarGz(pluginEntries(options))
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function temporaryInstallRoot(t) {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-managed-plugin-'))
  t.after(() => fs.rmSync(parent, { recursive: true, force: true }))
  return path.join(parent, 'installed')
}

function headers(values = {}) {
  const normalized = new Map(
    Object.entries(values).map(([key, value]) => [key.toLowerCase(), String(value)]),
  )
  return { get: (name) => normalized.get(String(name).toLowerCase()) ?? null }
}

function byteResponse(bytes, {
  status = 200,
  responseHeaders = {},
} = {}) {
  const bytesBody = Buffer.from(bytes)
  let read = false
  let cancelled = false
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: headers(responseHeaders),
    body: {
      cancel: async () => { cancelled = true },
      getReader: () => ({
        read: async () => {
          if (read) return { done: true }
          read = true
          return { done: false, value: bytesBody }
        },
        cancel: async () => { cancelled = true },
        releaseLock: () => {},
      }),
    },
    wasCancelled: () => cancelled,
  }
}

function streamResponse(chunks, { status = 200, responseHeaders = {} } = {}) {
  let index = 0
  let cancelled = false
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: headers(responseHeaders),
    body: {
      getReader: () => ({
        read: async () => index < chunks.length
          ? { done: false, value: chunks[index++] }
          : { done: true },
        cancel: async () => { cancelled = true },
        releaseLock: () => {},
      }),
    },
    wasCancelled: () => cancelled,
  }
}

function requestFor(bytes, overrides = {}) {
  return {
    sourceId: SOURCE_ID,
    pluginName: 'operations',
    version: '1.0.0',
    archiveURL: ARCHIVE_URL,
    catalogURL: CATALOG_URL,
    sha256: sha256(bytes),
    ...overrides,
  }
}

function uninstallRequest(result, overrides = {}) {
  return {
    sourceId: result.sourceId,
    pluginName: result.pluginName,
    version: result.version,
    sha256: result.sha256,
    installPath: result.installPath,
    leaseToken: result.leaseToken,
    ...overrides,
  }
}

function uninstallStatus(installer, request) {
  return installer.uninstall(request).status
}

function installerFor(root, fetchImpl, options = {}) {
  return createManagedPluginInstaller({
    installRoot: root,
    extensionsFile: path.join(path.dirname(root), 'extensions.json'),
    fetchImpl,
    ...options,
  })
}

function stagingNames(root) {
  if (!fs.existsSync(root)) return []
  const found = []
  const walk = (directory) => {
    for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
      const target = path.join(directory, item.name)
      if (item.name.startsWith('.staging-')) found.push(target)
      if (item.isDirectory()) walk(target)
    }
  }
  walk(root)
  return found
}

function runNodeModule(source) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--input-type=module', '--eval', source], {
      stdio: ['ignore', 'ignore', 'pipe'],
    })
    let errorOutput = ''
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => { errorOutput += chunk })
    child.once('error', reject)
    child.once('exit', (code, signal) => {
      if (code === 0) resolve()
      else reject(new Error(
        `child exited ${code ?? signal}: ${errorOutput.trim()}`,
      ))
    })
  })
}

test('managed install authenticates a same-origin HTTPS archive and publishes owner-only files', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  const calls = []
  const installer = installerFor(root, async (url, options) => {
    calls.push({ url, options })
    return byteResponse(bytes, {
      responseHeaders: { 'content-length': bytes.length },
    })
  }, {
    getIdentityToken: async () => 'identity-token',
  })

  const result = await installer.install(requestFor(bytes, {
    authentication: 'googleIdentity',
  }))

  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, ARCHIVE_URL)
  assert.equal(calls[0].options.method, 'GET')
  assert.equal(calls[0].options.redirect, 'manual')
  assert.equal(calls[0].options.headers.Authorization, 'Bearer identity-token')
  assert.ok(result.installPath.startsWith(`${path.resolve(root)}${path.sep}`))
  assert.equal(result.pluginName, 'operations')
  assert.equal(result.sourceId, SOURCE_ID)
  assert.equal(result.version, '1.0.0')
  assert.equal(result.sha256, sha256(bytes))
  assert.equal(result.reused, false)
  assert.deepEqual(
    JSON.parse(fs.readFileSync(
      path.join(result.installPath, '.claude-plugin', 'plugin.json'), 'utf8',
    )),
    { name: 'operations', version: '1.0.0' },
  )
  for (const target of [
    root,
    path.dirname(path.dirname(result.installPath)),
    path.dirname(result.installPath),
    result.installPath,
    path.join(result.installPath, '.claude-plugin', 'plugin.json'),
  ]) {
    assert.equal(fs.statSync(target).mode & 0o077, 0, `${target} must be owner-only`)
  }
  assert.deepEqual(stagingNames(root), [])
})

test('authentication fails closed and unauthenticated installs never invent a bearer header', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  let calls = 0
  const missing = installerFor(root, async () => {
    calls += 1
    return byteResponse(bytes)
  }, {
    getIdentityToken: async () => null,
  })
  await assert.rejects(
    missing.install(requestFor(bytes, { authentication: 'googleIdentity' })),
    /Google identity is unavailable/i,
  )
  assert.equal(calls, 0)

  let observedHeaders
  const publicInstaller = installerFor(root, async (_url, options) => {
    observedHeaders = options.headers
    return byteResponse(bytes)
  })
  await publicInstaller.install(requestFor(bytes, { authentication: null }))
  assert.equal(observedHeaders.Authorization, undefined)
})

test('archive URLs stay HTTPS and authenticated redirects cannot leak identity', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  let calls = 0
  const installer = installerFor(root, async () => {
    calls += 1
    return byteResponse(bytes)
  })

  for (const badURL of [
    'http://plugins.example/archive.tar.gz',
    'file:///tmp/archive.tar.gz',
    'https://user:secret@plugins.example/archive.tar.gz',
  ]) {
    await assert.rejects(
      installer.install(requestFor(bytes, { archiveURL: badURL })),
      /HTTPS|credentials/i,
    )
  }
  assert.equal(calls, 0)

  let publicHeaders
  await installerFor(root, async (_url, options) => {
    publicHeaders = options.headers
    return byteResponse(bytes)
  }).install(requestFor(bytes, {
    archiveURL: 'https://cdn.example/archive.tar.gz',
  }))
  assert.equal(publicHeaders.Authorization, undefined)

  const redirectCalls = []
  const redirectResponse = byteResponse('', {
    status: 302,
    responseHeaders: { location: 'https://cdn.example/signed/archive.tar.gz' },
  })
  const redirected = installerFor(root, async (url) => {
    redirectCalls.push(url)
    if (redirectCalls.length === 1) return redirectResponse
    return byteResponse(bytes)
  })
  await redirected.install(requestFor(bytes))
  assert.deepEqual(redirectCalls, [
    ARCHIVE_URL,
    'https://cdn.example/signed/archive.tar.gz',
  ])
  assert.equal(redirectResponse.wasCancelled(), true)

  let initialCrossOriginCalls = 0
  const initialCrossOrigin = installerFor(root, async () => {
    initialCrossOriginCalls += 1
    return byteResponse(bytes)
  }, {
    getIdentityToken: async () => 'identity-token',
  })
  await assert.rejects(
    initialCrossOrigin.install(requestFor(bytes, {
      authentication: 'googleIdentity',
      archiveURL: 'https://cdn.example/archive.tar.gz',
    })),
    /Authenticated.*same origin/i,
  )
  assert.equal(initialCrossOriginCalls, 0)

  const authenticatedCalls = []
  const authenticatedRedirect = byteResponse('', {
      status: 307,
      responseHeaders: { location: 'https://attacker.example/archive.tar.gz' },
  })
  const authenticated = installerFor(root, async (url, options) => {
    authenticatedCalls.push({ url, authorization: options.headers.Authorization })
    return authenticatedRedirect
  }, {
    getIdentityToken: async () => 'identity-token',
  })
  await assert.rejects(
    authenticated.install(requestFor(bytes, { authentication: 'googleIdentity' })),
    /Authenticated.*redirect left the signed catalog origin/i,
  )
  assert.deepEqual(authenticatedCalls, [{
    url: ARCHIVE_URL,
    authorization: 'Bearer identity-token',
  }], 'the cross-origin redirect must never be fetched')
  assert.equal(authenticatedRedirect.wasCancelled(), true)
})

test('compressed response bounds cover declared lengths and dishonest chunked bodies', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  const declared = installerFor(root, async () => byteResponse(bytes, {
    responseHeaders: { 'content-length': 101 },
  }), {
    compressedByteLimit: 100,
  })
  await assert.rejects(declared.install(requestFor(bytes)), /exceeds 100 compressed bytes/i)

  const streamedResponse = streamResponse([
    new Uint8Array(60),
    new Uint8Array(60),
  ])
  const streamed = installerFor(root, async () => streamedResponse, {
    compressedByteLimit: 100,
  })
  await assert.rejects(streamed.install(requestFor(bytes)), /exceeds 100 compressed bytes/i)
  assert.equal(streamedResponse.wasCancelled(), true)
  assert.equal(fs.existsSync(root), false, 'a rejected download must publish nothing')

  const unstreamed = installerFor(root, async () => ({
    ok: true,
    status: 200,
    headers: headers(),
    arrayBuffer: async () => bytes,
  }))
  await assert.rejects(
    unstreamed.install(requestFor(bytes)),
    /readable byte stream/i,
  )
})

test('expanded-byte and file-count limits reject gzip bombs and oversized catalogs', async (t) => {
  const bytes = archive()
  const expandedRoot = temporaryInstallRoot(t)
  const expanded = installerFor(expandedRoot, async () => byteResponse(bytes), {
    expandedByteLimit: 1024,
  })
  await assert.rejects(
    expanded.install(requestFor(bytes)),
    /expands beyond 1024 bytes/i,
  )
  assert.equal(fs.existsSync(expandedRoot), false)

  const countRoot = temporaryInstallRoot(t)
  const countLimited = installerFor(countRoot, async () => byteResponse(bytes), {
    fileCountLimit: 3,
  })
  await assert.rejects(
    countLimited.install(requestFor(bytes)),
    /more than 3 entries/i,
  )
  assert.equal(fs.existsSync(countRoot), false)
})

test('provided archive SHA-256 is syntactically validated and enforced before extraction', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  let calls = 0
  const installer = installerFor(root, async () => {
    calls += 1
    return byteResponse(bytes)
  })

  await assert.rejects(
    installer.install(requestFor(bytes, { sha256: 'not-a-digest' })),
    /SHA-256 is invalid/i,
  )
  assert.equal(calls, 0)
  await assert.rejects(
    installer.install(requestFor(bytes, { sha256: '0'.repeat(64) })),
    /did not match its expected SHA-256/i,
  )
  assert.equal(fs.existsSync(root), false)

  const unpinned = await installer.install(requestFor(bytes, { sha256: null }))
  assert.equal(unpinned.sha256, sha256(bytes))
})

test('tar parsing rejects traversal, absolute paths, links, devices, and metadata entries', async (t) => {
  const cases = [
    {
      label: 'parent traversal',
      entry: { name: 'operations/../../outside', content: 'owned' },
      pattern: /path traversal/i,
    },
    {
      label: 'absolute path',
      entry: { name: '/tmp/owned', content: 'owned' },
      pattern: /absolute path/i,
    },
    {
      label: 'symlink',
      entry: { name: 'operations/link', type: 'symlink', linkname: '/tmp/outside' },
      pattern: /unsupported link, device, or metadata/i,
    },
    {
      label: 'hardlink',
      entry: { name: 'operations/hard', type: 'hardlink', linkname: '/tmp/outside' },
      pattern: /unsupported link, device, or metadata/i,
    },
    {
      label: 'device',
      entry: { name: 'operations/device', type: 'character' },
      pattern: /unsupported link, device, or metadata/i,
    },
    {
      label: 'unapplied pax metadata',
      entry: {
        name: 'operations/PaxHeader/payload',
        type: 'pax',
        content: paxRecord('mtime', '1.5'),
      },
      pattern: /unapplied PAX metadata/i,
    },
  ]

  for (const fixture of cases) {
    const root = temporaryInstallRoot(t)
    const bytes = archive({ extra: [fixture.entry] })
    const installer = installerFor(root, async () => byteResponse(bytes))
    await assert.rejects(
      installer.install(requestFor(bytes)),
      fixture.pattern,
      fixture.label,
    )
    assert.equal(fs.existsSync(root), false, `${fixture.label} must publish nothing`)
  }
})

test('benign local PAX metadata is ignored while a PAX traversal override is rejected', async (t) => {
  const benignEntries = pluginEntries()
  benignEntries.splice(2, 0, {
    name: 'operations/.claude-plugin/PaxHeader/plugin.json',
    type: 'pax',
    content: paxRecord('mtime', '1.5')
      + paxRecord('LIBARCHIVE.xattr.com.apple.provenance', 'opaque'),
  })
  const benignBytes = tarGz(benignEntries)
  const benignRoot = temporaryInstallRoot(t)
  const benign = installerFor(benignRoot, async () => byteResponse(benignBytes))
  const installed = await benign.install(requestFor(benignBytes))
  assert.equal(fs.existsSync(
    path.join(installed.installPath, '.claude-plugin', 'plugin.json'),
  ), true)

  const unsafeEntries = pluginEntries()
  unsafeEntries.splice(3, 0,
    {
      name: 'operations/PaxHeader/payload.txt',
      type: 'pax',
      content: paxRecord('path', '../../outside.txt'),
    },
    { name: 'operations/payload.txt', content: 'owned' })
  const unsafeBytes = tarGz(unsafeEntries)
  const unsafeRoot = temporaryInstallRoot(t)
  const unsafe = installerFor(unsafeRoot, async () => byteResponse(unsafeBytes))
  await assert.rejects(
    unsafe.install(requestFor(unsafeBytes)),
    /path traversal/i,
  )
  assert.equal(fs.existsSync(unsafeRoot), false)

  const longPathEntries = pluginEntries()
  longPathEntries.splice(3, 0,
    {
      name: 'operations/PaxHeader/payload.txt',
      type: 'pax',
      content: paxRecord(
        'path',
        `operations/${'a'.repeat(MANAGED_PLUGIN_LIMITS.pathSegmentBytes + 1)}`,
      ),
    },
    { name: 'operations/payload.txt', content: 'owned' })
  const longPathBytes = tarGz(longPathEntries)
  const longPathRoot = temporaryInstallRoot(t)
  const longPathInstaller = installerFor(
    longPathRoot, async () => byteResponse(longPathBytes),
  )
  await assert.rejects(
    longPathInstaller.install(requestFor(longPathBytes)),
    /overlong path/i,
  )
  assert.equal(fs.existsSync(longPathRoot), false)
})

test('exactly one regular root manifest must match catalog name and version', async (t) => {
  const fixtures = [
    {
      label: 'invalid JSON',
      bytes: archive({ manifest: '{bad json' }),
      pattern: /manifest is not valid .*JSON/i,
    },
    {
      label: 'invalid UTF-8',
      bytes: archive({ manifest: Buffer.from([0xff]) }),
      pattern: /manifest is not valid UTF-8 JSON/i,
    },
    {
      label: 'oversized manifest',
      bytes: archive({ manifest: 'x'.repeat(MANAGED_PLUGIN_LIMITS.manifestBytes + 1) }),
      pattern: /manifest exceeds/i,
    },
    {
      label: 'wrong name',
      bytes: archive({ name: 'attacker' }),
      pattern: /manifest name must be "operations"/i,
    },
    {
      label: 'wrong version',
      bytes: archive({ version: '2.0.0' }),
      pattern: /manifest version must be "1.0.0"/i,
    },
    {
      label: 'second root',
      bytes: archive({ extra: [{ name: 'other/payload.txt', content: 'x' }] }),
      pattern: /exactly one top-level plugin directory/i,
    },
    {
      label: 'nested second manifest',
      bytes: archive({
        extra: [{
          name: 'operations/nested/.claude-plugin/plugin.json',
          content: JSON.stringify({ name: 'nested', version: '1.0.0' }),
        }],
      }),
      pattern: /exactly one regular \.claude-plugin\/plugin\.json/i,
    },
    {
      label: 'regular top-level root',
      bytes: tarGz([
        { name: 'operations', content: 'must not be discarded' },
        ...pluginEntries().slice(1),
      ]),
      pattern: /top-level root must be a directory/i,
    },
    {
      label: 'whitespace-only unpinned version',
      bytes: archive({
        manifest: JSON.stringify({ name: 'operations', version: '   ' }),
      }),
      requestOverrides: { version: null },
      pattern: /manifest version is invalid/i,
    },
  ]

  for (const fixture of fixtures) {
    const root = temporaryInstallRoot(t)
    const installer = installerFor(root, async () => byteResponse(fixture.bytes))
    await assert.rejects(
      installer.install(requestFor(fixture.bytes, fixture.requestOverrides)),
      fixture.pattern,
      fixture.label,
    )
    assert.equal(fs.existsSync(root), false, `${fixture.label} must publish nothing`)
  }
})

test('failed updates preserve the prior version and successful updates publish a new atomic path', async (t) => {
  const root = temporaryInstallRoot(t)
  let current = archive({ version: '1.0.0' })
  const installer = installerFor(root, async () => byteResponse(current))
  const first = await installer.install(requestFor(current))
  const firstManifest = path.join(first.installPath, '.claude-plugin', 'plugin.json')
  assert.equal(JSON.parse(fs.readFileSync(firstManifest)).version, '1.0.0')

  const invalid = archive({ name: 'wrong', version: '2.0.0' })
  current = invalid
  await assert.rejects(
    installer.install(requestFor(invalid, { version: '2.0.0' })),
    /manifest name/i,
  )
  assert.equal(JSON.parse(fs.readFileSync(firstManifest)).version, '1.0.0')
  assert.deepEqual(stagingNames(root), [])

  const secondBytes = archive({
    version: '2.0.0',
    extra: [{ name: 'operations/README.md', content: 'complete v2\n' }],
  })
  current = secondBytes
  const second = await installer.install(requestFor(secondBytes, { version: '2.0.0' }))
  assert.notEqual(second.installPath, first.installPath)
  assert.equal(JSON.parse(fs.readFileSync(firstManifest)).version, '1.0.0')
  assert.equal(
    fs.readFileSync(path.join(second.installPath, 'README.md'), 'utf8'),
    'complete v2\n',
  )
  assert.deepEqual(stagingNames(root), [])

  const reused = await installer.install(requestFor(secondBytes, { version: '2.0.0' }))
  assert.equal(reused.installPath, second.installPath)
  assert.equal(reused.reused, true)
})

test('staging verification rejects host-filesystem Unicode name folding', async (t) => {
  const root = temporaryInstallRoot(t)
  const probe = path.join(path.dirname(root), 'folding-probe')
  fs.mkdirSync(path.join(probe, 'σ'), { recursive: true })
  const hostFoldsNames = fs.existsSync(path.join(probe, 'ς'))
  fs.rmSync(probe, { recursive: true, force: true })

  const bytes = archive({
    extra: [
      { name: 'operations/σ/', type: 'directory' },
      { name: 'operations/σ/first.txt', content: 'first' },
      { name: 'operations/ς/', type: 'directory' },
      { name: 'operations/ς/second.txt', content: 'second' },
    ],
  })
  const installer = installerFor(root, async () => byteResponse(bytes))
  if (hostFoldsNames) {
    await assert.rejects(
      installer.install(requestFor(bytes)),
      /does not match its archive/i,
    )
    assert.equal(fs.existsSync(root), true)
    assert.deepEqual(stagingNames(root), [])
  } else {
    const result = await installer.install(requestFor(bytes))
    assert.equal(fs.existsSync(path.join(result.installPath, 'σ', 'first.txt')), true)
    assert.equal(fs.existsSync(path.join(result.installPath, 'ς', 'second.txt')), true)
  }
})

test('content-addressed reuse rejects unsafe permissions and hard-linked files', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  const installer = installerFor(root, async () => byteResponse(bytes))
  const first = await installer.install(requestFor(bytes))
  const manifestPath = path.join(first.installPath, '.claude-plugin', 'plugin.json')

  fs.chmodSync(manifestPath, 0o666)
  await assert.rejects(
    installer.install(requestFor(bytes)),
    /unsafe filesystem permissions/i,
  )
  fs.chmodSync(manifestPath, 0o600)

  const skillPath = path.join(first.installPath, 'skills', 'search', 'SKILL.md')
  const outside = path.join(path.dirname(root), 'same-content.txt')
  fs.writeFileSync(outside, '# Search\n', { mode: 0o600 })
  fs.chmodSync(outside, 0o600)
  fs.unlinkSync(skillPath)
  fs.linkSync(outside, skillPath)
  await assert.rejects(
    installer.install(requestFor(bytes)),
    /does not match its archive/i,
  )
})

test('identical plugins from different sources use isolated install and uninstall paths', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  let fetchCalls = 0
  const installer = installerFor(root, async () => {
    fetchCalls += 1
    return byteResponse(bytes)
  })
  await assert.rejects(
    installer.install(requestFor(bytes, { sourceId: null })),
    /source ID is invalid/i,
  )
  assert.equal(fetchCalls, 0)
  const first = await installer.install(requestFor(bytes))
  const secondSourceID = '22222222-2222-4222-8222-222222222222'
  const second = await installer.install(requestFor(bytes, { sourceId: secondSourceID }))

  assert.notEqual(first.installPath, second.installPath)
  assert.equal(first.sourceId, SOURCE_ID)
  assert.equal(second.sourceId, secondSourceID)
  assert.equal(fs.existsSync(first.installPath), true)
  assert.equal(fs.existsSync(second.installPath), true)
  assert.equal(uninstallStatus(installer, uninstallRequest(first)), 'removed')
  assert.equal(fs.existsSync(first.installPath), false)
  assert.equal(fs.existsSync(second.installPath), true)
})

test('mounted-path deletion guard includes disabled mounts and fails closed on corrupt state', (t) => {
  const root = temporaryInstallRoot(t)
  const extensionsFile = path.join(path.dirname(root), 'extensions.json')
  const active = path.join(root, 'source-a', 'plugin-a', 'v-a')
  const disabled = path.join(root, 'source-b', 'plugin-b', 'v-b')
  fs.writeFileSync(extensionsFile, JSON.stringify({
    plugins: [
      { path: active, enabled: true },
      { path: disabled, enabled: false },
    ],
  }))

  assert.equal(isManagedPluginPathMounted({ extensionsFile, installPath: active }), true)
  assert.equal(isManagedPluginPathMounted({ extensionsFile, installPath: disabled }), true)
  assert.equal(isManagedPluginPathMounted({
    extensionsFile,
    installPath: path.join(root, 'source-c', 'plugin-c', 'v-c'),
  }), false)

  fs.writeFileSync(extensionsFile, '{not-json')
  assert.throws(
    () => isManagedPluginPathMounted({ extensionsFile, installPath: active }),
    /could not be verified/i,
  )
  fs.unlinkSync(extensionsFile)
  assert.equal(isManagedPluginPathMounted({ extensionsFile, installPath: active }), false)
})

test('exact uninstall is idempotent, version-scoped, and refuses broad or linked targets', async (t) => {
  const root = temporaryInstallRoot(t)
  let current = archive({ version: '1.0.0' })
  const installer = installerFor(root, async () => byteResponse(current))
  const first = await installer.install(requestFor(current))
  current = archive({ version: '2.0.0' })
  const second = await installer.install(requestFor(current, { version: '2.0.0' }))

  assert.equal(uninstallStatus(installer, uninstallRequest(first)), 'removed')
  assert.equal(uninstallStatus(installer, uninstallRequest(first)), 'missing')
  assert.equal(fs.existsSync(second.installPath), true)
  assert.throws(
    () => installer.uninstall(uninstallRequest(second, { installPath: root })),
    /identity does not match/i,
  )
  assert.throws(
    () => installer.uninstall(uninstallRequest(second, {
      installPath: path.dirname(second.installPath),
    })),
    /identity does not match/i,
  )
  assert.throws(
    () => installer.uninstall(uninstallRequest(second, {
      installPath: path.join(path.dirname(root), 'outside'),
    })),
    /identity does not match/i,
  )
  const secondSourceDirectory = path.dirname(path.dirname(second.installPath))
  fs.chmodSync(secondSourceDirectory, 0o755)
  assert.throws(
    () => installer.uninstall(uninstallRequest(second)),
    /unsafe filesystem permissions/i,
  )
  assert.equal(fs.existsSync(second.installPath), true)
  fs.chmodSync(secondSourceDirectory, 0o700)

  const secondOwnerDirectory = path.dirname(second.installPath)
  const outside = path.join(path.dirname(root), 'outside-owner')
  fs.renameSync(secondOwnerDirectory, outside)
  fs.symlinkSync(outside, secondOwnerDirectory)
  assert.throws(
    () => uninstallManagedPlugin({
      installRoot: root,
      ...uninstallRequest(second),
    }),
    /real directory/i,
  )
  assert.equal(fs.existsSync(path.join(outside, path.basename(second.installPath))), true)
})

test('install leases block cross-installer cleanup until the exact install is aborted', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  const firstLane = installerFor(root, async () => byteResponse(bytes))
  const secondLane = installerFor(root, async () => byteResponse(bytes))

  const first = await firstLane.install(requestFor(bytes))
  assert.match(
    first.leaseToken,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  )
  const leaseFile = path.join(root, '.leases', `${first.leaseToken}.json`)
  assert.equal(fs.existsSync(leaseFile), true)
  assert.equal(fs.statSync(leaseFile).mode & 0o077, 0)
  const leaseRecord = JSON.parse(fs.readFileSync(leaseFile, 'utf8'))
  assert.ok(Number.isSafeInteger(leaseRecord.createdAt))
  assert.deepEqual(
    { ...leaseRecord, createdAt: '<timestamp>' },
    {
      token: first.leaseToken,
      sourceId: first.sourceId,
      pluginName: first.pluginName,
      version: first.version,
      sha256: first.sha256,
      installPath: first.installPath,
      createdAt: '<timestamp>',
      ownerPid: process.pid,
      clientPid: process.ppid,
    },
  )

  assert.equal(
    uninstallStatus(secondLane, uninstallRequest(first, { leaseToken: null })),
    'protected',
    'an ordinary cleanup must not erase an install before its mount commit',
  )
  assert.equal(fs.existsSync(first.installPath), true)
  assert.equal(
    uninstallStatus(secondLane, uninstallRequest(first, {
      leaseToken: crypto.randomUUID(),
    })),
    'protected',
    'an already-consumed or stale token falls through to the remaining live-lease guard',
  )
  assert.equal(fs.existsSync(first.installPath), true)

  const secondSourceID = '22222222-2222-4222-8222-222222222222'
  const second = await secondLane.install(requestFor(bytes, { sourceId: secondSourceID }))
  assert.throws(
    () => firstLane.uninstall(uninstallRequest(first, {
      leaseToken: second.leaseToken,
    })),
    /lease identity does not match/i,
  )
  assert.equal(fs.existsSync(first.installPath), true)
  assert.equal(fs.existsSync(second.installPath), true)

  assert.equal(uninstallStatus(secondLane, uninstallRequest(first)), 'removed')
  assert.equal(fs.existsSync(first.installPath), false)
  assert.equal(fs.existsSync(second.installPath), true)
  assert.equal(uninstallStatus(firstLane, uninstallRequest(second)), 'removed')
})

test('independent installers serialize reuse and retain every outstanding lease', async (t) => {
  const root = temporaryInstallRoot(t)
  const bytes = archive()
  const firstLane = installerFor(root, async () => byteResponse(bytes))
  const secondLane = installerFor(root, async () => byteResponse(bytes))

  const [first, second] = await Promise.all([
    firstLane.install(requestFor(bytes)),
    secondLane.install(requestFor(bytes)),
  ])
  assert.equal(first.installPath, second.installPath)
  assert.notEqual(first.leaseToken, second.leaseToken)
  assert.deepEqual(new Set([first.reused, second.reused]), new Set([false, true]))

  assert.equal(
    uninstallStatus(firstLane, uninstallRequest(first, { leaseToken: null })),
    'protected',
  )
  assert.equal(
    uninstallStatus(firstLane, uninstallRequest(first)),
    'protected',
    'aborting one lane must retain the path while the other lane has a live lease',
  )
  assert.equal(fs.existsSync(first.installPath), true)
  assert.equal(uninstallStatus(secondLane, uninstallRequest(second)), 'removed')
  assert.equal(fs.existsSync(first.installPath), false)
})

test('multiple processes safely retire one stale mutation lock', async (t) => {
  const root = temporaryInstallRoot(t)
  const extensionsFile = path.join(path.dirname(root), 'extensions.json')
  fs.mkdirSync(root, { recursive: true, mode: 0o700 })
  fs.chmodSync(root, 0o700)
  fs.writeFileSync(extensionsFile, JSON.stringify({ plugins: [] }))

  const staleToken = crypto.randomUUID().toLowerCase()
  const candidateName = `.mutation-candidate-${staleToken}`
  const candidate = path.join(root, candidateName)
  fs.writeFileSync(candidate, JSON.stringify({
    token: staleToken,
    pid: 2_147_483_647,
    createdAt: 0,
    candidateName,
  }), { mode: 0o600 })
  fs.chmodSync(candidate, 0o600)
  fs.linkSync(candidate, path.join(root, '.mutation-lock'))

  const moduleURL = new URL('../src/managed-plugin-installer.mjs', import.meta.url).href
  const synchronizationDirectory = path.join(path.dirname(root), 'lock-race')
  const barrier = path.join(synchronizationDirectory, 'go')
  fs.mkdirSync(synchronizationDirectory, { mode: 0o700 })
  const childCount = 32
  const children = Array.from({ length: childCount }, (_, index) => runNodeModule(`
    import fs from 'node:fs'
    import path from 'node:path'
    import { createManagedPluginInstaller } from ${JSON.stringify(moduleURL)}
    fs.writeFileSync(path.join(
      ${JSON.stringify(synchronizationDirectory)}, ${JSON.stringify(`ready-`)} + ${index}
    ), '')
    const word = new Int32Array(new SharedArrayBuffer(4))
    while (!fs.existsSync(${JSON.stringify(barrier)})) Atomics.wait(word, 0, 0, 5)
    const installer = createManagedPluginInstaller({
      installRoot: ${JSON.stringify(root)},
      extensionsFile: ${JSON.stringify(extensionsFile)},
      lockWaitMilliseconds: 10000,
      lockStaleMilliseconds: 1,
    })
    installer.reconcile()
  `))
  let readyCount = 0
  for (let attempt = 0; attempt < 2_000; attempt += 1) {
    readyCount = fs.readdirSync(synchronizationDirectory).filter(
      (name) => name.startsWith('ready-'),
    ).length
    if (readyCount === childCount) break
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  fs.writeFileSync(barrier, '')
  assert.equal(readyCount, childCount, 'every child must reach the contention barrier')
  await Promise.all(children)

  assert.equal(fs.existsSync(path.join(root, '.mutation-lock')), false)
  assert.deepEqual(
    fs.readdirSync(root).filter((name) => name.startsWith('.mutation-candidate-')),
    [],
  )
})

test('finalization requires a durable exact mount and mounted plugins cannot be deleted', async (t) => {
  const root = temporaryInstallRoot(t)
  const extensionsFile = path.join(path.dirname(root), 'extensions.json')
  const bytes = archive()
  const installer = installerFor(root, async () => byteResponse(bytes))
  const installed = await installer.install(requestFor(bytes))

  assert.throws(
    () => installer.finalize(uninstallRequest(installed)),
    /cannot be finalized before its mount is saved/i,
  )
  assert.equal(fs.existsSync(installed.installPath), true)

  fs.writeFileSync(extensionsFile, JSON.stringify({
    plugins: [{ path: installed.installPath, enabled: true }],
  }))
  assert.equal(installer.finalize(uninstallRequest(installed)), true)
  assert.equal(installer.finalize(uninstallRequest(installed)), false)
  assert.equal(
    uninstallStatus(installer, uninstallRequest(installed, { leaseToken: null })),
    'mounted',
  )
  assert.equal(fs.existsSync(installed.installPath), true)

  fs.writeFileSync(extensionsFile, JSON.stringify({
    plugins: [{ path: installed.installPath, enabled: false }],
  }))
  assert.equal(
    uninstallStatus(installer, uninstallRequest(installed, { leaseToken: null })),
    'mounted',
    'disabled mounts remain durable mounts and must not be deleted',
  )
  assert.equal(fs.existsSync(installed.installPath), true)

  fs.writeFileSync(extensionsFile, JSON.stringify({ plugins: [] }))
  assert.equal(
    uninstallStatus(installer, uninstallRequest(installed, { leaseToken: null })),
    'removed',
  )
  assert.equal(fs.existsSync(installed.installPath), false)
})

test('reconciliation preserves live leases, reclaims expired orphans, and keeps mounts', async (t) => {
  const root = temporaryInstallRoot(t)
  const extensionsFile = path.join(path.dirname(root), 'extensions.json')
  const bytes = archive()
  let clock = 10_000
  let ownerIsAlive = true
  const installer = installerFor(root, async () => byteResponse(bytes), {
    now: () => clock,
    processIsAlive: () => ownerIsAlive,
    leaseGraceMilliseconds: 100,
  })

  const orphan = await installer.install(requestFor(bytes))
  assert.deepEqual(installer.reconcile(), {
    removedPaths: 0,
    removedLeases: 0,
    retryAfterMilliseconds: null,
  })
  assert.equal(fs.existsSync(orphan.installPath), true)

  ownerIsAlive = false
  clock += 50
  assert.deepEqual(installer.reconcile(), {
    removedPaths: 0,
    removedLeases: 0,
    retryAfterMilliseconds: 50,
  })
  assert.equal(fs.existsSync(orphan.installPath), true)

  clock += 51
  assert.deepEqual(installer.reconcile(), {
    removedPaths: 1,
    removedLeases: 1,
    retryAfterMilliseconds: null,
  })
  assert.equal(fs.existsSync(orphan.installPath), false)

  const mounted = await installer.install(requestFor(bytes, {
    sourceId: '22222222-2222-4222-8222-222222222222',
  }))
  fs.writeFileSync(extensionsFile, JSON.stringify({
    plugins: [{ path: mounted.installPath, enabled: false }],
  }))
  clock += 101
  assert.deepEqual(installer.reconcile(), {
    removedPaths: 0,
    removedLeases: 1,
    retryAfterMilliseconds: null,
  })
  assert.equal(fs.existsSync(mounted.installPath), true)
  assert.equal(
    uninstallStatus(installer, uninstallRequest(mounted, { leaseToken: null })),
    'mounted',
  )

  fs.writeFileSync(extensionsFile, JSON.stringify({ plugins: [] }))
  assert.equal(
    uninstallStatus(installer, uninstallRequest(mounted, { leaseToken: null })),
    'removed',
  )
})

import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '../..')
const publisher = path.join(repo, 'scripts/publish-update-artifacts.sh')

function appcast({ daily = false } = {}) {
  const candidateChannel = daily ? '      <sparkle:channel>daily</sparkle:channel>\n' : ''
  const oldStable = daily
    ? `    <item>
      <sparkle:version>238</sparkle:version>
      <sparkle:shortVersionString>0.26.23</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="https://example.invalid/Mechanician-0.26.23.zip" length="10" sparkle:edSignature="old"/>
    </item>`
    : ''
  return `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Mechanician</title>
    <item>
      <sparkle:version>239</sparkle:version>
      <sparkle:shortVersionString>0.26.24</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
${candidateChannel}      <enclosure url="https://example.invalid/Mechanician-0.26.24.zip" length="10" sparkle:edSignature="new"/>
    </item>
${oldStable}
    <item>
      <sparkle:version>54</sparkle:version>
      <sparkle:shortVersionString>0.7.31</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="https://example.invalid/Mechanician-0.7.31.zip" length="10" sparkle:edSignature="legacy"/>
    </item>
  </channel>
</rss>
`
}

function createFixture(t, { daily = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-artifact-publisher-'))
  const bin = path.join(root, 'bin')
  const statePath = path.join(root, 'state.json')
  const logPath = path.join(root, 'gcloud.log')
  const signLog = path.join(root, 'sign.log')
  fs.mkdirSync(bin)
  fs.symlinkSync(process.execPath, path.join(bin, 'node'))
  fs.writeFileSync(logPath, '')
  fs.writeFileSync(signLog, '')

  const initial = { nextGeneration: 100, objects: {} }
  fs.writeFileSync(statePath, JSON.stringify(initial))

  const fakeGcloud = `#!/usr/bin/env node
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const statePath = process.env.FAKE_GCLOUD_STATE
const logPath = process.env.FAKE_GCLOUD_LOG
const bucket = process.env.MECHANICIAN_UPDATE_BUCKET
const state = JSON.parse(fs.readFileSync(statePath, 'utf8'))
fs.appendFileSync(logPath, JSON.stringify(args) + '\\n')

function save() { fs.writeFileSync(statePath, JSON.stringify(state)) }
function objectName(url) {
  const prefix = bucket + '/'
  if (!url.startsWith(prefix)) process.exit(65)
  return url.slice(prefix.length).split('#', 1)[0]
}
function crc(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('base64').slice(0, 12)
}
function decode(record) { return Buffer.from(record.bytes, 'base64') }
function makeRecord(bytes, options = {}) {
  return {
    bytes: bytes.toString('base64'),
    generation: String(state.nextGeneration++),
    crc: crc(bytes),
    cacheControl: options.cacheControl ?? '',
    metadata: options.metadata ?? {},
  }
}

if (args[0] !== 'storage') process.exit(64)
if (args[1] === 'objects' && args[2] === 'describe') {
  const requested = args[3]
  const name = objectName(requested)
  const record = state.objects[name]
  if (!record) process.exit(1)
  if (requested.includes('#') && requested.slice(requested.lastIndexOf('#') + 1) !== record.generation) {
    process.exit(1)
  }
  const format = args.find(argument => argument.startsWith('--format='))
  if (format?.startsWith('--format=json(')) {
    if (!format.includes('custom_fields') || format.includes('custom_metadata')) process.exit(69)
    process.stdout.write(JSON.stringify({
      generation: record.generation,
      size: String(decode(record).length),
      crc32c_hash: record.crc,
      custom_fields: record.metadata,
      cache_control: record.cacheControl,
      name,
    }) + '\\n')
    process.exit(0)
  }
  const columns = [
    record.generation,
    String(decode(record).length),
    record.crc,
    record.metadata['mechanician-version'] ?? '',
    record.metadata['mechanician-build'] ?? '',
    record.metadata['mechanician-source-generation'] ?? '',
    record.metadata['mechanician-source-crc32c'] ?? '',
    record.cacheControl,
    name,
  ]
  process.stdout.write(columns.join('\\t') + '\\n')
  process.exit(0)
}

if (args[1] === 'cp') {
  const positional = args.slice(2).filter(argument => !argument.startsWith('--'))
  if (positional.length !== 2) process.exit(66)
  const [source, destination] = positional
  const sourceRemote = source.startsWith('gs://')
  const destinationRemote = destination.startsWith('gs://')

  if (sourceRemote && !destinationRemote) {
    const record = state.objects[objectName(source)]
    if (!record) process.exit(1)
    fs.mkdirSync(path.dirname(destination), { recursive: true })
    fs.writeFileSync(destination, decode(record))
    process.exit(0)
  }

  const generationFlag = args.find(argument => argument.startsWith('--if-generation-match='))
  const expectedGeneration = generationFlag?.slice('--if-generation-match='.length)
  if (!destinationRemote || expectedGeneration === undefined) process.exit(67)
  const destinationName = objectName(destination)
  const existing = state.objects[destinationName]
  const actualGeneration = existing?.generation ?? '0'
  if (expectedGeneration !== actualGeneration) process.exit(1)

  let bytes
  if (sourceRemote) {
    const sourceRecord = state.objects[objectName(source)]
    if (!sourceRecord) process.exit(1)
    const sourceGeneration = source.includes('#') ? source.slice(source.lastIndexOf('#') + 1) : null
    if (sourceGeneration !== null && sourceGeneration !== sourceRecord.generation) process.exit(1)
    bytes = decode(sourceRecord)
  } else {
    if (!fs.existsSync(source)) process.exit(1)
    bytes = fs.readFileSync(source)
  }
  const metadataArgument = args.find(argument => argument.startsWith('--custom-metadata='))
  const metadata = {}
  if (metadataArgument) {
    for (const pair of metadataArgument.slice('--custom-metadata='.length).split(',')) {
      const separator = pair.indexOf('=')
      metadata[pair.slice(0, separator)] = pair.slice(separator + 1)
    }
  }
  const cacheArgument = args.find(argument => argument.startsWith('--cache-control='))
  state.objects[destinationName] = makeRecord(bytes, {
    metadata,
    cacheControl: cacheArgument?.slice('--cache-control='.length),
  })
  save()
  process.exit(0)
}
process.exit(68)
`

  const fakeSign = `#!/usr/bin/env node
import fs from 'node:fs'
fs.appendFileSync(process.env.FAKE_SIGN_LOG, JSON.stringify(process.argv.slice(2)) + '\\n')
process.exit(process.env.FAKE_BAD_FEED_SIGNATURE === '1' ? 1 : 0)
`
  const gcloudPath = path.join(bin, 'gcloud')
  const signPath = path.join(bin, 'sign_update')
  fs.writeFileSync(gcloudPath, fakeGcloud, { mode: 0o755 })
  fs.writeFileSync(signPath, fakeSign, { mode: 0o755 })

  function state() {
    return JSON.parse(fs.readFileSync(statePath, 'utf8'))
  }

  function writeObject(name, bytes, { metadata = {}, cacheControl = '' } = {}) {
    const current = state()
    const contents = Buffer.from(bytes)
    current.objects[name] = {
      bytes: contents.toString('base64'),
      generation: String(current.nextGeneration++),
      crc: crypto.createHash('sha256').update(contents).digest('base64').slice(0, 12),
      cacheControl,
      metadata,
    }
    fs.writeFileSync(statePath, JSON.stringify(current))
  }

  function readObject(name) {
    return Buffer.from(state().objects[name].bytes, 'base64')
  }

  function calls() {
    return fs.readFileSync(logPath, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse)
  }

  function run(args, extraEnv = {}) {
    return spawnSync(publisher, args, {
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        MECHANICIAN_UPDATE_BUCKET: 'gs://test-updates',
        MECHANICIAN_ARTIFACT_NAME: 'Mechanician',
        MECHANICIAN_GCLOUD: gcloudPath,
        MECHANICIAN_SIGN_UPDATE: signPath,
        MECHANICIAN_XMLLINT: '/usr/bin/xmllint',
        MECHANICIAN_XSLTPROC: '/usr/bin/xsltproc',
        FAKE_GCLOUD_STATE: statePath,
        FAKE_GCLOUD_LOG: logPath,
        FAKE_SIGN_LOG: signLog,
        ...extraEnv,
      },
    })
  }

  writeObject('appcast.xml', Buffer.from(appcast({ daily })))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return { root, state, writeObject, readObject, calls, run, signLog }
}

test('immutable upload is create-only, exactly idempotent, and rejects different existing bytes', (t) => {
  const fixture = createFixture(t)
  const local = path.join(fixture.root, 'Mechanician-0.26.24.zip')
  fs.writeFileSync(local, 'candidate-bytes')

  const created = fixture.run(['upload-immutable', local, 'Mechanician-0.26.24.zip'])
  assert.equal(created.status, 0, created.stderr)
  assert.deepEqual(fixture.readObject('Mechanician-0.26.24.zip'), Buffer.from('candidate-bytes'))
  const create = fixture.calls().find(call =>
    call[0] === 'storage' && call[1] === 'cp' && call.at(-1) === 'gs://test-updates/Mechanician-0.26.24.zip')
  assert.ok(create?.includes('--if-generation-match=0'))

  const repeated = fixture.run(['upload-immutable', local, 'Mechanician-0.26.24.zip'])
  assert.equal(repeated.status, 0, repeated.stderr)
  assert.match(repeated.stdout, /exact bytes/)
  const remoteWrites = fixture.calls().filter(call =>
    call[0] === 'storage' && call[1] === 'cp' && call.at(-1)?.startsWith('gs://'))
  assert.equal(remoteWrites.length, 1)

  fs.writeFileSync(local, 'different-bytes')
  const mismatch = fixture.run(['upload-immutable', local, 'Mechanician-0.26.24.zip'])
  assert.notEqual(mismatch.status, 0)
  assert.match(mismatch.stderr, /different bytes/)
  assert.deepEqual(fixture.readObject('Mechanician-0.26.24.zip'), Buffer.from('candidate-bytes'))
})

test('Stable alias reconciliation is signed-feed-gated, generation-safe, and idempotent', (t) => {
  const fixture = createFixture(t)
  fixture.writeObject('Mechanician-0.26.24.zip', Buffer.from('new-zip'))
  fixture.writeObject('Mechanician-0.26.24.dmg', Buffer.from('new-dmg'))
  fixture.writeObject('Mechanician-latest.zip', Buffer.from('old-zip'))
  fixture.writeObject('Mechanician-latest.dmg', Buffer.from('old-dmg'))

  const result = fixture.run(['reconcile-stable-aliases', '0.26.24', '239'])
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(fixture.readObject('Mechanician-latest.zip'), Buffer.from('new-zip'))
  assert.deepEqual(fixture.readObject('Mechanician-latest.dmg'), Buffer.from('new-dmg'))
  for (const alias of ['Mechanician-latest.zip', 'Mechanician-latest.dmg']) {
    const record = fixture.state().objects[alias]
    const source = fixture.state().objects[alias.endsWith('.zip')
      ? 'Mechanician-0.26.24.zip'
      : 'Mechanician-0.26.24.dmg']
    assert.equal(record.cacheControl, 'no-cache, max-age=0')
    assert.deepEqual(record.metadata, {
      'mechanician-version': '0.26.24',
      'mechanician-build': '239',
      'mechanician-source-generation': source.generation,
      'mechanician-source-crc32c': source.crc,
    })
  }
  const aliasWrites = () => fixture.calls().filter(call =>
    call[0] === 'storage' && call[1] === 'cp' &&
    call.at(-1)?.includes('Mechanician-latest.'))
  assert.equal(aliasWrites().length, 2)
  assert.ok(aliasWrites().every(call => call.some(argument => argument.startsWith('--if-generation-match='))))
  assert.ok(aliasWrites().every(call => {
    const source = call.find(argument => argument.startsWith('gs://test-updates/Mechanician-0.26.24.'))
    const extension = call.at(-1).split('.').at(-1)
    return source === `gs://test-updates/Mechanician-0.26.24.${extension}#${fixture.state().objects[`Mechanician-0.26.24.${extension}`].generation}`
  }))

  const repeated = fixture.run(['reconcile-stable-aliases', '0.26.24', '239'])
  assert.equal(repeated.status, 0, repeated.stderr)
  assert.equal(aliasWrites().length, 2)
  const signCalls = fs.readFileSync(fixture.signLog, 'utf8').trim().split('\n').filter(Boolean)
  assert.ok(signCalls.length >= 3)
})

test('Stable alias reconciliation rejects a source generation other than the validated one', (t) => {
  const fixture = createFixture(t)
  fixture.writeObject('Mechanician-0.26.24.zip', Buffer.from('new-zip'))
  fixture.writeObject('Mechanician-0.26.24.dmg', Buffer.from('new-dmg'))
  const snapshot = fixture.state().objects
  const zip = snapshot['Mechanician-0.26.24.zip']
  const dmg = snapshot['Mechanician-0.26.24.dmg']
  fixture.writeObject('Mechanician-0.26.24.zip', Buffer.from('replaced-after-validation'))

  const result = fixture.run([
    'reconcile-stable-aliases', '0.26.24', '239',
    zip.generation, zip.crc, dmg.generation, dmg.crc,
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /no longer matches the validated generation/)
  assert.equal(fixture.state().objects['Mechanician-latest.dmg'], undefined)
  assert.equal(fixture.state().objects['Mechanician-latest.zip'], undefined)
})

test('Daily feed item cannot move Stable aliases before promotion CAS', (t) => {
  const fixture = createFixture(t, { daily: true })
  fixture.writeObject('Mechanician-0.26.24.zip', Buffer.from('daily-zip'))
  fixture.writeObject('Mechanician-0.26.24.dmg', Buffer.from('daily-dmg'))
  fixture.writeObject('Mechanician-latest.zip', Buffer.from('stable-zip'))
  fixture.writeObject('Mechanician-latest.dmg', Buffer.from('stable-dmg'))

  const result = fixture.run(['reconcile-stable-aliases', '0.26.24', '239'])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /aliases remain unchanged/)
  assert.deepEqual(fixture.readObject('Mechanician-latest.zip'), Buffer.from('stable-zip'))
  assert.deepEqual(fixture.readObject('Mechanician-latest.dmg'), Buffer.from('stable-dmg'))
  assert.equal(fixture.calls().filter(call => call.at(-1)?.includes('Mechanician-latest.')).length, 0)
})

test('Stable alias reconciliation refuses invalid feed signatures and newer alias rollback', (t) => {
  const fixture = createFixture(t)
  fixture.writeObject('Mechanician-0.26.24.zip', Buffer.from('new-zip'))
  fixture.writeObject('Mechanician-0.26.24.dmg', Buffer.from('new-dmg'))
  fixture.writeObject('Mechanician-latest.zip', Buffer.from('future-zip'), {
    metadata: { 'mechanician-build': '240' },
  })
  fixture.writeObject('Mechanician-latest.dmg', Buffer.from('future-dmg'), {
    metadata: { 'mechanician-build': '240' },
  })

  let result = fixture.run(['reconcile-stable-aliases', '0.26.24', '239'], {
    FAKE_BAD_FEED_SIGNATURE: '1',
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /signature is invalid/)
  assert.deepEqual(fixture.readObject('Mechanician-latest.dmg'), Buffer.from('future-dmg'))

  result = fixture.run(['reconcile-stable-aliases', '0.26.24', '239'])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /newer build 240/)
  assert.deepEqual(fixture.readObject('Mechanician-latest.dmg'), Buffer.from('future-dmg'))
  assert.deepEqual(fixture.readObject('Mechanician-latest.zip'), Buffer.from('future-zip'))
})

test('Stable alias reconciliation repairs an exact alias with stale cache policy', (t) => {
  const fixture = createFixture(t)
  fixture.writeObject('Mechanician-0.26.24.zip', Buffer.from('new-zip'))
  fixture.writeObject('Mechanician-0.26.24.dmg', Buffer.from('new-dmg'))
  for (const extension of ['zip', 'dmg']) {
    const source = fixture.state().objects[`Mechanician-0.26.24.${extension}`]
    fixture.writeObject(`Mechanician-latest.${extension}`, Buffer.from(`new-${extension}`), {
      metadata: {
        'mechanician-version': '0.26.24',
        'mechanician-build': '239',
        'mechanician-source-generation': source.generation,
        'mechanician-source-crc32c': source.crc,
      },
      cacheControl: 'public, max-age=3600',
    })
  }

  const result = fixture.run(['reconcile-stable-aliases', '0.26.24', '239'])
  assert.equal(result.status, 0, result.stderr)
  assert.equal(fixture.state().objects['Mechanician-latest.zip'].cacheControl, 'no-cache, max-age=0')
  assert.equal(fixture.state().objects['Mechanician-latest.dmg'].cacheControl, 'no-cache, max-age=0')
})

test('release transaction wires Daily DMG retention, immutable publication, and post-CAS aliases', () => {
  const source = fs.readFileSync(path.join(repo, 'scripts/release.sh'), 'utf8')
  assert.match(source, /daily channel: retaining a promotable DMG without touching Stable aliases/)
  assert.match(
    source,
    /CHECKSUM_ARTIFACTS=\("\$ZIP" "\$DSYM_ZIP" "\$DMG" "\$PKG" "\$PROVENANCE" "\$SBOM"\)/,
  )
  for (const invocation of [
    'upload-immutable "$ZIP" "$VERSIONED_ZIP"',
    'upload-immutable "$DMG" "$VERSIONED_DMG"',
    'upload-immutable "$CHECKSUMS" "$(basename "$CHECKSUMS")"',
    'upload-immutable "$PROVENANCE" "$(basename "$PROVENANCE")"',
    'upload-immutable "$delta" "$(basename "$delta")"',
  ]) {
    assert.ok(source.includes(invocation), invocation)
  }
  const publishOffset = source.indexOf('"$UPDATE_HISTORY" publish "$STAGE"')
  const aliasOffset = source.lastIndexOf('"$ARTIFACT_PUBLISHER" reconcile-stable-aliases "$VERSION" "$NEW_BUILD"')
  assert.ok(publishOffset >= 0 && aliasOffset > publishOffset)
  assert.match(source, /PREV_CHANNEL_VERSION=.*\.appcast-before-items\.tsv/s)
  assert.match(source, /--channel-leader/)
  assert.match(source, /refs\/tags\/\$PREV_CHANNEL_TAG\^\{commit\}/)
  assert.match(source, /staged live appcast signature is invalid/)
  assert.match(source, /PUBLISHED_RESUME="stable"/)
  assert.match(source, /appcast already published; skipping release-note and appcast regeneration/)
  assert.match(source, /\[ -n "\$PUBLISHED_RESUME" \] \|\| "\$UPDATE_HISTORY" verify-remote "\$STAGE"/)
  assert.match(source, /reusing exact cached ZIP/)
  assert.match(source, /cached release ZIP app identity differs from the release app/)
  assert.match(source, /reusing exact signed\/notarized versioned DMG/)
  assert.match(source, /verify_cached_dmg_app "\$DMG" "\$APP" "\$PROVENANCE_IN_APP"/)
  assert.match(source, /reusing exact cached dSYM archive/)
  assert.match(source, /object-facts "\$VERSIONED_ZIP"/)
  assert.match(source, /object-facts "\$VERSIONED_DMG"/)
})

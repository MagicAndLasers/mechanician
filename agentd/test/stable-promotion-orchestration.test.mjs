import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const sourceRepo = path.resolve(here, '../..')
const promotionSource = path.join(sourceRepo, 'scripts/promote-daily.sh')

const version = '0.26.24'
const build = '239'
const toolingCommit = 'a'.repeat(40)
const releaseCommit = 'b'.repeat(40)
const sourceCommit = 'c'.repeat(40)
const releaseDiff = 'fixture version-only release diff\n'
const sourceDiffSHA256 = crypto.createHash('sha256').update(releaseDiff).digest('hex')

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

function executable(filename, source) {
  fs.writeFileSync(filename, source, { mode: 0o755 })
}

function nodeExecutable(filename, source) {
  if (filename.endsWith('.sh')) {
    fs.writeFileSync(`${filename}.mjs`, source)
    executable(filename, `#!/bin/sh\nexec node "$0.mjs" "$@"\n`)
  } else {
    executable(filename, `#!/usr/bin/env node\n${source}`)
  }
}

function createFixture(t, {
  state = 'promotion-required',
  failCAS = false,
  failAttestation = false,
} = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-promotion-orchestration-'))
  const repo = path.join(root, 'repo')
  const scripts = path.join(repo, 'scripts')
  const bin = path.join(root, 'bin')
  const bucket = path.join(root, 'bucket')
  const stage = path.join(repo, 'build', 'stable-promotion')
  const appTemplate = path.join(root, 'app-template', 'Mechanician.app')
  const dmgMount = path.join(root, 'mounted-dmg')
  const log = path.join(root, 'events.log')
  const attestation = path.join(root, 'attestation.json')
  fs.mkdirSync(scripts, { recursive: true })
  fs.mkdirSync(bin)
  fs.mkdirSync(bucket)
  fs.mkdirSync(path.join(appTemplate, 'Contents/Resources'), { recursive: true })
  fs.mkdirSync(path.join(dmgMount, 'Mechanician.app/Contents/Resources'), { recursive: true })
  fs.copyFileSync(promotionSource, path.join(scripts, 'promote-daily.sh'))
  fs.chmodSync(path.join(scripts, 'promote-daily.sh'), 0o755)
  fs.writeFileSync(attestation, JSON.stringify({ fixture: true }))

  const zipObject = `Mechanician-${version}.zip`
  const dmgObject = `Mechanician-${version}.dmg`
  const checksumObject = `Mechanician-${version}-${build}-SHA256SUMS.txt`
  const provenanceObject = `Mechanician-${version}-${build}-provenance.json`
  const receiptObject = `Mechanician-${version}-${build}-stable-promotion-authorization.json`
  const zipBytes = Buffer.from('exact immutable Daily ZIP bytes')
  const dmgBytes = Buffer.from('exact immutable Daily DMG bytes')
  const provenanceBytes = Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    application: 'Mechanician',
    version,
    build,
    dogfood: false,
    bundleIdentifier: 'ai.mechanician.app',
    sourceCommit,
    sourceDiffSHA256,
  }, null, 2)}\n`)
  const checksums = Buffer.from(
    `${sha256(zipBytes)}  ${zipBytes.length}  ${zipObject}\n`
    + `${sha256(dmgBytes)}  ${dmgBytes.length}  ${dmgObject}\n`,
  )
  const initialFeed = Buffer.from(`signed feed before ${state}\n`)
  const promotedFeed = Buffer.from(`signed Stable feed for ${version} (${build})\n`)
  const initialZipAlias = Buffer.from('older stable ZIP alias')
  const initialDMGAlias = Buffer.from('older stable DMG alias')
  fs.writeFileSync(path.join(bucket, zipObject), zipBytes)
  fs.writeFileSync(path.join(bucket, dmgObject), dmgBytes)
  fs.writeFileSync(path.join(bucket, checksumObject), checksums)
  fs.writeFileSync(path.join(bucket, provenanceObject), provenanceBytes)
  fs.writeFileSync(path.join(bucket, 'appcast.xml'), initialFeed)
  fs.writeFileSync(path.join(bucket, 'Mechanician-latest.zip'), initialZipAlias)
  fs.writeFileSync(path.join(bucket, 'Mechanician-latest.dmg'), initialDMGAlias)

  const info = `${JSON.stringify({
    CFBundleShortVersionString: version,
    CFBundleVersion: build,
  })}\n`
  for (const app of [appTemplate, path.join(dmgMount, 'Mechanician.app')]) {
    fs.writeFileSync(path.join(app, 'Contents/Info.plist'), info)
    fs.writeFileSync(path.join(app, 'Contents/Resources/BuildProvenance.json'), provenanceBytes)
  }

  const baseEnvironment = {
    FIXTURE_LOG: log,
    FIXTURE_BUCKET_ROOT: bucket,
    FIXTURE_STAGE: stage,
    FIXTURE_APP_TEMPLATE: appTemplate,
    FIXTURE_DMG_MOUNT: dmgMount,
    FIXTURE_PROMOTION_STATE: state,
    FIXTURE_FAIL_CAS: failCAS ? '1' : '0',
    FIXTURE_FAIL_ATTESTATION: failAttestation ? '1' : '0',
    FIXTURE_VERSION: version,
    FIXTURE_BUILD: build,
    FIXTURE_ZIP_OBJECT: zipObject,
    FIXTURE_DMG_OBJECT: dmgObject,
    FIXTURE_CHECKSUM_OBJECT: checksumObject,
    FIXTURE_PROVENANCE_OBJECT: provenanceObject,
    FIXTURE_RECEIPT_OBJECT: receiptObject,
    FIXTURE_PROMOTED_FEED_BASE64: promotedFeed.toString('base64'),
    FIXTURE_TOOLING_COMMIT: toolingCommit,
    FIXTURE_RELEASE_COMMIT: releaseCommit,
    FIXTURE_SOURCE_COMMIT: sourceCommit,
    FIXTURE_RELEASE_DIFF: releaseDiff,
    FIXTURE_RELEASED_AT: '2026-08-10T09:59:00Z',
    FIXTURE_PUBLISHED_AT: '2026-08-10T09:59:30.000Z',
  }

  const appendEvent = `
const append = event => fs.appendFileSync(process.env.FIXTURE_LOG, event + '\\n')
`

  nodeExecutable(path.join(bin, 'git'), `
import fs from 'node:fs'
${appendEvent}
let args = process.argv.slice(2)
if (args[0] === '-C') args = args.slice(2)
const [command] = args
if (command === 'status') process.exit(0)
if (command === 'branch' && args.includes('--show-current')) { process.stdout.write('main\\n'); process.exit(0) }
if (command === 'fetch') { append('git:fetch'); process.exit(0) }
if (command === 'rev-parse') {
  const value = args.at(-1)
  if (value === '@{upstream}') process.stdout.write('origin/main\\n')
  else if (value === 'HEAD' || value === 'origin/main') process.stdout.write(process.env.FIXTURE_TOOLING_COMMIT + '\\n')
  else if (value.endsWith('^{commit}')) process.stdout.write(process.env.FIXTURE_RELEASE_COMMIT + '\\n')
  else if (value === process.env.FIXTURE_RELEASE_COMMIT + '^') process.stdout.write(process.env.FIXTURE_SOURCE_COMMIT + '\\n')
  else process.exit(2)
  process.exit(0)
}
if (command === 'cat-file') { process.stdout.write('tag\\n'); process.exit(0) }
if (command === 'ls-remote') {
  process.stdout.write(process.env.FIXTURE_RELEASE_COMMIT + '\\trefs/tags/v' + process.env.FIXTURE_VERSION + '^{}\\n')
  process.exit(0)
}
if (command === 'merge-base') process.exit(0)
if (command === 'log') {
  process.stdout.write('chore(release): ' + process.env.FIXTURE_VERSION + ' (daily)\\n')
  process.exit(0)
}
if (command === 'diff-tree') { process.stdout.write('app/Mechanician-Info.plist\\n'); process.exit(0) }
if (command === 'show') {
  if (args.includes('--format=%cI')) {
    process.stdout.write(process.env.FIXTURE_RELEASED_AT + '\\n')
    process.exit(0)
  }
  process.stdout.write(JSON.stringify({
    CFBundleShortVersionString: process.env.FIXTURE_VERSION,
    CFBundleVersion: process.env.FIXTURE_BUILD,
    CFBundleIdentifier: 'ai.mechanician.app',
  }) + '\\n')
  process.exit(0)
}
if (command === 'diff' && args.includes('--binary')) {
  process.stdout.write(process.env.FIXTURE_RELEASE_DIFF)
  process.exit(0)
}
process.stderr.write('unexpected fake git invocation: ' + JSON.stringify(args) + '\\n')
process.exit(90)
`)

  nodeExecutable(path.join(bin, 'gh'), `
import fs from 'node:fs'
${appendEvent}
append('ci:green')
process.stdout.write('success\\tmacOS 26 / Apple Silicon\\n')
`)

  nodeExecutable(path.join(bin, 'gcloud'), `
import fs from 'node:fs'
import path from 'node:path'
${appendEvent}
const args = process.argv.slice(2)
const root = process.env.FIXTURE_BUCKET_ROOT
const bucketPrefix = 'gs://test-updates/'
if (args[0] !== 'storage') process.exit(90)
if (args[1] === 'objects' && args[2] === 'describe') {
  const object = args[3].slice(bucketPrefix.length).split('#', 1)[0]
  const filename = path.join(root, object)
  if (!fs.existsSync(filename)) process.exit(1)
  const format = args.find(value => value.startsWith('--format=')) ?? ''
  if (format.includes('crc32c_hash')) {
    process.stdout.write('17\\tfixture-crc32c\\t2026-08-10T09:59:30+0000\\n')
  } else {
    process.stdout.write('17\\t' + fs.statSync(filename).size + '\\n')
  }
  process.exit(0)
}
if (args[1] === 'cp') {
  const positional = args.slice(2).filter(arg => !arg.startsWith('--'))
  const source = positional[0]
  const destination = positional[1]
  if (!source.startsWith(bucketPrefix) || destination.startsWith('gs://')) process.exit(90)
  const object = source.slice(bucketPrefix.length).split('#', 1)[0]
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  fs.copyFileSync(path.join(root, object), destination)
  append('gcloud:download:' + object)
  process.exit(0)
}
process.exit(90)
`)

  nodeExecutable(path.join(bin, 'plutil'), `
import fs from 'node:fs'
const args = process.argv.slice(2)
const read = filename => filename === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(filename, 'utf8')
if (args[0] === '-convert' && args[1] === 'json') {
  process.stdout.write(read(args.at(-1)))
  process.exit(0)
}
if (args[0] === '-extract') {
  const value = JSON.parse(read(args.at(-1)))[args[1]]
  if (value === undefined) process.exit(1)
  process.stdout.write(String(value))
  process.exit(0)
}
process.exit(90)
`)

  nodeExecutable(path.join(bin, 'ditto'), `
import fs from 'node:fs'
import path from 'node:path'
${appendEvent}
const args = process.argv.slice(2)
if (args[0] !== '-x' || args[1] !== '-k') { append('FORBIDDEN:ditto-mutation'); process.exit(91) }
const output = args[3]
fs.mkdirSync(output, { recursive: true })
fs.cpSync(process.env.FIXTURE_APP_TEMPLATE, path.join(output, 'Mechanician.app'), { recursive: true })
append('ditto:extract')
`)

  nodeExecutable(path.join(bin, 'codesign'), `
import fs from 'node:fs'
${appendEvent}
const args = process.argv.slice(2)
if (args.includes('--verify')) { append('codesign:verify'); process.exit(0) }
if (args.includes('-d')) {
  append('codesign:display')
  process.stderr.write('Identifier=ai.mechanician.app\\nTeamIdentifier=5YPG2C4S34\\nCDHash=abc123\\n')
  process.exit(0)
}
append('FORBIDDEN:codesign-sign')
process.exit(91)
`)

  nodeExecutable(path.join(bin, 'spctl'), `
import fs from 'node:fs'
${appendEvent}
const args = process.argv.slice(2)
if (!args.includes('--assess')) { append('FORBIDDEN:spctl-mutation'); process.exit(91) }
append('spctl:assess')
`)

  nodeExecutable(path.join(bin, 'xcrun'), `
import fs from 'node:fs'
${appendEvent}
const args = process.argv.slice(2)
if (args[0] === 'stapler' && args[1] === 'validate') { append('stapler:validate'); process.exit(0) }
if (args[0] === 'notarytool' && args[1] === 'submit') append('FORBIDDEN:notary-submit')
else append('FORBIDDEN:xcrun-mutation')
process.exit(91)
`)

  nodeExecutable(path.join(bin, 'hdiutil'), `
import fs from 'node:fs'
${appendEvent}
const args = process.argv.slice(2)
if (args[0] === 'verify') { append('hdiutil:verify'); process.exit(0) }
if (args[0] === 'attach') {
  append('hdiutil:attach')
  process.stdout.write(JSON.stringify({ 'system-entities': [{ 'mount-point': process.env.FIXTURE_DMG_MOUNT }] }))
  process.exit(0)
}
if (args[0] === 'detach') { append('hdiutil:detach'); process.exit(0) }
if (args[0] === 'create') append('FORBIDDEN:create-DMG')
else append('FORBIDDEN:hdiutil-mutation')
process.exit(91)
`)

  nodeExecutable(path.join(bin, 'sign_update'), `
import fs from 'node:fs'
${appendEvent}
const args = process.argv.slice(2)
const feed = args.find(arg => arg.endsWith('.xml'))
if (args.includes('--verify')) {
  append(feed?.endsWith('.appcast-before.xml') ? 'appcast-source:verify' : 'appcast-candidate:verify')
  process.exit(0)
}
if (feed) { append('appcast-candidate:sign'); process.exit(0) }
append('FORBIDDEN:artifact-sign')
process.exit(91)
`)

  nodeExecutable(path.join(scripts, 'stage-update-history.sh'), `
import fs from 'node:fs'
import path from 'node:path'
${appendEvent}
const [mode, stage, requestedBuild, requestedVersion] = process.argv.slice(2)
const root = process.env.FIXTURE_BUCKET_ROOT
if (mode === 'stage') {
  append('history:stage')
  fs.copyFileSync(path.join(root, 'appcast.xml'), path.join(stage, '.appcast-before.xml'))
  fs.copyFileSync(path.join(root, 'appcast.xml'), path.join(stage, 'appcast.xml'))
  fs.copyFileSync(path.join(root, process.env.FIXTURE_ZIP_OBJECT), path.join(stage, process.env.FIXTURE_ZIP_OBJECT))
  const channel = process.env.FIXTURE_PROMOTION_STATE === 'already-promoted' ? '' : 'daily'
  const fields = [
    process.env.FIXTURE_BUILD, process.env.FIXTURE_VERSION, process.env.FIXTURE_ZIP_OBJECT,
    'https://storage.googleapis.com/test-updates/' + process.env.FIXTURE_ZIP_OBJECT,
    String(fs.statSync(path.join(root, process.env.FIXTURE_ZIP_OBJECT)).size), 'signature',
    '200', '26.0', '27.9', '100', 'arm64', channel,
  ]
  fs.writeFileSync(path.join(stage, '.appcast-before-items.tsv'), fields.join('\\t') + '\\n')
  process.exit(0)
}
if (mode === 'prepare-promotion') {
  append('history:prepare')
  if (requestedBuild !== process.env.FIXTURE_BUILD || requestedVersion !== process.env.FIXTURE_VERSION) process.exit(2)
  fs.writeFileSync(path.join(stage, 'appcast.xml'), Buffer.from(process.env.FIXTURE_PROMOTED_FEED_BASE64, 'base64'))
  process.stdout.write(process.env.FIXTURE_PROMOTION_STATE + '\\n')
  process.exit(0)
}
if (mode === 'verify-promotion') { append('history:verify-promotion'); process.exit(0) }
if (mode === 'verify-remote') { append('history:verify-remote'); process.exit(0) }
if (mode === 'publish') {
  append('appcast:CAS-attempt')
  if (process.env.FIXTURE_FAIL_CAS === '1') { append('appcast:CAS-failed'); process.exit(1) }
  fs.copyFileSync(path.join(stage, 'appcast.xml'), path.join(root, 'appcast.xml'))
  append('appcast:CAS-succeeded')
  process.exit(0)
}
process.exit(90)
`)

  nodeExecutable(path.join(scripts, 'publish-update-artifacts.sh'), `
import fs from 'node:fs'
import path from 'node:path'
${appendEvent}
const [mode, first, second] = process.argv.slice(2)
const root = process.env.FIXTURE_BUCKET_ROOT
if (mode === 'upload-immutable') {
  append('receipt:upload')
  fs.copyFileSync(first, path.join(root, second))
  process.exit(0)
}
if (mode === 'reconcile-stable-aliases') {
  if (first !== process.env.FIXTURE_VERSION || second !== process.env.FIXTURE_BUILD) process.exit(2)
  append('aliases:reconcile')
  fs.copyFileSync(path.join(root, process.env.FIXTURE_ZIP_OBJECT), path.join(root, 'Mechanician-latest.zip'))
  fs.copyFileSync(path.join(root, process.env.FIXTURE_DMG_OBJECT), path.join(root, 'Mechanician-latest.dmg'))
  process.exit(0)
}
process.exit(90)
`)

  nodeExecutable(path.join(scripts, 'validate-stable-promotion.mjs'), `
import fs from 'node:fs'
${appendEvent}
append('attestation:validate')
if (process.env.FIXTURE_FAIL_ATTESTATION === '1') process.exit(1)
const args = process.argv.slice(2)
const required = ['--version', process.env.FIXTURE_VERSION, '--build', process.env.FIXTURE_BUILD,
  '--source-commit', process.env.FIXTURE_SOURCE_COMMIT, '--released-at', process.env.FIXTURE_PUBLISHED_AT]
for (let index = 0; index < required.length; index += 2) {
  const at = args.indexOf(required[index])
  if (at < 0 || args[at + 1] !== required[index + 1]) process.exit(2)
}
process.stdout.write(JSON.stringify({ validated: true, version: process.env.FIXTURE_VERSION, build: process.env.FIXTURE_BUILD }) + '\\n')
`)

  for (const relative of ['build-app.sh', 'scripts/create-dmg.sh']) {
    const filename = path.join(repo, relative)
    fs.mkdirSync(path.dirname(filename), { recursive: true })
    nodeExecutable(filename, `
import fs from 'node:fs'
fs.appendFileSync(process.env.FIXTURE_LOG, 'FORBIDDEN:${relative}\\n')
process.exit(91)
`)
  }

  const environment = {
    ...process.env,
    ...baseEnvironment,
    PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
    MECHANICIAN_UPDATE_BUCKET: 'gs://test-updates',
    MECHANICIAN_UPDATE_URL_PREFIX: 'https://storage.googleapis.com/test-updates/',
    MECHANICIAN_GCLOUD: path.join(bin, 'gcloud'),
    MECHANICIAN_GH: path.join(bin, 'gh'),
    MECHANICIAN_GIT: path.join(bin, 'git'),
    MECHANICIAN_SIGN_UPDATE: path.join(bin, 'sign_update'),
    MECHANICIAN_PROMOTION_STAGE: stage,
    MECHANICIAN_PROMOTION_VOLUME_ROOT: root,
  }

  function run() {
    return spawnSync(path.join(scripts, 'promote-daily.sh'), [
      version, '--attestation', attestation,
    ], { encoding: 'utf8', env: environment })
  }

  function events() {
    if (!fs.existsSync(log)) return []
    return fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean)
  }

  function bucketBytes(object) {
    return fs.readFileSync(path.join(bucket, object))
  }

  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return {
    root,
    repo,
    bucket,
    stage,
    receiptObject,
    initialFeed,
    promotedFeed,
    initialZipAlias,
    initialDMGAlias,
    zipBytes,
    dmgBytes,
    run,
    events,
    bucketBytes,
  }
}

function indexOfExactlyOnce(events, event) {
  assert.equal(events.filter(value => value === event).length, 1, `${event} should occur once:\n${events.join('\n')}`)
  return events.indexOf(event)
}

function assertNoArtifactMutation(events) {
  assert.deepEqual(events.filter(event => event.startsWith('FORBIDDEN:')), [])
  assert.equal(events.some(event => event === 'codesign:sign'), false)
  assert.equal(events.some(event => event === 'FORBIDDEN:notary-submit'), false)
  assert.ok(events.filter(event => event === 'codesign:verify').length >= 3)
  assert.ok(events.filter(event => event === 'stapler:validate').length >= 2)
}

test('Daily promotion validates policy and creates its immutable receipt before CAS, then moves aliases', (t) => {
  const fixture = createFixture(t)
  const result = fixture.run()
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  const events = fixture.events()
  const attestation = indexOfExactlyOnce(events, 'attestation:validate')
  const receipt = indexOfExactlyOnce(events, 'receipt:upload')
  const casAttempt = indexOfExactlyOnce(events, 'appcast:CAS-attempt')
  const casSuccess = indexOfExactlyOnce(events, 'appcast:CAS-succeeded')
  const aliases = indexOfExactlyOnce(events, 'aliases:reconcile')
  assert.ok(attestation < receipt)
  assert.ok(receipt < casAttempt)
  assert.ok(casAttempt < casSuccess)
  assert.ok(casSuccess < aliases)
  assert.ok(fixture.bucketBytes(fixture.receiptObject).length > 0)
  assert.deepEqual(fixture.bucketBytes('appcast.xml'), fixture.promotedFeed)
  assert.deepEqual(fixture.bucketBytes('Mechanician-latest.zip'), fixture.zipBytes)
  assert.deepEqual(fixture.bucketBytes('Mechanician-latest.dmg'), fixture.dmgBytes)
  assertNoArtifactMutation(events)
})

test('an already-promoted feed skips appcast signing and CAS but still reconciles exact aliases', (t) => {
  const fixture = createFixture(t, { state: 'already-promoted' })
  const result = fixture.run()
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  const events = fixture.events()
  const attestation = indexOfExactlyOnce(events, 'attestation:validate')
  const receipt = indexOfExactlyOnce(events, 'receipt:upload')
  const aliases = indexOfExactlyOnce(events, 'aliases:reconcile')
  assert.ok(attestation < receipt && receipt < aliases)
  assert.equal(events.includes('appcast-candidate:sign'), false)
  assert.equal(events.includes('appcast-candidate:verify'), false)
  assert.equal(events.includes('appcast:CAS-attempt'), false)
  assert.deepEqual(fixture.bucketBytes('appcast.xml'), fixture.initialFeed)
  assert.deepEqual(fixture.bucketBytes('Mechanician-latest.zip'), fixture.zipBytes)
  assert.deepEqual(fixture.bucketBytes('Mechanician-latest.dmg'), fixture.dmgBytes)
  assertNoArtifactMutation(events)
})

test('an appcast generation conflict leaves both Stable aliases byte-for-byte untouched', (t) => {
  const fixture = createFixture(t, { failCAS: true })
  const result = fixture.run()
  assert.notEqual(result.status, 0)
  const events = fixture.events()
  const attestation = indexOfExactlyOnce(events, 'attestation:validate')
  const receipt = indexOfExactlyOnce(events, 'receipt:upload')
  const casAttempt = indexOfExactlyOnce(events, 'appcast:CAS-attempt')
  const casFailure = indexOfExactlyOnce(events, 'appcast:CAS-failed')
  assert.ok(attestation < receipt && receipt < casAttempt && casAttempt < casFailure)
  assert.equal(events.includes('aliases:reconcile'), false)
  assert.deepEqual(fixture.bucketBytes('appcast.xml'), fixture.initialFeed)
  assert.deepEqual(fixture.bucketBytes('Mechanician-latest.zip'), fixture.initialZipAlias)
  assert.deepEqual(fixture.bucketBytes('Mechanician-latest.dmg'), fixture.initialDMGAlias)
  assert.ok(fixture.bucketBytes(fixture.receiptObject).length > 0)
  assertNoArtifactMutation(events)
})

test('a rejected attestation creates no receipt and cannot reach either mutable publication step', (t) => {
  const fixture = createFixture(t, { failAttestation: true })
  const result = fixture.run()
  assert.notEqual(result.status, 0)
  const events = fixture.events()
  indexOfExactlyOnce(events, 'attestation:validate')
  assert.equal(events.includes('receipt:upload'), false)
  assert.equal(events.includes('appcast:CAS-attempt'), false)
  assert.equal(events.includes('aliases:reconcile'), false)
  assert.deepEqual(fixture.bucketBytes('appcast.xml'), fixture.initialFeed)
  assert.deepEqual(fixture.bucketBytes('Mechanician-latest.zip'), fixture.initialZipAlias)
  assert.deepEqual(fixture.bucketBytes('Mechanician-latest.dmg'), fixture.initialDMGAlias)
  assert.equal(fs.existsSync(path.join(fixture.bucket, fixture.receiptObject)), false)
  assertNoArtifactMutation(events)
})

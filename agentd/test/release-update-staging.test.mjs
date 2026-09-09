import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '../..')
const stager = path.join(repo, 'scripts/stage-update-history.sh')

const signatures = {
  current: Buffer.alloc(64, 0x11).toString('base64'),
  legacy: Buffer.alloc(64, 0x22).toString('base64'),
  candidate: Buffer.alloc(64, 0x33).toString('base64'),
  delta: Buffer.alloc(64, 0x44).toString('base64'),
  alternate: Buffer.alloc(64, 0x55).toString('base64'),
}

const currentBranch = {
  minimumUpdateVersion: '200',
  minimumSystemVersion: '26.0',
  maximumSystemVersion: '27.9',
  minimumAutoupdateVersion: '100',
  hardwareRequirements: 'arm64',
  channel: undefined,
}

const legacyBranch = {
  minimumUpdateVersion: '30',
  minimumSystemVersion: '13.0',
  maximumSystemVersion: '25.9',
  minimumAutoupdateVersion: '20',
  hardwareRequirements: 'arm64',
  channel: 'legacy',
}

function branchXML(branch = {}) {
  const fields = [
    ['minimumUpdateVersion', branch.minimumUpdateVersion],
    ['minimumSystemVersion', branch.minimumSystemVersion],
    ['maximumSystemVersion', branch.maximumSystemVersion],
    ['minimumAutoupdateVersion', branch.minimumAutoupdateVersion],
    ['hardwareRequirements', branch.hardwareRequirements],
    ['channel', branch.channel],
  ]
  return fields
    .filter(([, value]) => value !== undefined && value !== null)
    .map(([name, value]) => `      <sparkle:${name}>${value}</sparkle:${name}>`)
    .join('\n')
}

function itemXML({
  build,
  version,
  url,
  length,
  signature,
  branch,
  deltas = [],
  directEnclosures,
}) {
  const enclosures = directEnclosures ?? [{ url, length, signature }]
  const directXML = enclosures.map(enclosure => `      <enclosure url="${enclosure.url}" length="${enclosure.length}" type="application/octet-stream" sparkle:edSignature="${enclosure.signature}"/>`).join('\n')
  const deltaXML = deltas.length === 0
    ? ''
    : `\n      <sparkle:deltas>\n${deltas.map(delta => `        <enclosure url="${delta.url}" sparkle:deltaFrom="${delta.from}" length="${delta.length}" type="application/octet-stream" sparkle:edSignature="${delta.signature}"/>`).join('\n')}\n      </sparkle:deltas>`

  return `    <item>
      <title>${version}</title>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
${branchXML(branch)}
${directXML}${deltaXML}
    </item>`
}

function appcastXML(items) {
  return `<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Mechanician</title>
${items.join('\n')}
  </channel>
</rss>
`
}

function objectURL(fixture, object) {
  return `${fixture.urlPrefix}${encodeURIComponent(object)}`
}

function createFixture(t, {
  bucket = 'gs://test-updates',
  urlPrefix = 'https://storage.googleapis.com/test-updates/',
  artifactName = 'Mechanician',
  deltaPrefix = 'Mechanician',
  sparkleAccount = 'test-ed25519',
  generations = ['170', '170'],
} = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-update-stage-'))
  const bin = path.join(root, 'bin')
  const bucketRoot = path.join(root, 'bucket')
  const stage = path.join(root, 'stage')
  const gcloudLog = path.join(root, 'gcloud.log')
  const signLog = path.join(root, 'sign-update.log')
  const statePath = path.join(root, 'gcloud-state.json')
  const signaturesPath = path.join(root, 'signatures.json')
  fs.mkdirSync(bin)
  fs.mkdirSync(bucketRoot)
  fs.mkdirSync(stage)
  fs.symlinkSync(process.execPath, path.join(bin, 'node'))
  fs.writeFileSync(statePath, JSON.stringify({ describeCount: 0, generations }))
  fs.writeFileSync(signaturesPath, '{}')

  const fakeGcloud = `#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const bucket = process.env.MECHANICIAN_UPDATE_BUCKET
const bucketRoot = process.env.FAKE_GCLOUD_BUCKET_ROOT
const log = process.env.FAKE_GCLOUD_LOG
const statePath = process.env.FAKE_GCLOUD_STATE
fs.appendFileSync(log, JSON.stringify(args) + '\\n')

if (args[0] !== 'storage') process.exit(64)

if (args[1] === 'objects' && args[2] === 'describe') {
  const target = args[3]
  const format = args.find(arg => arg.startsWith('--format='))
  const prefix = bucket + '/'
  if (format === '--format=value(generation)') {
    if (target !== bucket + '/appcast.xml') process.exit(65)
    const state = JSON.parse(fs.readFileSync(statePath, 'utf8'))
    const index = Math.min(state.describeCount, state.generations.length - 1)
    process.stdout.write(String(state.generations[index]) + '\\n')
    state.describeCount += 1
    fs.writeFileSync(statePath, JSON.stringify(state))
    process.exit(0)
  }
  if (format === '--format=value(size)') {
    if (!target.startsWith(prefix)) process.exit(65)
    const objectPath = path.join(bucketRoot, target.slice(prefix.length))
    if (!fs.existsSync(objectPath)) process.exit(1)
    process.stdout.write(String(fs.statSync(objectPath).size) + '\\n')
    process.exit(0)
  }
  process.exit(65)
}

if (args[1] === 'cp') {
  const positional = args.slice(2).filter(arg => !arg.startsWith('--'))
  if (positional.length !== 2) process.exit(66)
  const [source, destinationArgument] = positional
  const prefix = bucket + '/'
  if (source.startsWith(prefix) && !destinationArgument.startsWith('gs://')) {
    const object = source.slice(prefix.length)
    const sourcePath = path.join(bucketRoot, object)
    if (!fs.existsSync(sourcePath)) {
      process.stderr.write('missing fake object: ' + source + '\\n')
      process.exit(1)
    }
    let destination = destinationArgument
    if (destination.endsWith('/') || (fs.existsSync(destination) && fs.statSync(destination).isDirectory())) {
      destination = path.join(destination, path.basename(object))
    }
    fs.mkdirSync(path.dirname(destination), { recursive: true })
    fs.copyFileSync(sourcePath, destination)
    process.exit(0)
  }
  if (!source.startsWith('gs://') && destinationArgument.startsWith(prefix)) {
    const generationFlag = args.find(arg => arg.startsWith('--if-generation-match='))
    const expectedGeneration = generationFlag?.slice('--if-generation-match='.length)
    const state = JSON.parse(fs.readFileSync(statePath, 'utf8'))
    const currentGeneration = String(state.generations.at(-1))
    if (process.env.FAKE_GCLOUD_GENERATION_CONFLICT === '1' || expectedGeneration !== currentGeneration) {
      process.stderr.write('simulated generation conflict\\n')
      process.exit(1)
    }
    if (!fs.existsSync(source)) process.exit(1)
    const object = destinationArgument.slice(prefix.length)
    const destination = path.join(bucketRoot, object)
    fs.mkdirSync(path.dirname(destination), { recursive: true })
    fs.copyFileSync(source, destination)
    state.generations = [String(Number(currentGeneration) + 1)]
    state.describeCount = 0
    fs.writeFileSync(statePath, JSON.stringify(state))
    process.exit(0)
  }
  process.exit(67)
}

process.exit(68)
`

  const fakeSignUpdate = `#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const verifyIndex = args.indexOf('--verify')
fs.appendFileSync(process.env.FAKE_SIGN_UPDATE_LOG, JSON.stringify(args) + '\\n')
if (verifyIndex < 0 || verifyIndex + 2 >= args.length) process.exit(64)
const archive = args[verifyIndex + 1]
const signature = args[verifyIndex + 2]
const expected = JSON.parse(fs.readFileSync(process.env.FAKE_SIGNATURES, 'utf8'))[path.basename(archive)]
if (!expected || expected !== signature || !fs.existsSync(archive)) {
  process.stderr.write('signature verification failed for ' + path.basename(archive) + '\\n')
  process.exit(1)
}
process.exit(0)
`

  const gcloudPath = path.join(bin, 'gcloud')
  const signUpdatePath = path.join(bin, 'sign_update')
  fs.writeFileSync(gcloudPath, fakeGcloud, { mode: 0o755 })
  fs.writeFileSync(signUpdatePath, fakeSignUpdate, { mode: 0o755 })

  function writeObject(name, contents) {
    const destination = path.join(bucketRoot, name)
    fs.mkdirSync(path.dirname(destination), { recursive: true })
    fs.writeFileSync(destination, contents)
  }

  function registerSignature(name, signature) {
    const records = JSON.parse(fs.readFileSync(signaturesPath, 'utf8'))
    records[path.basename(name)] = signature
    fs.writeFileSync(signaturesPath, JSON.stringify(records))
  }

  function writeStageFile(name, contents, signature) {
    fs.writeFileSync(path.join(stage, name), contents)
    if (signature) registerSignature(name, signature)
  }

  function run(args, extraEnv = {}) {
    return spawnSync(stager, args, {
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        MECHANICIAN_UPDATE_BUCKET: bucket,
        MECHANICIAN_UPDATE_URL_PREFIX: urlPrefix,
        MECHANICIAN_ARTIFACT_NAME: artifactName,
        MECHANICIAN_SPARKLE_DELTA_PREFIX: deltaPrefix,
        MECHANICIAN_SPARKLE_ACCOUNT: sparkleAccount,
        MECHANICIAN_GCLOUD: gcloudPath,
        MECHANICIAN_SIGN_UPDATE: signUpdatePath,
        MECHANICIAN_XMLLINT: '/usr/bin/xmllint',
        FAKE_GCLOUD_BUCKET_ROOT: bucketRoot,
        FAKE_GCLOUD_LOG: gcloudLog,
        FAKE_GCLOUD_STATE: statePath,
        FAKE_SIGN_UPDATE_LOG: signLog,
        FAKE_SIGNATURES: signaturesPath,
        ...extraEnv,
      },
    })
  }

  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return {
    root,
    bucketRoot,
    stage,
    bucket,
    urlPrefix,
    artifactName,
    deltaPrefix,
    sparkleAccount,
    gcloudLog,
    signLog,
    writeObject,
    writeStageFile,
    registerSignature,
    run,
  }
}

function readJSONLines(filename) {
  if (!fs.existsSync(filename)) return []
  return fs.readFileSync(filename, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line))
}

function seedTwoBranchFeed(fixture) {
  const currentArchive = Buffer.from('current-update-archive')
  const legacyArchive = Buffer.from('legacy-update')
  const currentName = `${fixture.artifactName}-0.26.18.zip`
  const legacyName = `${fixture.artifactName}-0.7.31.zip`
  const currentDeltaName = `${fixture.deltaPrefix}233-232.delta`
  const feed = appcastXML([
    itemXML({
      build: '233',
      version: '0.26.18',
      branch: currentBranch,
      url: `${fixture.urlPrefix}${currentName}`,
      length: currentArchive.length,
      signature: signatures.current,
      deltas: [{
        from: '232',
        url: objectURL(fixture, currentDeltaName),
        length: 7,
        signature: signatures.delta,
      }],
    }),
    itemXML({
      build: '54',
      version: '0.7.31',
      branch: legacyBranch,
      url: `${fixture.urlPrefix}${legacyName}`,
      length: legacyArchive.length,
      signature: signatures.legacy,
      deltas: [{
        from: '53',
        url: objectURL(fixture, `${fixture.deltaPrefix}54-53.delta`),
        length: 6,
        signature: signatures.alternate,
      }],
    }),
  ])

  fixture.writeObject('appcast.xml', feed)
  fixture.writeObject(currentName, currentArchive)
  fixture.writeObject(legacyName, legacyArchive)
  fixture.writeObject(currentDeltaName, Buffer.alloc(7))
  fixture.writeObject(`${fixture.deltaPrefix}54-53.delta`, Buffer.alloc(6))
  fixture.writeObject(`${fixture.artifactName}-0.26.17.zip`, Buffer.from('unrelated-history'))
  fixture.writeObject(`${fixture.artifactName}-latest.zip`, Buffer.from('stable-zip'))
  fixture.writeObject(`${fixture.artifactName}-latest.dmg`, Buffer.from('stable-dmg'))
  fixture.writeObject(`${fixture.artifactName}-0.26.18-233-SHA256SUMS.txt`, Buffer.from('checksums'))
  fixture.writeObject(`${fixture.artifactName}-0.26.18-233-provenance.json`, Buffer.from('{}'))
  fixture.registerSignature(currentName, signatures.current)
  fixture.registerSignature(legacyName, signatures.legacy)
  return { feed, currentName, legacyName, currentArchive, legacyArchive }
}

function writeSingleItemFeed(fixture, {
  build = '233',
  version = '0.26.18',
  branch = currentBranch,
  url = `${fixture.urlPrefix}${fixture.artifactName}-${version}.zip`,
  archive = Buffer.from('single-update-archive'),
  length = archive.length,
  signature = signatures.current,
  directEnclosures,
  writeArchive = true,
  registeredSignature = signatures.current,
} = {}) {
  const name = `${fixture.artifactName}-${version}.zip`
  const feed = appcastXML([itemXML({
    build,
    version,
    branch,
    url,
    length,
    signature,
    directEnclosures,
  })])
  fixture.writeObject('appcast.xml', feed)
  if (writeArchive) fixture.writeObject(name, archive)
  if (registeredSignature) fixture.registerSignature(name, registeredSignature)
  return { feed, name, archive }
}

function prepareCandidate(fixture, {
  legacy = legacyBranch,
  includeLegacy = true,
  candidateBuild = '234',
  candidateVersion = '0.26.19',
  candidateArchive = Buffer.from('candidate-update-archive'),
  candidateLength = candidateArchive.length,
  candidateSignature = signatures.candidate,
  registeredCandidateSignature = signatures.candidate,
  deltaFrom = '233',
  deltaArchive = Buffer.from('candidate-delta'),
  deltaLength = deltaArchive.length,
  deltaSignature = signatures.delta,
  registeredDeltaSignature = signatures.delta,
  deltaURL,
  includeLegacyDelta = true,
} = {}) {
  const candidateName = `${fixture.artifactName}-${candidateVersion}.zip`
  const deltaName = `${fixture.deltaPrefix}${candidateBuild}-${deltaFrom}.delta`
  const items = [itemXML({
    build: candidateBuild,
    version: candidateVersion,
    branch: currentBranch,
    url: `${fixture.urlPrefix}${candidateName}`,
    length: candidateLength,
    signature: candidateSignature,
    deltas: [{
      from: deltaFrom,
      url: deltaURL ?? objectURL(fixture, deltaName),
      length: deltaLength,
      signature: deltaSignature,
    }],
  })]
  if (includeLegacy) {
    const legacyArchive = fs.readFileSync(path.join(fixture.stage, `${fixture.artifactName}-0.7.31.zip`))
    items.push(itemXML({
      build: '54',
      version: '0.7.31',
      branch: legacy,
      url: `${fixture.urlPrefix}${fixture.artifactName}-0.7.31.zip`,
      length: legacyArchive.length,
      signature: signatures.legacy,
      deltas: includeLegacyDelta ? [{
        from: '53',
        url: objectURL(fixture, `${fixture.deltaPrefix}54-53.delta`),
        length: 6,
        signature: signatures.alternate,
      }] : [],
    }))
  }

  fixture.writeStageFile(candidateName, candidateArchive, registeredCandidateSignature)
  fixture.writeStageFile(deltaName, deltaArchive, registeredDeltaSignature)
  fixture.writeStageFile('appcast.xml', appcastXML(items))
  return { candidateName, deltaName }
}

test('stage downloads only direct full archives from every compatibility branch', (t) => {
  const fixture = createFixture(t)
  const seeded = seedTwoBranchFeed(fixture)
  const result = fixture.run(['stage', fixture.stage])

  assert.equal(result.status, 0, result.stderr)
  const stagedFiles = fs.readdirSync(fixture.stage)
  assert.deepEqual(stagedFiles.filter(name => !name.startsWith('.')).sort(), [
    seeded.currentName,
    seeded.legacyName,
    'appcast.xml',
  ].sort())
  assert.ok(stagedFiles.includes('.appcast-before.xml'))
  assert.ok(stagedFiles.includes('.appcast-generation'))
  assert.equal(fs.readFileSync(path.join(fixture.stage, '.appcast-before.xml'), 'utf8'), seeded.feed)
  assert.equal(fs.readFileSync(path.join(fixture.stage, '.appcast-generation'), 'utf8').trim(), '170')

  const gcloudCalls = readJSONLines(fixture.gcloudLog)
  const generationDescribeCalls = gcloudCalls.filter(args =>
    args[1] === 'objects' && args[2] === 'describe' && args.includes('--format=value(generation)'))
  const sizeDescribeCalls = gcloudCalls.filter(args =>
    args[1] === 'objects' && args[2] === 'describe' && args.includes('--format=value(size)'))
  const copiedObjects = gcloudCalls
    .filter(args => args[1] === 'cp')
    .map(args => args.find(arg => arg.startsWith('gs://')))
    .sort()
  assert.equal(generationDescribeCalls.length, 2)
  assert.equal(sizeDescribeCalls.length, 2)
  assert.deepEqual(copiedObjects, [
    `${fixture.bucket}/appcast.xml`,
    `${fixture.bucket}/${seeded.currentName}`,
    `${fixture.bucket}/${seeded.legacyName}`,
  ].sort())
  assert.equal(gcloudCalls.some(args => args.includes('rsync')), false)
  assert.equal(copiedObjects.some(object => object.includes('.delta')), false)
  assert.equal(copiedObjects.some(object => object.includes('-latest.')), false)
  assert.equal(copiedObjects.some(object => object.includes('SHA256SUMS')), false)
  assert.equal(copiedObjects.some(object => object.includes('provenance')), false)

  const signCalls = readJSONLines(fixture.signLog)
  assert.equal(signCalls.length, 2)
  assert.ok(signCalls.every(args => args.includes('--account') && args.includes(fixture.sparkleAccount)))
})

test('stage honors custom release identity knobs and Sparkle-encoded branded delta names', (t) => {
  const fixture = createFixture(t, {
    bucket: 'gs://acme-updates/releases',
    urlPrefix: 'https://updates.example.invalid/acme/',
    artifactName: 'Acme-Mechanician',
    deltaPrefix: 'Acme Agent',
    sparkleAccount: 'acme-ed25519',
  })
  const seeded = writeSingleItemFeed(fixture)
  const result = fixture.run(['stage', fixture.stage])

  assert.equal(result.status, 0, result.stderr)
  assert.ok(fs.existsSync(path.join(fixture.stage, seeded.name)))
  const signCalls = readJSONLines(fixture.signLog)
  assert.equal(signCalls.length, 1)
  assert.ok(signCalls[0].includes('acme-ed25519'))

  const candidate = prepareCandidate(fixture, { includeLegacy: false })
  const transitioned = fixture.run(['verify-transition', fixture.stage, '234', '0.26.19', 'stable'])
  assert.equal(transitioned.status, 0, transitioned.stderr)
  assert.match(candidate.deltaName, /Acme Agent234-233\.delta/)
  assert.match(fs.readFileSync(path.join(fixture.stage, 'appcast.xml'), 'utf8'), /Acme%20Agent234-233\.delta/)
})

test('stage fails closed on malformed, off-origin, noncanonical, missing, corrupt, or unsigned inputs', async (t) => {
  const cases = [
    {
      name: 'malformed XML',
      setup(fixture) {
        fixture.writeObject('appcast.xml', '<rss><channel><item></rss>')
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'no update items',
      setup(fixture) {
        fixture.writeObject('appcast.xml', appcastXML([]))
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'missing direct enclosure',
      setup(fixture) {
        const feed = appcastXML([itemXML({
          build: '233',
          version: '0.26.18',
          branch: currentBranch,
          directEnclosures: [],
        })])
        fixture.writeObject('appcast.xml', feed)
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'multiple direct enclosures',
      setup(fixture) {
        const archive = Buffer.from('archive')
        const canonical = `${fixture.urlPrefix}${fixture.artifactName}-0.26.18.zip`
        const feed = appcastXML([itemXML({
          build: '233',
          version: '0.26.18',
          branch: currentBranch,
          directEnclosures: [
            { url: canonical, length: archive.length, signature: signatures.current },
            { url: canonical, length: archive.length, signature: signatures.current },
          ],
        })])
        fixture.writeObject('appcast.xml', feed)
        fixture.writeObject(`${fixture.artifactName}-0.26.18.zip`, archive)
        fixture.registerSignature(`${fixture.artifactName}-0.26.18.zip`, signatures.current)
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'off-origin archive URL',
      setup(fixture) {
        writeSingleItemFeed(fixture, { url: 'https://attacker.invalid/Mechanician-0.26.18.zip' })
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'noncanonical archive path',
      setup(fixture) {
        writeSingleItemFeed(fixture, { url: `${fixture.urlPrefix}history/${fixture.artifactName}-0.26.18.zip` })
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'noncanonical archive name',
      setup(fixture) {
        writeSingleItemFeed(fixture, { url: `${fixture.urlPrefix}${fixture.artifactName}-wrong.zip` })
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'missing referenced archive',
      setup(fixture) {
        writeSingleItemFeed(fixture, { writeArchive: false })
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'declared object length mismatch',
      setup(fixture) {
        writeSingleItemFeed(fixture, { length: 999 })
      },
      expectedArchiveCopies: 0,
    },
    {
      name: 'signature verification failure',
      setup(fixture) {
        writeSingleItemFeed(fixture, {
          signature: signatures.alternate,
          registeredSignature: signatures.current,
        })
      },
      expectedArchiveCopies: 1,
    },
    {
      name: 'missing signature',
      setup(fixture) {
        writeSingleItemFeed(fixture, { signature: '' })
      },
      expectedArchiveCopies: 0,
    },
  ]

  for (const scenario of cases) {
    await t.test(scenario.name, (t) => {
      const fixture = createFixture(t)
      scenario.setup(fixture)
      const result = fixture.run(['stage', fixture.stage])

      assert.notEqual(result.status, 0, `unexpected success:\n${result.stdout}`)
      const archiveCopies = readJSONLines(fixture.gcloudLog)
        .filter(args => args[1] === 'cp')
        .map(args => args.find(arg => arg.startsWith('gs://')))
        .filter(source => !source.endsWith('/appcast.xml'))
      assert.equal(archiveCopies.length, scenario.expectedArchiveCopies)
    })
  }
})

test('stage rejects an appcast that changes generation while being read', (t) => {
  const fixture = createFixture(t, { generations: ['170', '171'] })
  writeSingleItemFeed(fixture)
  const result = fixture.run(['stage', fixture.stage])

  assert.notEqual(result.status, 0)
  const archiveCopies = readJSONLines(fixture.gcloudLog)
    .filter(args => args[1] === 'cp')
    .map(args => args.find(arg => arg.startsWith('gs://')))
    .filter(source => !source.endsWith('/appcast.xml'))
  assert.equal(archiveCopies.length, 0)
})

test('verify-transition accepts a same-branch update while retaining the legacy branch', (t) => {
  const fixture = createFixture(t)
  seedTwoBranchFeed(fixture)
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)
  const candidate = prepareCandidate(fixture)

  const result = fixture.run(['verify-transition', fixture.stage, '234', '0.26.19', 'stable'])

  assert.equal(result.status, 0, result.stderr)
  const manifest = path.join(fixture.stage, '.appcast-candidate-objects.tsv')
  assert.ok(fs.existsSync(manifest))
  const manifestContents = fs.readFileSync(manifest, 'utf8')
  assert.match(manifestContents, new RegExp(candidate.candidateName.replaceAll('.', '\\.')))
  assert.match(manifestContents, new RegExp(candidate.deltaName.replaceAll('.', '\\.')))
})

test('preserve-unaffected restores old item metadata and deltas before verification', (t) => {
  const fixture = createFixture(t)
  seedTwoBranchFeed(fixture)
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)
  prepareCandidate(fixture)

  const candidatePath = path.join(fixture.stage, 'appcast.xml')
  const mutated = fs.readFileSync(candidatePath, 'utf8')
    .replaceAll(`${fixture.deltaPrefix}54-53.delta`, `${fixture.deltaPrefix}54-52.delta`)
    .replace('sparkle:deltaFrom="53"', 'sparkle:deltaFrom="52"')
  fs.writeFileSync(candidatePath, mutated)
  const orphanDelta = `${fixture.deltaPrefix}54-52.delta`
  fixture.writeStageFile(orphanDelta, Buffer.alloc(4), signatures.alternate)

  const preserved = fixture.run(['preserve-unaffected', fixture.stage, '234'])
  assert.equal(preserved.status, 0, preserved.stderr)
  const restored = fs.readFileSync(candidatePath, 'utf8')
  assert.match(restored, new RegExp(`${fixture.deltaPrefix}234-233\\.delta`))
  assert.match(restored, new RegExp(`${fixture.deltaPrefix}54-53\\.delta`))
  assert.doesNotMatch(restored, new RegExp(`${fixture.deltaPrefix}54-52\\.delta`))
  assert.equal(fs.existsSync(path.join(fixture.stage, orphanDelta)), false)
  assert.equal(fs.existsSync(path.join(fixture.stage, `${fixture.deltaPrefix}234-233.delta`)), true)

  const verified = fixture.run([
    'verify-transition', fixture.stage, '234', '0.26.19', 'stable',
  ])
  assert.equal(verified.status, 0, verified.stderr)
})

test('stable transition requires deltas from both live stable and daily leaders', (t) => {
  const fixture = createFixture(t)
  const stableArchive = Buffer.from('stable-leader')
  const dailyArchive = Buffer.from('daily-leader')
  const stableName = `${fixture.artifactName}-0.26.18.zip`
  const dailyName = `${fixture.artifactName}-0.26.19.zip`
  const dailyDeltaName = `${fixture.deltaPrefix}234-233.delta`
  const dailyBranch = { ...currentBranch, channel: 'daily' }
  fixture.writeObject('appcast.xml', appcastXML([
    itemXML({
      build: '234', version: '0.26.19', branch: dailyBranch,
      url: objectURL(fixture, dailyName), length: dailyArchive.length,
      signature: signatures.legacy,
      deltas: [{
        from: '233', url: objectURL(fixture, dailyDeltaName), length: 8,
        signature: signatures.alternate,
      }],
    }),
    itemXML({
      build: '233', version: '0.26.18', branch: currentBranch,
      url: objectURL(fixture, stableName), length: stableArchive.length,
      signature: signatures.current,
    }),
  ]))
  fixture.writeObject(stableName, stableArchive)
  fixture.writeObject(dailyName, dailyArchive)
  fixture.writeObject(dailyDeltaName, Buffer.alloc(8))
  fixture.registerSignature(stableName, signatures.current)
  fixture.registerSignature(dailyName, signatures.legacy)
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)

  const candidateArchive = Buffer.from('new-stable')
  const candidateName = `${fixture.artifactName}-0.26.20.zip`
  const fromDailyName = `${fixture.deltaPrefix}235-234.delta`
  const fromStableName = `${fixture.deltaPrefix}235-233.delta`
  fixture.writeStageFile(candidateName, candidateArchive, signatures.candidate)
  fixture.writeStageFile(fromDailyName, Buffer.alloc(9), signatures.delta)
  fixture.writeStageFile(fromStableName, Buffer.alloc(10), signatures.alternate)
  fixture.writeStageFile('appcast.xml', appcastXML([
    itemXML({
      build: '235', version: '0.26.20', branch: currentBranch,
      url: objectURL(fixture, candidateName), length: candidateArchive.length,
      signature: signatures.candidate,
      deltas: [
        { from: '234', url: objectURL(fixture, fromDailyName), length: 9, signature: signatures.delta },
        { from: '233', url: objectURL(fixture, fromStableName), length: 10, signature: signatures.alternate },
      ],
    }),
    itemXML({
      build: '234', version: '0.26.19', branch: dailyBranch,
      url: objectURL(fixture, dailyName), length: dailyArchive.length,
      signature: signatures.legacy,
      deltas: [{
        from: '233', url: objectURL(fixture, dailyDeltaName), length: 8,
        signature: signatures.alternate,
      }],
    }),
  ]))

  const verified = fixture.run([
    'verify-transition', fixture.stage, '235', '0.26.20', 'stable',
  ])
  assert.equal(verified.status, 0, verified.stderr)

  const missingStableSource = fs.readFileSync(path.join(fixture.stage, 'appcast.xml'), 'utf8')
    .replace(new RegExp(`\\s*<enclosure url="[^"]*${fromStableName.replaceAll('.', '\\.')}"[^>]+/>`), '')
  fixture.writeStageFile('appcast.xml', missingStableSource)
  const rejected = fixture.run([
    'verify-transition', fixture.stage, '235', '0.26.20', 'stable',
  ])
  assert.notEqual(rejected.status, 0)
  assert.match(rejected.stderr, /no delta from live channel build 233/)
})

test('verify-transition enforces default-stable and explicit-daily channel identity', (t) => {
  const fixture = createFixture(t)
  const stableBranch = { ...currentBranch, channel: undefined }
  const stable = writeSingleItemFeed(fixture, { branch: stableBranch })
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)

  const candidateBuild = '234'
  const candidateVersion = '0.26.19'
  const candidateName = `${fixture.artifactName}-${candidateVersion}.zip`
  const candidateArchive = Buffer.from('daily-update-archive')
  const deltaName = `${fixture.deltaPrefix}${candidateBuild}-233.delta`
  const deltaArchive = Buffer.from('daily-delta')
  fixture.writeStageFile(candidateName, candidateArchive, signatures.candidate)
  fixture.writeStageFile(deltaName, deltaArchive, signatures.delta)
  fixture.writeStageFile('appcast.xml', appcastXML([
    itemXML({
      build: candidateBuild,
      version: candidateVersion,
      branch: { ...stableBranch, channel: 'daily' },
      url: objectURL(fixture, candidateName),
      length: candidateArchive.length,
      signature: signatures.candidate,
      deltas: [{
        from: '233',
        url: objectURL(fixture, deltaName),
        length: deltaArchive.length,
        signature: signatures.delta,
      }],
    }),
    itemXML({
      build: '233',
      version: '0.26.18',
      branch: stableBranch,
      url: objectURL(fixture, stable.name),
      length: stable.archive.length,
      signature: signatures.current,
    }),
  ]))

  const daily = fixture.run([
    'verify-transition', fixture.stage, candidateBuild, candidateVersion, 'daily',
  ])
  assert.equal(daily.status, 0, daily.stderr)
  const mislabeledStable = fixture.run([
    'verify-transition', fixture.stage, candidateBuild, candidateVersion, 'stable',
  ])
  assert.notEqual(mislabeledStable.status, 0)
  assert.match(mislabeledStable.stderr, /must use Sparkle's default channel/)

  fixture.writeStageFile('appcast.xml', appcastXML([
    itemXML({
      build: candidateBuild,
      version: candidateVersion,
      branch: stableBranch,
      url: objectURL(fixture, candidateName),
      length: candidateArchive.length,
      signature: signatures.candidate,
      deltas: [{
        from: '233',
        url: objectURL(fixture, deltaName),
        length: deltaArchive.length,
        signature: signatures.delta,
      }],
    }),
  ]))
  const stableResult = fixture.run([
    'verify-transition', fixture.stage, candidateBuild, candidateVersion, 'stable',
  ])
  assert.equal(stableResult.status, 0, stableResult.stderr)
  const mislabeledDaily = fixture.run([
    'verify-transition', fixture.stage, candidateBuild, candidateVersion, 'daily',
  ])
  assert.notEqual(mislabeledDaily.status, 0)
  assert.match(mislabeledDaily.stderr, /does not declare the daily channel/)
})

test('verify-transition requires an explicit fail-closed channel identity', (t) => {
  const fixture = createFixture(t)
  writeSingleItemFeed(fixture)
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)

  const missingChannel = fixture.run([
    'verify-transition', fixture.stage, '234', '0.26.19',
  ])
  assert.equal(missingChannel.status, 64)
  assert.match(missingChannel.stderr, /<stable\|daily>/)
})

test('verify-transition rejects loss or mutation of any Sparkle branch dimension', async (t) => {
  const fixture = createFixture(t)
  seedTwoBranchFeed(fixture)
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)

  await t.test('lost legacy branch', () => {
    prepareCandidate(fixture, { includeLegacy: false })
    const result = fixture.run(['verify-transition', fixture.stage, '234', '0.26.19', 'stable'])
    assert.notEqual(result.status, 0)
  })

  await t.test('lost legacy delta availability', () => {
    prepareCandidate(fixture, { includeLegacyDelta: false })
    const result = fixture.run(['verify-transition', fixture.stage, '234', '0.26.19', 'stable'])
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /changed delta availability/)
  })

  const mutations = {
    minimumUpdateVersion: '31',
    minimumSystemVersion: '14.0',
    maximumSystemVersion: '24.9',
    minimumAutoupdateVersion: '21',
    hardwareRequirements: 'x86_64',
    channel: 'beta',
  }
  for (const [field, value] of Object.entries(mutations)) {
    await t.test(`mutated ${field}`, () => {
      prepareCandidate(fixture, { legacy: { ...legacyBranch, [field]: value } })
      const result = fixture.run(['verify-transition', fixture.stage, '234', '0.26.19', 'stable'])
      assert.notEqual(result.status, 0)
    })
  }
})

test('verify-transition requires the requested build and short version', (t) => {
  const fixture = createFixture(t)
  seedTwoBranchFeed(fixture)
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)
  prepareCandidate(fixture)

  const wrongBuild = fixture.run(['verify-transition', fixture.stage, '235', '0.26.19', 'stable'])
  assert.notEqual(wrongBuild.status, 0)
  const wrongVersion = fixture.run(['verify-transition', fixture.stage, '234', '0.26.20', 'stable'])
  assert.notEqual(wrongVersion.status, 0)

  prepareCandidate(fixture, { candidateBuild: '233', deltaFrom: '232' })
  const staleBuild = fixture.run(['verify-transition', fixture.stage, '233', '0.26.19', 'stable'])
  assert.notEqual(staleBuild.status, 0)
  assert.match(staleBuild.stderr, /must exceed staged feed build 233/)
})

test('verify-transition validates candidate archive and delta integrity', async (t) => {
  const fixture = createFixture(t)
  seedTwoBranchFeed(fixture)
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)

  const cases = [
    {
      name: 'candidate archive length mismatch',
      candidate: { candidateLength: 999 },
    },
    {
      name: 'candidate archive signature mismatch',
      candidate: {
        candidateSignature: signatures.alternate,
        registeredCandidateSignature: signatures.candidate,
      },
    },
    {
      name: 'delta must come from an older build',
      candidate: { deltaFrom: '234' },
    },
    {
      name: 'delta URL must use its canonical build pair',
      candidate: { deltaURL: 'https://storage.googleapis.com/test-updates/Mechanician234-999.delta' },
    },
    {
      name: 'delta URL must remain on the configured origin',
      candidate: { deltaURL: 'https://attacker.invalid/Mechanician234-233.delta' },
    },
    {
      name: 'delta URL cannot encode a path separator',
      candidate: { deltaURL: 'https://storage.googleapis.com/test-updates/Mechanician%2F234-233.delta' },
    },
    {
      name: 'candidate delta length mismatch',
      candidate: { deltaLength: 999 },
    },
    {
      name: 'candidate delta signature mismatch',
      candidate: {
        deltaSignature: signatures.alternate,
        registeredDeltaSignature: signatures.delta,
      },
    },
  ]

  for (const scenario of cases) {
    await t.test(scenario.name, () => {
      for (const name of fs.readdirSync(fixture.stage)) {
        if (name.endsWith('.delta') || name === `${fixture.artifactName}-0.26.19.zip`) {
          fs.rmSync(path.join(fixture.stage, name), { force: true })
        }
      }
      prepareCandidate(fixture, scenario.candidate)

      const result = fixture.run(['verify-transition', fixture.stage, '234', '0.26.19', 'stable'])
      assert.notEqual(result.status, 0, `unexpected success:\n${result.stdout}`)
    })
  }
})

test('verify-remote requires the complete candidate full-archive and delta set at exact sizes', (t) => {
  const fixture = createFixture(t)
  seedTwoBranchFeed(fixture)
  const staged = fixture.run(['stage', fixture.stage])
  assert.equal(staged.status, 0, staged.stderr)
  const candidate = prepareCandidate(fixture)
  const transitioned = fixture.run(['verify-transition', fixture.stage, '234', '0.26.19', 'stable'])
  assert.equal(transitioned.status, 0, transitioned.stderr)

  const missing = fixture.run(['verify-remote', fixture.stage])
  assert.notEqual(missing.status, 0)

  const candidateArchive = fs.readFileSync(path.join(fixture.stage, candidate.candidateName))
  const candidateDelta = fs.readFileSync(path.join(fixture.stage, candidate.deltaName))
  fixture.writeObject(candidate.candidateName, candidateArchive)
  fixture.writeObject(candidate.deltaName, Buffer.alloc(candidateDelta.length + 1))
  const wrongSize = fixture.run(['verify-remote', fixture.stage])
  assert.notEqual(wrongSize.status, 0)

  fixture.writeObject(candidate.deltaName, candidateDelta)
  const callStart = readJSONLines(fixture.gcloudLog).length
  const complete = fixture.run(['verify-remote', fixture.stage])
  assert.equal(complete.status, 0, complete.stderr)
  assert.match(complete.stdout, /every candidate feed object exists with its declared length/)

  const expectedObjects = fs.readFileSync(path.join(fixture.stage, '.appcast-candidate-objects.tsv'), 'utf8')
    .trim()
    .split('\n')
    .map(line => line.split('\t')[0])
  const finalCalls = readJSONLines(fixture.gcloudLog).slice(callStart)
  assert.deepEqual(finalCalls.map(args => args[3]), expectedObjects.map(object => `${fixture.bucket}/${object}`))
  assert.ok(finalCalls.every(args =>
    args[0] === 'storage' &&
    args[1] === 'objects' &&
    args[2] === 'describe' &&
    args[4] === '--format=value(size)'))
})

test('publish uses a no-cache generation-matched appcast upload', (t) => {
  const fixture = createFixture(t)
  const original = Buffer.from('original live appcast')
  const candidate = Buffer.from('candidate appcast')
  fixture.writeObject('appcast.xml', original)
  fixture.writeStageFile('appcast.xml', candidate)
  fixture.writeStageFile('.appcast-generation', '170\n')

  const result = fixture.run(['publish', fixture.stage])

  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(readJSONLines(fixture.gcloudLog), [[
    'storage',
    'cp',
    '--cache-control=no-cache, max-age=0',
    '--if-generation-match=170',
    path.join(fixture.stage, 'appcast.xml'),
    `${fixture.bucket}/appcast.xml`,
  ]])
  assert.deepEqual(fs.readFileSync(path.join(fixture.bucketRoot, 'appcast.xml')), candidate)
})

test('publish leaves the live appcast unchanged on a generation conflict', (t) => {
  const fixture = createFixture(t)
  const original = Buffer.from('original live appcast')
  fixture.writeObject('appcast.xml', original)
  fixture.writeStageFile('appcast.xml', Buffer.from('candidate appcast'))
  fixture.writeStageFile('.appcast-generation', '170\n')

  const result = fixture.run(['publish', fixture.stage], {
    FAKE_GCLOUD_GENERATION_CONFLICT: '1',
  })

  assert.notEqual(result.status, 0)
  assert.deepEqual(readJSONLines(fixture.gcloudLog), [[
    'storage',
    'cp',
    '--cache-control=no-cache, max-age=0',
    '--if-generation-match=170',
    path.join(fixture.stage, 'appcast.xml'),
    `${fixture.bucket}/appcast.xml`,
  ]])
  assert.deepEqual(fs.readFileSync(path.join(fixture.bucketRoot, 'appcast.xml')), original)
})

test('release transaction wires selective staging, immutable publication, and CAS feed/alias ordering', () => {
  const source = fs.readFileSync(path.join(repo, 'scripts/release.sh'), 'utf8')
  assert.doesNotMatch(source, /gcloud\s+storage\s+rsync/)
  assert.match(source, /--versions "\$NEW_BUILD"/)
  assert.match(source, /RELEASE_CHANNEL="stable"/)
  assert.match(source, /--channel\).*RELEASE_CHANNEL="\$2"/)
  assert.match(source, /if \[ "\$RELEASE_CHANNEL" = "daily" \]; then/)
  assert.match(source, /MAXIMUM_DELTAS=1/)
  assert.match(source, /\[ "\$DAILY_HEAD_COUNT" = "0" \] \|\| MAXIMUM_DELTAS=2/)
  assert.match(source, /--maximum-deltas "\$MAXIMUM_DELTAS" --channel daily "\$STAGE"/)
  assert.match(source, /--maximum-deltas "\$MAXIMUM_DELTAS" "\$STAGE"/)
  assert.match(source, /preserve-unaffected "\$STAGE" "\$NEW_BUILD"/)
  assert.match(source, /verify-transition "\$STAGE" "\$NEW_BUILD" "\$VERSION" "\$RELEASE_CHANNEL"/)
  assert.match(source, /new_deltas=\("\$STAGE"\/\*\.delta\)/)
  assert.match(source, /for delta in "\$\{new_deltas\[@\]\}"; do\n\s+"\$ARTIFACT_PUBLISHER" upload-immutable "\$delta" "\$\(basename "\$delta"\)"/)
  assert.match(source, /if \[ "\$RELEASE_CHANNEL" = "stable" \]; then\n\s+echo "==> promoting stable download aliases \(un-cached\)"\n\s+"\$ARTIFACT_PUBLISHER" reconcile-stable-aliases "\$VERSION" "\$NEW_BUILD"/)
  assert.match(source, /if \[ "\$RELEASE_CHANNEL" = "daily" \]; then\n\s+echo "==> preserving stable download aliases for daily-channel release"\nfi/)
  assert.match(source, /daily channel: retaining a promotable DMG without touching Stable aliases/)
  assert.match(
    source,
    /CHECKSUM_ARTIFACTS=\("\$ZIP" "\$DSYM_ZIP" "\$DMG" "\$PKG" "\$PROVENANCE" "\$SBOM"\)/,
  )
  assert.match(source, /"\$ARTIFACT_PUBLISHER" upload-immutable "\$ZIP" "\$VERSIONED_ZIP"/)
  assert.match(source, /"\$ARTIFACT_PUBLISHER" upload-immutable "\$DMG" "\$VERSIONED_DMG"/)
  assert.match(source, /actions\/runs\?head_sha=\$CI_GATE_COMMIT&event=push&per_page=100/)
  assert.match(source, /\$2 == branch && \$3 == commit/)
  assert.match(source, /actions\/runs\/\$CI_RUN_ID\/jobs\?per_page=100/)
  assert.doesNotMatch(source, /commits\/\$CI_GATE_COMMIT\/check-runs/)

  const modes = [
    '"$UPDATE_HISTORY" stage "$STAGE"',
    '"$UPDATE_HISTORY" preserve-unaffected "$STAGE" "$NEW_BUILD"',
    '"$UPDATE_HISTORY" verify-transition "$STAGE" "$NEW_BUILD" "$VERSION" "$RELEASE_CHANNEL"',
    '"$UPDATE_HISTORY" verify-remote "$STAGE"',
    '"$UPDATE_HISTORY" publish "$STAGE"',
    '"$ARTIFACT_PUBLISHER" reconcile-stable-aliases "$VERSION" "$NEW_BUILD"',
  ]
  const offsets = modes.map((mode, index) => index === modes.length - 1
    ? source.lastIndexOf(mode)
    : source.indexOf(mode))
  assert.ok(offsets.every(offset => offset >= 0), `missing release helper mode: ${offsets}`)
  assert.deepEqual([...offsets].sort((left, right) => left - right), offsets)
})

test('release transaction binds a new release commit and its provenance to the CI-gated source', () => {
  const source = fs.readFileSync(path.join(repo, 'scripts/release.sh'), 'utf8')
  assert.match(source, /verify_gated_release_source\(\)/)
  assert.match(source, /\[ "\$CURRENT_SOURCE_COMMIT" = "\$CI_GATE_COMMIT" \]/)
  assert.match(source, /\[ "\$PROVENANCE_SOURCE" = "\$CI_GATE_COMMIT" \]/)
  assert.match(source, /\[ "\$PROVENANCE_DIFF" = "\$CURRENT_SOURCE_DIFF" \]/)

  const guardOffset = source.lastIndexOf('verify_gated_release_source')
  const commitOffset = source.indexOf('git -C "$REPO" commit -m "$RELEASE_COMMIT_SUBJECT"')
  assert.ok(guardOffset >= 0 && guardOffset < commitOffset, 'source guard must immediately precede the release commit')

  assert.match(source, /RELEASE_PARENT="\$\(git -C "\$REPO" rev-parse HEAD\^\)"/)
  assert.match(source, /\[ "\$RELEASE_PARENT" = "\$CI_GATE_COMMIT" \]/)
  assert.match(source, /\[ "\$PROVENANCE_SOURCE" = "\$RELEASE_PARENT" \]/)
  assert.match(source, /\[ "\$PROVENANCE_DIFF" = "\$RELEASE_DIFF" \]/)
})

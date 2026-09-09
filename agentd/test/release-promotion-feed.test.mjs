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
  stable: Buffer.alloc(64, 0x11).toString('base64'),
  daily: Buffer.alloc(64, 0x22).toString('base64'),
  legacy: Buffer.alloc(64, 0x33).toString('base64'),
  delta: Buffer.alloc(64, 0x44).toString('base64'),
  alternate: Buffer.alloc(64, 0x55).toString('base64'),
}

const platformBranch = {
  minimumUpdateVersion: '200',
  minimumSystemVersion: '26.0',
  maximumSystemVersion: '27.9',
  minimumAutoupdateVersion: '100',
  hardwareRequirements: 'arm64',
}

const legacyBranch = {
  minimumUpdateVersion: '30',
  minimumSystemVersion: '13.0',
  maximumSystemVersion: '25.9',
  minimumAutoupdateVersion: '20',
  hardwareRequirements: 'arm64',
  channel: 'legacy',
}

function branchXML(branch) {
  return [
    ['minimumUpdateVersion', branch.minimumUpdateVersion],
    ['minimumSystemVersion', branch.minimumSystemVersion],
    ['maximumSystemVersion', branch.maximumSystemVersion],
    ['minimumAutoupdateVersion', branch.minimumAutoupdateVersion],
    ['hardwareRequirements', branch.hardwareRequirements],
    ['channel', branch.channel],
  ]
    .filter(([, value]) => value !== undefined)
    .map(([name, value]) => `      <sparkle:${name}>${value}</sparkle:${name}>`)
    .join('\n')
}

function itemXML({
  build,
  version,
  branch,
  url,
  length,
  signature,
  title = version,
  pubDate,
  description,
  releaseNotesLink,
  deltas = [],
}) {
  const dateXML = pubDate ? `\n      <pubDate>${pubDate}</pubDate>` : ''
  const descriptionXML = description ? `\n      <description><![CDATA[${description}]]></description>` : ''
  const notesXML = releaseNotesLink
    ? `\n      <sparkle:releaseNotesLink length="${releaseNotesLink.length}" sparkle:edSignature="${releaseNotesLink.signature}">${releaseNotesLink.url}</sparkle:releaseNotesLink>`
    : ''
  const deltaXML = deltas.length === 0
    ? ''
    : `\n      <sparkle:deltas>\n${deltas.map(delta => `        <enclosure url="${delta.url}" sparkle:deltaFrom="${delta.from}" length="${delta.length}" type="application/octet-stream" sparkle:edSignature="${delta.signature}"/>`).join('\n')}\n      </sparkle:deltas>`
  return `    <item>
      <title>${title}</title>${dateXML}${descriptionXML}
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
${branchXML(branch)}
      <enclosure url="${url}" length="${length}" type="application/octet-stream" sparkle:edSignature="${signature}"/>${notesXML}${deltaXML}
    </item>`
}

function appcastXML(items) {
  return `<?xml version="1.0" standalone="yes"?>
<!-- sparkle-sign-warning: fixture signing warning -->
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0" data-feed="primary">
  <channel>
    <title>Mechanician</title>
    <link>https://mechanician.ai/updates</link>
    <!-- channel-policy: preserve unrelated feed comments -->
${items.join('\n')}
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: ${Buffer.alloc(64, 0x66).toString('base64')}
length: 1234
-->
`
}

function objectURL(fixture, object) {
  return `${fixture.urlPrefix}${encodeURIComponent(object)}`
}

function createFixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-promotion-feed-'))
  const stage = path.join(root, 'stage')
  const bin = path.join(root, 'bin')
  const signaturesPath = path.join(root, 'signatures.json')
  const signLog = path.join(root, 'sign-update.log')
  fs.mkdirSync(stage)
  fs.mkdirSync(bin)
  fs.symlinkSync(process.execPath, path.join(bin, 'node'))
  fs.writeFileSync(signaturesPath, '{}')

  const fakeSignUpdate = `#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
const args = process.argv.slice(2)
fs.appendFileSync(process.env.FAKE_SIGN_LOG, JSON.stringify(args) + '\\n')
const verify = args.indexOf('--verify')
if (verify < 0 || verify + 2 >= args.length) process.exit(64)
const archive = args[verify + 1]
const signature = args[verify + 2]
const expected = JSON.parse(fs.readFileSync(process.env.FAKE_SIGNATURES, 'utf8'))[path.basename(archive)]
if (!fs.existsSync(archive) || expected !== signature) process.exit(1)
`
  const signUpdate = path.join(bin, 'sign_update')
  fs.writeFileSync(signUpdate, fakeSignUpdate, { mode: 0o755 })

  const fixture = {
    root,
    stage,
    signLog,
    signaturesPath,
    artifactName: 'Mechanician',
    deltaPrefix: 'Mechanician',
    urlPrefix: 'https://storage.googleapis.com/test-updates/',
  }

  fixture.registerSignature = (name, signature) => {
    const values = JSON.parse(fs.readFileSync(signaturesPath, 'utf8'))
    values[path.basename(name)] = signature
    fs.writeFileSync(signaturesPath, JSON.stringify(values))
  }
  fixture.writeArchive = (name, contents, signature) => {
    fs.writeFileSync(path.join(stage, name), contents)
    fixture.registerSignature(name, signature)
  }
  fixture.writeSource = (feed) => {
    fs.writeFileSync(path.join(stage, '.appcast-before.xml'), feed)
    fs.writeFileSync(path.join(stage, 'appcast.xml'), feed)
  }
  fixture.run = (args) => spawnSync(stager, args, {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
      MECHANICIAN_UPDATE_BUCKET: 'gs://test-updates',
      MECHANICIAN_UPDATE_URL_PREFIX: fixture.urlPrefix,
      MECHANICIAN_ARTIFACT_NAME: fixture.artifactName,
      MECHANICIAN_SIGN_UPDATE: signUpdate,
      MECHANICIAN_XMLLINT: '/usr/bin/xmllint',
      FAKE_SIGNATURES: signaturesPath,
      FAKE_SIGN_LOG: signLog,
    },
  })
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return fixture
}

function seedPromotionSource(fixture, {
  stableBuild = '238',
  stableVersion = '0.26.23',
  dailyBuild = '239',
  dailyVersion = '0.26.24',
  dailyChannel = 'daily',
  deltaFrom = stableBuild,
  includeStable = true,
  extraItems = [],
} = {}) {
  const stableArchive = Buffer.from(`stable-${stableBuild}`)
  const dailyArchive = Buffer.from(`daily-${dailyBuild}`)
  const legacyArchive = Buffer.from('legacy-54')
  const stableName = `${fixture.artifactName}-${stableVersion}.zip`
  const dailyName = `${fixture.artifactName}-${dailyVersion}.zip`
  const legacyName = `${fixture.artifactName}-0.7.31.zip`
  const dailyDelta = `${fixture.deltaPrefix}${dailyBuild}-${deltaFrom}.delta`
  const stableDelta = `${fixture.deltaPrefix}${stableBuild}-${Number(stableBuild) - 1}.delta`
  const legacyDelta = `${fixture.deltaPrefix}54-53.delta`
  const stableItem = itemXML({
    build: stableBuild,
    version: stableVersion,
    branch: platformBranch,
    url: objectURL(fixture, stableName),
    length: stableArchive.length,
    signature: signatures.stable,
    title: `Stable ${stableVersion}`,
    pubDate: 'Mon, 10 Aug 2026 10:00:00 +0000',
    description: '<p>Older stable notes.</p>',
    deltas: [{
      from: String(Number(stableBuild) - 1),
      url: objectURL(fixture, stableDelta),
      length: 13,
      signature: signatures.alternate,
    }],
  })
  const dailyItem = itemXML({
    build: dailyBuild,
    version: dailyVersion,
    branch: { ...platformBranch, channel: dailyChannel },
    url: objectURL(fixture, dailyName),
    length: dailyArchive.length,
    signature: signatures.daily,
    title: `Daily ${dailyVersion}`,
    pubDate: 'Tue, 11 Aug 2026 11:22:33 +0000',
    description: '<h2>Exact daily notes</h2><p>Keep every byte of this body.</p>',
    releaseNotesLink: {
      url: `${fixture.urlPrefix}notes-${dailyVersion}.html`,
      length: '321',
      signature: signatures.alternate,
    },
    deltas: [{
      from: deltaFrom,
      url: objectURL(fixture, dailyDelta),
      length: 17,
      signature: signatures.delta,
    }],
  })
  const legacyItem = itemXML({
    build: '54',
    version: '0.7.31',
    branch: legacyBranch,
    url: objectURL(fixture, legacyName),
    length: legacyArchive.length,
    signature: signatures.legacy,
    title: 'Legacy compatibility leader',
    pubDate: 'Wed, 12 Jul 2023 09:00:00 +0000',
    description: '<p>Legacy notes must remain untouched.</p>',
    deltas: [{
      from: '53',
      url: objectURL(fixture, legacyDelta),
      length: 9,
      signature: signatures.alternate,
    }],
  })
  const items = [dailyItem]
  if (includeStable) items.push(stableItem)
  items.push(legacyItem, ...extraItems)
  fixture.writeSource(appcastXML(items))
  fixture.writeArchive(stableName, stableArchive, signatures.stable)
  fixture.writeArchive(dailyName, dailyArchive, signatures.daily)
  fixture.writeArchive(legacyName, legacyArchive, signatures.legacy)
  return {
    stableBuild,
    stableVersion,
    dailyBuild,
    dailyVersion,
    stableName,
    dailyName,
    legacyName,
    dailyDelta,
    stableDelta,
    legacyDelta,
    stableItem,
    dailyItem,
    legacyItem,
  }
}

function xmlCount(file, expression) {
  const result = spawnSync('/usr/bin/xmllint', ['--nonet', '--xpath', `count(${expression})`, file], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  return Number(result.stdout)
}

function readManifest(stage) {
  return fs.readFileSync(path.join(stage, '.appcast-candidate-objects.tsv'), 'utf8')
    .trim()
    .split('\n')
    .map(line => line.split('\t')[0])
    .sort()
}

test('promotion rewrites only the exact Daily item and displaced Stable leader', (t) => {
  const fixture = createFixture(t)
  const seeded = seedPromotionSource(fixture)

  const prepared = fixture.run([
    'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(prepared.status, 0, prepared.stderr)
  assert.equal(prepared.stdout.trim(), 'promotion-required')
  assert.equal(fs.readFileSync(path.join(fixture.stage, '.promotion-state'), 'utf8').trim(), 'promotion-required')

  const candidate = path.join(fixture.stage, 'appcast.xml')
  assert.equal(xmlCount(candidate, `/rss/channel/item[*[local-name()='version' and text()='${seeded.dailyBuild}'] and not(*[local-name()='channel'])]`), 1)
  assert.equal(xmlCount(candidate, `/rss/channel/item[*[local-name()='version' and text()='${seeded.stableBuild}']]`), 0)
  assert.equal(xmlCount(candidate, "/rss/channel/item[*[local-name()='version' and text()='54'] and *[local-name()='channel' and text()='legacy']]"), 1)
  const candidateText = fs.readFileSync(candidate, 'utf8')
  assert.match(candidateText, /Tue, 11 Aug 2026 11:22:33 \+0000/)
  assert.match(candidateText, /Exact daily notes/)
  assert.match(candidateText, /Keep every byte of this body/)
  assert.match(candidateText, /notes-0\.26\.24\.html/)
  assert.match(candidateText, /Legacy notes must remain untouched/)
  assert.match(candidateText, new RegExp(seeded.dailyDelta.replaceAll('.', '\\.')))

  const verified = fixture.run([
    'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(verified.status, 0, verified.stderr)
  assert.match(verified.stdout, /promotion-required: exact build 239/)
  assert.deepEqual(readManifest(fixture.stage), [
    seeded.dailyDelta,
    seeded.dailyName,
    seeded.legacyDelta,
    seeded.legacyName,
  ].sort())
  assert.equal(readManifest(fixture.stage).includes(seeded.stableName), false)
  assert.equal(readManifest(fixture.stage).includes(seeded.stableDelta), false)
})

test('promotion succeeds without an older Stable leader', (t) => {
  const fixture = createFixture(t)
  const seeded = seedPromotionSource(fixture, { includeStable: false })

  const prepared = fixture.run([
    'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(prepared.status, 0, prepared.stderr)
  assert.equal(prepared.stdout.trim(), 'promotion-required')
  const verified = fixture.run([
    'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(verified.status, 0, verified.stderr)
})

test('an already promoted feed is detected and verified for alias-only resume', (t) => {
  const fixture = createFixture(t)
  const seeded = seedPromotionSource(fixture)
  const first = fixture.run([
    'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(first.status, 0, first.stderr)
  const promoted = fs.readFileSync(path.join(fixture.stage, 'appcast.xml'))
  fs.writeFileSync(path.join(fixture.stage, '.appcast-before.xml'), promoted)

  const resumed = fixture.run([
    'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(resumed.status, 0, resumed.stderr)
  assert.equal(resumed.stdout.trim(), 'already-promoted')
  assert.deepEqual(fs.readFileSync(path.join(fixture.stage, 'appcast.xml')), promoted)

  const verified = fixture.run([
    'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(verified.status, 0, verified.stderr)
  assert.match(verified.stdout, /already-promoted: exact build 239/)
  assert.deepEqual(readManifest(fixture.stage), [
    seeded.dailyDelta,
    seeded.dailyName,
    seeded.legacyDelta,
    seeded.legacyName,
  ].sort())
})

test('promotion verification rejects every semantic mutation after preparation', async (t) => {
  const mutations = [
    ['root metadata', text => text.replace('data-feed="primary"', 'data-feed="secondary"')],
    ['channel metadata', text => text.replace('https://mechanician.ai/updates', 'https://attacker.invalid/updates')],
    ['unrelated channel comment', text => text.replace('preserve unrelated feed comments', 'changed unrelated feed comments')],
    ['target date', text => text.replace('Tue, 11 Aug 2026 11:22:33 +0000', 'Tue, 11 Aug 2026 11:22:34 +0000')],
    ['target notes', text => text.replace('Keep every byte of this body.', 'Changed promotion notes.')],
    ['target enclosure signature', text => text.replace(signatures.daily, signatures.alternate)],
    ['target delta', text => text.replace('sparkle:deltaFrom="238"', 'sparkle:deltaFrom="237"')],
    ['legacy entry', text => text.replace('Legacy notes must remain untouched.', 'Changed legacy notes.')],
    ['restored Daily channel', text => text.replace(
      '<sparkle:shortVersionString>0.26.24</sparkle:shortVersionString>',
      '<sparkle:shortVersionString>0.26.24</sparkle:shortVersionString>\n      <sparkle:channel>daily</sparkle:channel>',
    )],
  ]

  for (const [name, mutate] of mutations) {
    await t.test(name, (t) => {
      const fixture = createFixture(t)
      const seeded = seedPromotionSource(fixture)
      const prepared = fixture.run([
        'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
      ])
      assert.equal(prepared.status, 0, prepared.stderr)
      const candidate = path.join(fixture.stage, 'appcast.xml')
      fs.writeFileSync(candidate, mutate(fs.readFileSync(candidate, 'utf8')))

      const verified = fixture.run([
        'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
      ])
      assert.notEqual(verified.status, 0, `unexpected success for ${name}`)
      assert.equal(fs.existsSync(path.join(fixture.stage, '.appcast-candidate-objects.tsv')), false)
    })
  }
})

test('promotion verification ignores only Sparkle document-level signature comments', (t) => {
  const fixture = createFixture(t)
  const seeded = seedPromotionSource(fixture)
  const prepared = fixture.run([
    'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(prepared.status, 0, prepared.stderr)
  const candidate = path.join(fixture.stage, 'appcast.xml')
  fs.appendFileSync(candidate, '<!-- sparkle-signatures: replacement fixture signature -->\n')
  const verified = fixture.run([
    'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(verified.status, 0, verified.stderr)
})

test('promotion verification rejects restoration of the displaced Stable item', (t) => {
  const fixture = createFixture(t)
  const seeded = seedPromotionSource(fixture)
  const prepared = fixture.run([
    'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.equal(prepared.status, 0, prepared.stderr)
  const candidate = path.join(fixture.stage, 'appcast.xml')
  const mutated = fs.readFileSync(candidate, 'utf8').replace('  </channel>', `${seeded.stableItem}\n  </channel>`)
  fs.writeFileSync(candidate, mutated)

  const verified = fixture.run([
    'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.notEqual(verified.status, 0)
  assert.equal(fs.existsSync(path.join(fixture.stage, '.appcast-candidate-objects.tsv')), false)
})

test('promotion preparation rejects ambiguity, wrong identity, and Stable supersession', async (t) => {
  const cases = [
    {
      name: 'wrong version',
      setup(fixture) {
        const seeded = seedPromotionSource(fixture)
        return { seeded, build: seeded.dailyBuild, version: '0.26.25', pattern: /not requested version/ }
      },
    },
    {
      name: 'non-Daily channel',
      setup(fixture) {
        const seeded = seedPromotionSource(fixture, { dailyChannel: 'beta' })
        return { seeded, build: seeded.dailyBuild, version: seeded.dailyVersion, pattern: /not Daily or default Stable/ }
      },
    },
    {
      name: 'newer Stable leader',
      setup(fixture) {
        const seeded = seedPromotionSource(fixture, {
          stableBuild: '240', stableVersion: '0.26.25', deltaFrom: '238',
        })
        return { seeded, build: seeded.dailyBuild, version: seeded.dailyVersion, pattern: /default-channel Stable head 240 already supersedes/ }
      },
    },
    {
      name: 'target no longer live',
      setup(fixture) {
        seedPromotionSource(fixture)
        return { build: '237', version: '0.26.22', pattern: /may have been superseded/ }
      },
    },
    {
      name: 'duplicate target build',
      setup(fixture) {
        const duplicateArchive = Buffer.from('duplicate-target')
        const duplicateName = `${fixture.artifactName}-0.26.25.zip`
        const duplicate = itemXML({
          build: '239',
          version: '0.26.25',
          branch: { ...legacyBranch, channel: 'beta' },
          url: objectURL(fixture, duplicateName),
          length: duplicateArchive.length,
          signature: signatures.alternate,
        })
        const seeded = seedPromotionSource(fixture, { extraItems: [duplicate] })
        fixture.writeArchive(duplicateName, duplicateArchive, signatures.alternate)
        return { seeded, build: seeded.dailyBuild, version: seeded.dailyVersion, pattern: /duplicate build/ }
      },
    },
  ]

  for (const scenario of cases) {
    await t.test(scenario.name, (t) => {
      const fixture = createFixture(t)
      const configured = scenario.setup(fixture)
      const before = fs.readFileSync(path.join(fixture.stage, '.appcast-before.xml'))
      const prepared = fixture.run([
        'prepare-promotion', fixture.stage, configured.build, configured.version,
      ])
      assert.notEqual(prepared.status, 0, `unexpected success for ${scenario.name}`)
      assert.match(prepared.stderr, configured.pattern)
      assert.deepEqual(fs.readFileSync(path.join(fixture.stage, '.appcast-before.xml')), before)
      assert.equal(fs.existsSync(path.join(fixture.stage, '.promotion-state')), false)
    })
  }
})

test('promotion rejects a newer global Stable head on another compatibility branch', (t) => {
  const fixture = createFixture(t)
  const futureArchive = Buffer.from('future-unrelated-stable')
  const futureName = `${fixture.artifactName}-0.26.25.zip`
  const futureItem = itemXML({
    build: '240',
    version: '0.26.25',
    branch: { ...legacyBranch, channel: undefined },
    url: objectURL(fixture, futureName),
    length: futureArchive.length,
    signature: signatures.alternate,
  })
  const seeded = seedPromotionSource(fixture, { extraItems: [futureItem] })
  fixture.writeArchive(futureName, futureArchive, signatures.alternate)

  const prepared = fixture.run([
    'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
  ])
  assert.notEqual(prepared.status, 0)
  assert.match(prepared.stderr, /default-channel Stable head 240 already supersedes/)
  assert.equal(fs.existsSync(path.join(fixture.stage, '.promotion-state')), false)
})

test('already-promoted alias recovery requires the target to remain the global Stable head', (t) => {
  const fixture = createFixture(t)
  const seeded = seedPromotionSource(fixture)
  const first = fixture.run(['prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion])
  assert.equal(first.status, 0, first.stderr)
  let promoted = fs.readFileSync(path.join(fixture.stage, 'appcast.xml'), 'utf8')
  const futureArchive = Buffer.from('future-unrelated-stable')
  const futureName = `${fixture.artifactName}-0.26.25.zip`
  const futureItem = itemXML({
    build: '240', version: '0.26.25', branch: { ...legacyBranch, channel: undefined },
    url: objectURL(fixture, futureName), length: futureArchive.length, signature: signatures.alternate,
  })
  promoted = promoted.replace('  </channel>', `${futureItem}\n  </channel>`)
  fs.writeFileSync(path.join(fixture.stage, '.appcast-before.xml'), promoted)
  fixture.writeArchive(futureName, futureArchive, signatures.alternate)

  const resumed = fixture.run(['prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion])
  assert.notEqual(resumed.status, 0)
  assert.match(resumed.stderr, /newer default-channel Stable head 240 blocks alias reconciliation/)
  assert.equal(fs.existsSync(path.join(fixture.stage, '.promotion-state')), false)
})

test('nested signature-looking comments remain semantic', (t) => {
  const fixture = createFixture(t)
  const seeded = seedPromotionSource(fixture)
  const prepared = fixture.run(['prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion])
  assert.equal(prepared.status, 0, prepared.stderr)
  const candidate = path.join(fixture.stage, 'appcast.xml')
  fs.writeFileSync(candidate, fs.readFileSync(candidate, 'utf8').replace(
    '<title>Mechanician</title>',
    '<title>Mechanician</title><!-- sparkle-signatures: nested attacker comment -->',
  ))
  const verified = fixture.run(['verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion])
  assert.notEqual(verified.status, 0)
})

test('promotion verification fails closed on stale state and archive integrity', async (t) => {
  await t.test('stale state', (t) => {
    const fixture = createFixture(t)
    const seeded = seedPromotionSource(fixture)
    const prepared = fixture.run([
      'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
    ])
    assert.equal(prepared.status, 0, prepared.stderr)
    fs.writeFileSync(path.join(fixture.stage, '.promotion-state'), 'already-promoted\n')
    const verified = fixture.run([
      'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
    ])
    assert.notEqual(verified.status, 0)
    assert.match(verified.stderr, /state does not match/)
  })

  await t.test('archive signature', (t) => {
    const fixture = createFixture(t)
    const seeded = seedPromotionSource(fixture)
    const prepared = fixture.run([
      'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
    ])
    assert.equal(prepared.status, 0, prepared.stderr)
    fixture.registerSignature(seeded.dailyName, signatures.alternate)
    const verified = fixture.run([
      'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
    ])
    assert.notEqual(verified.status, 0)
    assert.match(verified.stderr, /signature verification failed/)
  })

  await t.test('a failed re-verification clears a previously valid object manifest', (t) => {
    const fixture = createFixture(t)
    const seeded = seedPromotionSource(fixture)
    const prepared = fixture.run([
      'prepare-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
    ])
    assert.equal(prepared.status, 0, prepared.stderr)
    const first = fixture.run([
      'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
    ])
    assert.equal(first.status, 0, first.stderr)
    assert.equal(fs.existsSync(path.join(fixture.stage, '.appcast-candidate-objects.tsv')), true)
    const candidate = path.join(fixture.stage, 'appcast.xml')
    fs.writeFileSync(candidate, fs.readFileSync(candidate, 'utf8').replace(
      'Keep every byte of this body.', 'Mutation after successful verification.',
    ))
    const second = fixture.run([
      'verify-promotion', fixture.stage, seeded.dailyBuild, seeded.dailyVersion,
    ])
    assert.notEqual(second.status, 0)
    assert.equal(fs.existsSync(path.join(fixture.stage, '.appcast-candidate-objects.tsv')), false)
  })
})

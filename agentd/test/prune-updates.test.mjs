import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '../..')
const pruner = path.join(repo, 'scripts/prune-updates.sh')

const validAppcast = `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>97</sparkle:version>
    <enclosure url="https://storage.googleapis.com/test-updates/releases/Mechanician-0.8.35.zip" />
    <sparkle:deltas>
      <enclosure url="https://storage.googleapis.com/test-updates/deltas/Mechanician97-96.delta" />
    </sparkle:deltas>
  </item></channel>
</rss>
`

function createFixture(t, { appcast = validAppcast, omit = [] } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-prune-test-'))
  const bin = path.join(root, 'bin')
  const statePath = path.join(root, 'state.json')
  const appcastPath = path.join(root, 'appcast.xml')
  const logPath = path.join(root, 'gcloud.log')
  fs.mkdirSync(bin)
  fs.symlinkSync(process.execPath, path.join(bin, 'node'))
  fs.writeFileSync(appcastPath, appcast)

  const state = {
    'appcast.xml': 500,
    'Mechanician-latest.dmg': 1_000,
    'Mechanician-latest.zip': 900,
    'releases/Mechanician-0.8.35.zip': 700,
    'deltas/Mechanician97-96.delta': 100,
    'orphan/Mechanician-0.7.1.zip': 600,
  }
  for (const object of omit) delete state[object]
  fs.writeFileSync(statePath, JSON.stringify(state))

  const fakeGcloud = `#!/usr/bin/env node
import fs from 'node:fs'

const args = process.argv.slice(2)
const statePath = process.env.FAKE_GCLOUD_STATE
const appcastPath = process.env.FAKE_GCLOUD_APPCAST
const logPath = process.env.FAKE_GCLOUD_LOG
const bucket = process.env.MECHANICIAN_UPDATE_BUCKET
const state = () => JSON.parse(fs.readFileSync(statePath, 'utf8'))

if (args[0] !== 'storage') process.exit(2)
if (args[1] === 'objects' && args[2] === 'describe') {
  process.stdout.write('100')
  process.exit(0)
}
if (args[1] === 'cat') {
  process.stdout.write(fs.readFileSync(appcastPath))
  process.exit(0)
}
if (args[1] === 'ls') {
  const objects = state()
  for (const name of Object.keys(objects).sort()) {
    const size = objects[name]
    process.stdout.write(bucket + '/' + name + ':\\n')
    process.stdout.write('  Creation Time:               2026-07-15T00:00:00Z\\n')
    process.stdout.write('  Content-Length:              ' + size + '\\n')
  }
  process.exit(0)
}
if (args[1] === 'rm') {
  const objects = state()
  for (const url of args.slice(2)) delete objects[url.slice((bucket + '/').length)]
  fs.writeFileSync(statePath, JSON.stringify(objects))
  fs.appendFileSync(logPath, 'rm ' + args.slice(2).join(' ') + '\\n')
  process.exit(0)
}
process.exit(2)
`
  const gcloudPath = path.join(bin, 'gcloud')
  fs.writeFileSync(gcloudPath, fakeGcloud, { mode: 0o755 })

  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return { root, bin, statePath, appcastPath, logPath }
}

function runPruner(fixture, args = []) {
  return spawnSync(pruner, args, {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${fixture.bin}:/usr/bin:/bin`,
      MECHANICIAN_UPDATE_BUCKET: 'gs://test-updates',
      FAKE_GCLOUD_STATE: fixture.statePath,
      FAKE_GCLOUD_APPCAST: fixture.appcastPath,
      FAKE_GCLOUD_LOG: fixture.logPath,
    },
  })
}

test('pruner dry-run retains feed and stable artifacts without mutating the bucket', (t) => {
  const fixture = createFixture(t)
  const before = fs.readFileSync(fixture.statePath, 'utf8')
  const result = runPruner(fixture, ['--verbose'])

  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /delete:\s+1 objects, 600\.00 B/)
  assert.match(result.stdout, /releases\/Mechanician-0\.8\.35\.zip/)
  assert.match(result.stdout, /deltas\/Mechanician97-96\.delta/)
  assert.match(result.stdout, /orphan\/Mechanician-0\.7\.1\.zip/)
  assert.match(result.stdout, /DRY RUN/)
  assert.equal(fs.readFileSync(fixture.statePath, 'utf8'), before)
  assert.equal(fs.existsSync(fixture.logPath), false)
})

test('pruner apply deletes only unreferenced objects and re-verifies retained objects', (t) => {
  const fixture = createFixture(t)
  const result = runPruner(fixture, ['--apply'])

  assert.equal(result.status, 0, result.stderr)
  const objects = JSON.parse(fs.readFileSync(fixture.statePath, 'utf8'))
  assert.deepEqual(Object.keys(objects).sort(), [
    'Mechanician-latest.dmg',
    'Mechanician-latest.zip',
    'appcast.xml',
    'deltas/Mechanician97-96.delta',
    'releases/Mechanician-0.8.35.zip',
  ])
  assert.match(fs.readFileSync(fixture.logPath, 'utf8'), /orphan\/Mechanician-0\.7\.1\.zip/)
  assert.match(result.stdout, /prune complete: 5 live objects remain/)
})

test('pruner refuses a feed that references a missing object before deletion', (t) => {
  const fixture = createFixture(t, { omit: ['deltas/Mechanician97-96.delta'] })
  const before = fs.readFileSync(fixture.statePath, 'utf8')
  const result = runPruner(fixture, ['--apply'])

  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /required object is missing: .*Mechanician97-96\.delta/)
  assert.equal(fs.readFileSync(fixture.statePath, 'utf8'), before)
  assert.equal(fs.existsSync(fixture.logPath), false)
})

test('pruner refuses malformed or unrecognized feeds before deletion', (t) => {
  for (const appcast of [
    '<rss><channel></channel></rss>',
    '<rss xmlns:sparkle="x"><sparkle:version>97</sparkle:version></rss>',
  ]) {
    const fixture = createFixture(t, { appcast })
    const before = fs.readFileSync(fixture.statePath, 'utf8')
    const result = runPruner(fixture, ['--apply'])

    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /refusing to prune/)
    assert.equal(fs.readFileSync(fixture.statePath, 'utf8'), before)
    assert.equal(fs.existsSync(fixture.logPath), false)
  }
})

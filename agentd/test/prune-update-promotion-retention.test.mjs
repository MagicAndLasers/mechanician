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

const liveAppcast = `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>238</sparkle:version>
      <sparkle:shortVersionString>0.26.23</sparkle:shortVersionString>
      <enclosure url="https://storage.googleapis.com/test-updates/Mechanician-0.26.23.zip" />
    </item>
    <item>
      <sparkle:version>239</sparkle:version>
      <sparkle:shortVersionString>0.26.24</sparkle:shortVersionString>
      <sparkle:channel>daily</sparkle:channel>
      <enclosure url="https://storage.googleapis.com/test-updates/Mechanician-0.26.24.zip" />
    </item>
  </channel>
</rss>
`

function createFixture(t, extraObjects = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-promotion-prune-test-'))
  const bin = path.join(root, 'bin')
  const statePath = path.join(root, 'state.json')
  const appcastPath = path.join(root, 'appcast.xml')
  const logPath = path.join(root, 'gcloud.log')
  fs.mkdirSync(bin)
  fs.symlinkSync(process.execPath, path.join(bin, 'node'))
  fs.writeFileSync(appcastPath, liveAppcast)
  fs.writeFileSync(statePath, JSON.stringify({
    'appcast.xml': 500,
    'Mechanician-latest.dmg': 1_000,
    'Mechanician-latest.zip': 900,
    'Mechanician-0.26.23.zip': 700,
    'Mechanician-0.26.24.zip': 710,
    ...extraObjects,
  }))

  const fakeGcloud = `#!/usr/bin/env node
import fs from 'node:fs'

const args = process.argv.slice(2)
const statePath = process.env.FAKE_GCLOUD_STATE
const appcastPath = process.env.FAKE_GCLOUD_APPCAST
const logPath = process.env.FAKE_GCLOUD_LOG
const bucket = process.env.MECHANICIAN_UPDATE_BUCKET
const readState = () => JSON.parse(fs.readFileSync(statePath, 'utf8'))

if (args[0] !== 'storage') process.exit(2)
if (args[1] === 'objects' && args[2] === 'describe') {
  process.stdout.write(process.env.FAKE_APPCAST_GENERATION ?? '100')
  process.exit(0)
}
if (args[1] === 'cat') {
  process.stdout.write(fs.readFileSync(appcastPath))
  process.exit(0)
}
if (args[1] === 'ls') {
  const objects = readState()
  for (const name of Object.keys(objects).sort()) {
    process.stdout.write(bucket + '/' + name + ':\\n')
    process.stdout.write('  Creation Time:               2026-08-01T00:00:00Z\\n')
    process.stdout.write('  Content-Length:              ' + objects[name] + '\\n')
  }
  process.exit(0)
}
if (args[1] === 'rm') {
  const objects = readState()
  for (const url of args.slice(2)) delete objects[url.slice((bucket + '/').length)]
  fs.writeFileSync(statePath, JSON.stringify(objects))
  fs.appendFileSync(logPath, 'rm ' + args.slice(2).join(' ') + '\\n')
  process.exit(0)
}
process.exit(2)
`
  fs.writeFileSync(path.join(bin, 'gcloud'), fakeGcloud, { mode: 0o755 })

  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return { bin, statePath, appcastPath, logPath }
}

function runPruner(fixture, args = ['--apply'], extraEnvironment = {}) {
  return spawnSync(pruner, args, {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${fixture.bin}:/usr/bin:/bin`,
      MECHANICIAN_UPDATE_BUCKET: 'gs://test-updates',
      FAKE_GCLOUD_STATE: fixture.statePath,
      FAKE_GCLOUD_APPCAST: fixture.appcastPath,
      FAKE_GCLOUD_LOG: fixture.logPath,
      ...extraEnvironment,
    },
  })
}

test('pruner retains promotable artifacts for every live Stable and Daily feed item', (t) => {
  const fixture = createFixture(t, {
    'Mechanician-0.26.23.dmg': 1_100,
    'Mechanician-0.26.23-238-provenance.json': 80,
    'Mechanician-0.26.24.dmg': 1_120,
    'Mechanician-0.26.24-239-stable-promotion-authorization.json': 90,
    'unrelated.bin': 50,
  })
  const result = runPruner(fixture)

  assert.equal(result.status, 0, result.stderr)
  const objects = JSON.parse(fs.readFileSync(fixture.statePath, 'utf8'))
  assert.equal(objects['Mechanician-0.26.23.dmg'], 1_100)
  assert.equal(objects['Mechanician-0.26.24.dmg'], 1_120)
  assert.equal(objects['Mechanician-0.26.24-239-stable-promotion-authorization.json'], 90)
  assert.equal(objects['Mechanician-0.26.23-238-stable-promotion-authorization.json'], undefined,
    'a missing historical optional record must remain nonfatal')
  assert.equal(objects['unrelated.bin'], undefined)
  assert.match(result.stdout, /Optional release artifacts retained/)
  assert.match(result.stdout, /Mechanician-0\.26\.24-239-stable-promotion-authorization\.json/)
})

test('pruner rejects wildcard and prefixed bucket targets before invoking gcloud', (t) => {
  const fixture = createFixture(t)
  for (const bucket of ['gs://*', 'gs://test-updates/prefix']) {
    const result = runPruner(fixture, ['--apply'], { MECHANICIAN_UPDATE_BUCKET: bucket })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /canonical root gs:\/\/ bucket/)
  }
  assert.equal(fs.existsSync(fixture.logPath), false)
})

test('pruner deletes DMGs and promotion attestations that belong to no live feed item', (t) => {
  const fixture = createFixture(t, {
    'Mechanician-0.26.24.dmg': 1_120,
    'Mechanician-0.26.24-239-stable-promotion-authorization.json': 90,
    'Mechanician-0.26.22.dmg': 1_080,
    'Mechanician-0.26.22-237-stable-promotion-authorization.json': 88,
    'Mechanician-0.26.24-238-stable-promotion-authorization.json': 87,
  })
  const result = runPruner(fixture)

  assert.equal(result.status, 0, result.stderr)
  const objects = JSON.parse(fs.readFileSync(fixture.statePath, 'utf8'))
  assert.equal(objects['Mechanician-0.26.24.dmg'], 1_120)
  assert.equal(objects['Mechanician-0.26.24-239-stable-promotion-authorization.json'], 90)
  assert.equal(objects['Mechanician-0.26.22.dmg'], undefined)
  assert.equal(objects['Mechanician-0.26.22-237-stable-promotion-authorization.json'], undefined)
  assert.equal(objects['Mechanician-0.26.24-238-stable-promotion-authorization.json'], undefined,
    'attestation retention is scoped to both version and build')
  const deletionLog = fs.readFileSync(fixture.logPath, 'utf8')
  assert.match(deletionLog, /Mechanician-0\.26\.22\.dmg/)
  assert.match(deletionLog, /Mechanician-0\.26\.22-237-stable-promotion-authorization\.json/)
  assert.match(deletionLog, /Mechanician-0\.26\.24-238-stable-promotion-authorization\.json/)
})

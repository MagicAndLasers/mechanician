import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '../..')
const generator = path.join(repo, 'scripts/generate-release-notes.sh')

function runGit(repository, args) {
  const result = spawnSync('git', ['-C', repository, ...args], {
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'Release Notes Test',
      GIT_AUTHOR_EMAIL: 'release-notes@example.invalid',
      GIT_COMMITTER_NAME: 'Release Notes Test',
      GIT_COMMITTER_EMAIL: 'release-notes@example.invalid',
    },
  })
  assert.equal(result.status, 0, result.stderr)
  return result.stdout.trim()
}

function commit(repository, subject, sequence) {
  fs.writeFileSync(path.join(repository, 'sequence.txt'), `${sequence}\n`)
  runGit(repository, ['add', 'sequence.txt'])
  runGit(repository, ['commit', '-q', '-m', subject])
}

function createRepository(t) {
  const repository = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-release-notes-'))
  t.after(() => fs.rmSync(repository, { recursive: true, force: true }))
  runGit(repository, ['init', '-q', '-b', 'main'])
  return repository
}

function render(repository, range) {
  return spawnSync(generator, [repository, range, 'chore(release)', '0.26.34'], {
    encoding: 'utf8',
  })
}

test('generated release notes tolerate an empty metadata-only range', (t) => {
  const repository = createRepository(t)
  commit(repository, 'chore(release): 0.26.33 (daily)', 1)
  const previousRelease = runGit(repository, ['rev-parse', 'HEAD'])
  commit(repository, 'chore(release): integrate 0.26.34 daily', 2)

  const result = render(repository, `${previousRelease}..HEAD`)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, "<h2>What's new in 0.26.34</h2><ul>\n</ul>\n")
})

test('generated release notes escape, normalize, and bound subjects without SIGPIPE', (t) => {
  const repository = createRepository(t)
  commit(repository, 'chore(release): 0.26.33 (daily)', 1)
  const previousRelease = runGit(repository, ['rev-parse', 'HEAD'])
  commit(repository, 'chore(release): integrate 0.26.34 daily', 2)
  for (let index = 1; index <= 24; index += 1) {
    commit(repository, `fix(notes): generated item ${index}`, index + 2)
  }
  commit(repository, 'fix(ui): escape <chips> & prompts', 27)

  const result = render(repository, `${previousRelease}..HEAD`)
  assert.equal(result.status, 0, result.stderr)
  const items = [...result.stdout.matchAll(/<li>(.*?)<\/li>/g)].map(match => match[1])
  assert.equal(items.length, 20)
  assert.equal(items[0], 'Escape &lt;chips&gt; &amp; prompts')
  assert.equal(items[1], 'Generated item 24')
  assert.doesNotMatch(result.stdout, /integrate 0\.26\.34/)
  assert.match(result.stdout, /<\/ul>\n$/)
})

test('release transaction derives both channel boundaries from tagged live-feed leaders', () => {
  const source = fs.readFileSync(path.join(repo, 'scripts/release.sh'), 'utf8')
  assert.match(source, /PREV_CHANNEL_VERSION=.*--channel-leader/s)
  assert.match(source, /refs\/tags\/\$PREV_CHANNEL_TAG\^\{commit\}/)
  assert.doesNotMatch(source, /--grep="\^\$RELEASE_COMMIT_PREFIX:"/)
  assert.match(source, /"\$RELEASE_NOTES_GENERATOR" "\$REPO" "\$RANGE"/)
})

test('channel boundary follows the highest live item eligible for its audience', (t) => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-release-channel-'))
  t.after(() => fs.rmSync(fixture, { recursive: true, force: true }))
  const items = path.join(fixture, 'items.tsv')
  const row = (build, version, channel) => [
    build, version, 'unused', 'unused', 'unused', 'unused',
    'unused', 'unused', 'unused', 'unused', 'unused', channel,
  ].join('\t')
  fs.writeFileSync(items, `${row(248, '0.26.33', 'daily')}\n${row(249, '0.26.34', '')}\n`)

  const stable = spawnSync(generator, ['--channel-leader', items, 'stable'], { encoding: 'utf8' })
  const daily = spawnSync(generator, ['--channel-leader', items, 'daily'], { encoding: 'utf8' })
  assert.equal(stable.status, 0, stable.stderr)
  assert.equal(daily.status, 0, daily.stderr)
  assert.equal(stable.stdout, '0.26.34\n')
  assert.equal(daily.stdout, '0.26.34\n')

  fs.appendFileSync(items, row(250, '0.26.35', 'daily') + '\n')
  const newerDaily = spawnSync(generator, ['--channel-leader', items, 'daily'], { encoding: 'utf8' })
  assert.equal(newerDaily.status, 0, newerDaily.stderr)
  assert.equal(newerDaily.stdout, '0.26.35\n')
})

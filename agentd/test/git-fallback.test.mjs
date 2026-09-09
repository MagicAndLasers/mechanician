import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import git from 'isomorphic-git'
import { diffFallback, findRepoRoot, statusFallback } from '../src/git-fallback.mjs'

const temporaryRepos = []

async function makeRepo(files = { 'tracked.txt': 'base\n' }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-git-fallback-'))
  temporaryRepos.push(dir)
  await git.init({ fs, dir, defaultBranch: 'main' })
  for (const [filepath, contents] of Object.entries(files)) {
    const absolute = path.join(dir, filepath)
    fs.mkdirSync(path.dirname(absolute), { recursive: true })
    fs.writeFileSync(absolute, contents)
    await git.add({ fs, dir, filepath })
  }
  await git.commit({
    fs,
    dir,
    message: 'initial',
    author: { name: 'Mechanician Test', email: 'test@example.invalid' },
  })
  return dir
}

test.afterEach(() => {
  for (const dir of temporaryRepos.splice(0)) fs.rmSync(dir, { recursive: true, force: true })
})

test('findRepoRoot locates a repository from a nested folder', async () => {
  const dir = await makeRepo()
  const nested = path.join(dir, 'one', 'two')
  fs.mkdirSync(nested, { recursive: true })
  assert.equal(findRepoRoot(nested), dir)
})

test('statusFallback handles an unborn repository', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-git-fallback-'))
  temporaryRepos.push(dir)
  await git.init({ fs, dir, defaultBranch: 'main' })
  fs.writeFileSync(path.join(dir, 'first.txt'), 'first\n')

  const status = await statusFallback(dir)
  assert.equal(status.branch, 'main')
  assert.equal(status.files[0].path, 'first.txt')
  assert.equal(status.files[0].untracked, true)
})

test('statusFallback reports a staged deletion without a duplicate worktree deletion', async () => {
  const dir = await makeRepo()
  fs.unlinkSync(path.join(dir, 'tracked.txt'))
  await git.remove({ fs, dir, filepath: 'tracked.txt' })

  const status = await statusFallback(dir)
  assert.deepEqual(status.files, [{
    path: 'tracked.txt', originalPath: null, paths: ['tracked.txt'],
    x: 'D', y: ' ', staged: true, untracked: false,
  }])
  const diff = await diffFallback(dir, 'tracked.txt', { staged: true })
  assert.match(diff, /-base/)
})

test('diffFallback keeps staged and unstaged sides separate', async () => {
  const dir = await makeRepo()
  fs.writeFileSync(path.join(dir, 'tracked.txt'), 'staged\n')
  await git.add({ fs, dir, filepath: 'tracked.txt' })
  fs.writeFileSync(path.join(dir, 'tracked.txt'), 'worktree\n')

  const status = await statusFallback(dir)
  assert.equal(status.files[0].x, 'M')
  assert.equal(status.files[0].y, 'M')

  const staged = await diffFallback(dir, 'tracked.txt', { staged: true })
  assert.match(staged, /-base/)
  assert.match(staged, /\+staged/)
  assert.doesNotMatch(staged, /worktree/)

  const unstaged = await diffFallback(dir, 'tracked.txt')
  assert.match(unstaged, /-staged/)
  assert.match(unstaged, /\+worktree/)
  assert.doesNotMatch(unstaged, /-base/)
})

test('diffFallback renders an untracked file against an empty side', async () => {
  const dir = await makeRepo()
  fs.writeFileSync(path.join(dir, 'new.txt'), 'new line\n')

  const status = await statusFallback(dir)
  const untracked = status.files.find(file => file.path === 'new.txt')
  assert.equal(untracked?.x, '?')
  assert.equal(untracked?.y, '?')

  const diff = await diffFallback(dir, 'new.txt', { untracked: true })
  assert.match(diff, /\+new line/)
})

test('diffFallback rejects paths outside the worktree', async () => {
  const dir = await makeRepo()
  await assert.rejects(
    diffFallback(dir, '../outside.txt'),
    /outside the repository worktree/,
  )
  await assert.rejects(
    diffFallback(dir, '.git/config'),
    /outside the repository worktree/,
  )
})

test('diffFallback does not decode binary content as text', async () => {
  const dir = await makeRepo({ 'binary.dat': Buffer.from([0, 1, 2, 3]) })
  fs.writeFileSync(path.join(dir, 'binary.dat'), Buffer.from([0, 4, 5, 6]))

  const diff = await diffFallback(dir, 'binary.dat')
  assert.match(diff, /Binary files .* differ/)
})

import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')
const systemGit = '/usr/bin/git'

function runGit(cwd, args) {
  return execFileSync(systemGit, args, { cwd, encoding: 'utf8' })
}

function startAgentd(t, { withGit = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-git-controls-'))
  const config = path.join(root, 'config')
  const bin = path.join(root, 'bin')
  fs.mkdirSync(config)
  fs.mkdirSync(bin)
  if (withGit) fs.symlinkSync(systemGit, path.join(bin, 'git'))
  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: config,
      OPENAI_API_KEY: '',
      ANTHROPIC_API_KEY: '',
      PATH: bin,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => {
    child.kill()
    fs.rmSync(root, { recursive: true, force: true })
  })
  return { child, events, root }
}

async function waitFor(predicate, description, timeout = 5000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}`)
}

function request(child, body) {
  child.stdin.write(`${JSON.stringify(body)}\n`)
}

test('Git controls remain repo-rooted and preserve literal rename paths', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  const workspace = path.join(repo, 'subfolder')
  fs.mkdirSync(workspace, { recursive: true })
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'old name.txt'), 'old\n')
  fs.writeFileSync(path.join(workspace, 'file with spaces.txt'), 'before\n')
  runGit(repo, ['add', '--', '.'])
  runGit(repo, ['commit', '-qm', 'initial'])

  fs.appendFileSync(path.join(workspace, 'file with spaces.txt'), 'after\n')
  runGit(repo, ['mv', '--', 'old name.txt', 'new name.txt'])
  fs.mkdirSync(path.join(repo, 'untracked folder'))
  fs.writeFileSync(path.join(repo, 'untracked folder', 'one.txt'), 'one\n')
  fs.writeFileSync(path.join(repo, 'untracked folder', 'two.txt'), 'two\n')

  const expectedHead = runGit(repo, ['rev-parse', 'HEAD']).trim()
  const expectedRef = runGit(repo, ['symbolic-ref', 'HEAD']).trim()
  const requestedAt = Date.now() / 1000
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  request(child, {
    type: 'git_status', id: 'status-1', cwd: workspace,
    candidateOIDs: [expectedHead], frozenTargetOID: expectedHead,
  })
  const status = await waitFor(
    () => events.find((event) => event.type === 'git_status_result' && event.id === 'status-1'),
    'nested-workspace Git status')

  assert.equal(status.isRepo, true)
  assert.equal(status.toplevel, fs.realpathSync(repo))
  assert.equal(status.repositoryEvidence.state, 'available')
  assert.ok(status.repositoryEvidence.checkedAt >= requestedAt)
  assert.equal(status.repositoryEvidence.worktreeRoot, fs.realpathSync(repo))
  assert.equal(status.repositoryEvidence.gitCommonDir, fs.realpathSync(path.join(repo, '.git')))
  assert.deepEqual(status.repositoryEvidence.head, {
    state: 'attached', oid: expectedHead, symbolicRef: expectedRef,
  })
  assert.ok(status.repositoryEvidence.localBranches.some((branch) =>
    branch.ref === expectedRef && branch.tipOID === expectedHead))
  assert.deepEqual(status.repositoryEvidence.commitReachability, [{
    oid: expectedHead, resolvedOID: expectedHead, state: 'available',
    localBranchRefs: [expectedRef], targetRelationship: 'equal',
  }])
  assert.deepEqual(status.repositoryEvidence.frozenTarget, {
    requestedOID: expectedHead, resolvedOID: expectedHead,
    relationship: 'equal', ahead: 0, behind: 0,
  })
  assert.ok(status.repositoryEvidence.registeredWorktrees.some((worktree) =>
    worktree.path === fs.realpathSync(repo)
      && worktree.symbolicRef === expectedRef
      && worktree.headOID === expectedHead))
  const rename = status.files.find((file) => file.path === 'new name.txt')
  assert.ok(rename)
  assert.equal(rename.originalPath, 'old name.txt')
  assert.deepEqual(rename.paths, ['old name.txt', 'new name.txt'])
  assert.ok(status.files.some((file) => file.path === 'subfolder/file with spaces.txt'))
  assert.deepEqual(
    status.files.filter((file) => file.untracked).map((file) => file.path).sort(),
    ['untracked folder/one.txt', 'untracked folder/two.txt'])

  request(child, {
    type: 'git_diff', id: 'diff-rename', cwd: workspace, staged: true,
    path: rename.path, paths: rename.paths,
  })
  const diff = await waitFor(
    () => events.find((event) => event.type === 'git_diff_result' && event.id === 'diff-rename'),
    'staged rename diff')
  assert.match(diff.diff, /rename from old name\.txt/)
  assert.match(diff.diff, /rename to new name\.txt/)

  request(child, {
    type: 'git_unstage', id: 'unstage-rename', cwd: workspace,
    path: rename.path, paths: rename.paths,
  })
  const unstaged = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'unstage-rename'),
    'rename unstage')
  assert.equal(unstaged.ok, true)
  assert.equal(runGit(repo, ['diff', '--cached', '--name-only']).trim(), '')

  request(child, {
    type: 'git_stage', id: 'stage-rename', cwd: workspace,
    path: rename.path, paths: rename.paths,
  })
  const staged = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'stage-rename'),
    'rename restage')
  assert.equal(staged.ok, true)
  assert.match(runGit(repo, ['diff', '--cached', '--name-status']), /^R/)

  request(child, { type: 'git_stage', id: 'stage-missing', cwd: workspace })
  request(child, { type: 'git_unstage', id: 'unstage-missing', cwd: workspace })
  const missingStage = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'stage-missing'),
    'missing stage path')
  const missingUnstage = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'unstage-missing'),
    'missing unstage path')
  assert.equal(missingStage.ok, false)
  assert.equal(missingUnstage.ok, false)
  assert.match(missingStage.message, /No file path/)
  assert.match(missingUnstage.message, /No file path/)
})

test('Git status distinguishes non-repositories from repository failures', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'broken-repo')
  const plain = path.join(root, 'plain-folder')
  fs.mkdirSync(repo)
  fs.mkdirSync(plain)
  runGit(repo, ['init', '-q'])
  fs.writeFileSync(path.join(repo, 'file.txt'), 'content\n')
  runGit(repo, ['add', '--', 'file.txt'])

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  request(child, { type: 'git_status', id: 'plain-status', cwd: plain })
  const nonRepo = await waitFor(
    () => events.find((event) => event.type === 'git_status_result' && event.id === 'plain-status'),
    'non-repository status')
  assert.equal(nonRepo.isRepo, false)
  assert.equal(nonRepo.statusUnavailable, undefined)
  assert.equal(nonRepo.repositoryEvidence.state, 'not_repository')
  assert.equal(nonRepo.repositoryEvidence.head.state, 'unavailable')

  fs.writeFileSync(path.join(repo, '.git', 'index'), 'not a valid Git index')
  request(child, { type: 'git_status', id: 'broken-status', cwd: repo })
  const broken = await waitFor(
    () => events.find((event) => event.type === 'git_status_result' && event.id === 'broken-status'),
    'failed repository status')
  assert.equal(broken.isRepo, true)
  assert.equal(broken.statusUnavailable, true)
  assert.match(broken.message, /index|fatal/i)
})

test('Git status attributes clean activity only to a newer path commit', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo)
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  const committed = path.join(repo, 'committed.txt')
  const unresolved = path.join(repo, 'unresolved.txt')
  fs.writeFileSync(committed, 'before\n')
  fs.writeFileSync(unresolved, 'unchanged\n')
  runGit(repo, ['add', '--', '.'])
  runGit(repo, ['commit', '-qm', 'initial'])
  const editedAt = Math.floor(Date.now() / 1000) - 1
  fs.writeFileSync(committed, 'after\n')
  const committedDigest = createHash('sha256').update(fs.readFileSync(committed)).digest('hex')
  runGit(repo, ['add', '--', 'committed.txt'])
  runGit(repo, ['commit', '-qm', 'agent edit'])

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  request(child, {
    type: 'git_status', id: 'activity-status', cwd: repo,
    activity: [
      { path: committed, editedAt, digest: committedDigest },
      { path: unresolved, editedAt: Date.now() / 1000 + 60, digest: '0'.repeat(64) },
      { path: path.join(root, 'outside.txt'), editedAt, digest: '0'.repeat(64) },
    ],
  })
  const status = await waitFor(
    () => events.find((event) => event.type === 'git_status_result' && event.id === 'activity-status'),
    'activity provenance status')
  assert.equal(status.files.length, 0)
  assert.equal(status.activityCommits.length, 1)
  assert.equal(status.activityCommits[0].path, committed)
  assert.match(status.activityCommits[0].commit, /^[0-9a-f]{7}$/)
  assert.equal(status.activityCommits[0].fullCommit, runGit(repo, ['rev-parse', 'HEAD']).trim())
  assert.equal(status.activityCommits[0].digest, committedDigest)
  assert.deepEqual(status.repositoryEvidence.commitReachability, [{
    oid: status.activityCommits[0].fullCommit,
    resolvedOID: status.activityCommits[0].fullCommit,
    state: 'available',
    localBranchRefs: [runGit(repo, ['symbolic-ref', 'HEAD']).trim()],
    targetRelationship: 'equal',
  }])
})

test('built-in Git reads work without developer tools and writes remain actionable', async (t) => {
  const { child, events, root } = startAgentd(t, { withGit: false })
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo)
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'file.txt'), 'before\n')
  runGit(repo, ['add', '--', 'file.txt'])
  runGit(repo, ['commit', '-qm', 'initial'])
  fs.writeFileSync(path.join(repo, 'file.txt'), 'after\n')

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  request(child, { type: 'git_status', id: 'fallback-status', cwd: repo })
  const status = await waitFor(
    () => events.find((event) => event.type === 'git_status_result' && event.id === 'fallback-status'),
    'built-in Git status')
  assert.equal(status.isRepo, true)
  assert.equal(status.viaFallback, true)
  assert.equal(status.writeToolError, 'dev_tools')
  assert.equal(status.repositoryEvidence.state, 'git_cli_unavailable')
  assert.equal(status.repositoryEvidence.worktreeRoot, fs.realpathSync(repo))
  assert.equal(status.repositoryEvidence.head.state, 'unavailable')
  assert.deepEqual(status.repositoryEvidence.localBranches, [])
  assert.equal(status.files[0].path, 'file.txt')
  assert.equal(status.files[0].y, 'M')

  request(child, { type: 'git_diff', id: 'fallback-diff', cwd: repo, path: 'file.txt' })
  const diff = await waitFor(
    () => events.find((event) => event.type === 'git_diff_result' && event.id === 'fallback-diff'),
    'built-in Git diff')
  assert.match(diff.diff, /-before/)
  assert.match(diff.diff, /\+after/)

  request(child, { type: 'git_stage', id: 'fallback-stage', cwd: repo, path: 'file.txt' })
  const stage = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'fallback-stage'),
    'unavailable Git write')
  assert.equal(stage.ok, false)
  assert.equal(stage.toolError, 'dev_tools')
})

test('Git evidence identifies linked worktrees through one canonical common directory', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  const linked = path.join(root, 'linked-topic')
  fs.mkdirSync(repo)
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'seed.txt'), 'seed\n')
  runGit(repo, ['add', '--', 'seed.txt'])
  runGit(repo, ['commit', '-qm', 'initial'])
  runGit(repo, ['branch', 'topic'])
  runGit(repo, ['worktree', 'add', '-q', linked, 'topic'])
  const head = runGit(linked, ['rev-parse', 'HEAD']).trim()

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  request(child, {
    type: 'git_status', id: 'linked-status', cwd: linked,
    candidateOIDs: [head], frozenTargetOID: head,
  })
  const status = await waitFor(
    () => events.find((event) => event.type === 'git_status_result'
      && event.id === 'linked-status'),
    'linked worktree status')
  const evidence = status.repositoryEvidence
  assert.equal(evidence.state, 'available')
  assert.equal(evidence.worktreeRoot, fs.realpathSync(linked))
  assert.equal(evidence.gitCommonDir, fs.realpathSync(path.join(repo, '.git')))
  assert.deepEqual(evidence.head, {
    state: 'attached', oid: head, symbolicRef: 'refs/heads/topic',
  })
  assert.ok(evidence.localBranches.some((branch) => branch.ref === 'refs/heads/topic'))
  assert.deepEqual(
    evidence.registeredWorktrees.map((worktree) => worktree.path).sort(),
    [fs.realpathSync(linked), fs.realpathSync(repo)].sort())
  assert.deepEqual(
    evidence.commitReachability[0].localBranchRefs,
    [runGit(repo, ['symbolic-ref', 'HEAD']).trim(), 'refs/heads/topic'].sort())
  assert.equal(evidence.commitReachability[0].targetRelationship, 'equal')
})

test('Git evidence proves candidate ancestry against the captured checkout OID', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo)
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'seed.txt'), 'base\n')
  runGit(repo, ['add', '--', 'seed.txt'])
  runGit(repo, ['commit', '-qm', 'base'])
  const baseOID = runGit(repo, ['rev-parse', 'HEAD']).trim()
  const checkoutRef = runGit(repo, ['symbolic-ref', 'HEAD']).trim()
  const checkoutBranch = checkoutRef.slice('refs/heads/'.length)

  runGit(repo, ['checkout', '-qb', 'side'])
  fs.writeFileSync(path.join(repo, 'side.txt'), 'side\n')
  runGit(repo, ['add', '--', 'side.txt'])
  runGit(repo, ['commit', '-qm', 'side'])
  const sideOID = runGit(repo, ['rev-parse', 'HEAD']).trim()

  runGit(repo, ['checkout', '-q', checkoutBranch])
  fs.writeFileSync(path.join(repo, 'checkout.txt'), 'checkout\n')
  runGit(repo, ['add', '--', 'checkout.txt'])
  runGit(repo, ['commit', '-qm', 'checkout'])
  const headOID = runGit(repo, ['rev-parse', 'HEAD']).trim()
  const missingOID = 'f'.repeat(40)

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  request(child, {
    type: 'git_status', id: 'ancestry-status', cwd: repo,
    candidateOIDs: [headOID, baseOID, sideOID, missingOID],
  })
  const status = await waitFor(
    () => events.find((event) => event.type === 'git_status_result'
      && event.id === 'ancestry-status'),
    'candidate ancestry status')
  assert.equal(status.repositoryEvidence.head.oid, headOID)
  assert.deepEqual(status.repositoryEvidence.commitReachability, [
    {
      oid: headOID, resolvedOID: headOID, state: 'available',
      localBranchRefs: [checkoutRef], targetRelationship: 'equal',
    },
    {
      oid: baseOID, resolvedOID: baseOID, state: 'available',
      localBranchRefs: [checkoutRef, 'refs/heads/side'].sort(),
      targetRelationship: 'ancestor',
    },
    {
      oid: sideOID, resolvedOID: sideOID, state: 'available',
      localBranchRefs: ['refs/heads/side'], targetRelationship: 'notAncestor',
    },
    {
      oid: missingOID, state: 'missing', localBranchRefs: [],
      targetRelationship: 'missing',
    },
  ])

  // An existing candidate can still be resolved while this checkout names an unborn branch. That
  // preserves its branch-containment facts but cannot prove a relation to a checkout commit.
  runGit(repo, ['symbolic-ref', 'HEAD', 'refs/heads/unborn-checkout'])
  request(child, {
    type: 'git_status', id: 'unavailable-target-status', cwd: repo,
    candidateOIDs: [sideOID],
  })
  const unavailable = await waitFor(
    () => events.find((event) => event.type === 'git_status_result'
      && event.id === 'unavailable-target-status'),
    'unavailable checkout target status')
  assert.equal(unavailable.repositoryEvidence.head.state, 'unborn')
  assert.deepEqual(unavailable.repositoryEvidence.commitReachability, [{
    oid: sideOID, resolvedOID: sideOID, state: 'available',
    localBranchRefs: ['refs/heads/side'], targetRelationship: 'unavailable',
  }])
})

test('Git evidence names unborn and detached HEAD states without inventing a branch', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo)
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  const unbornRef = runGit(repo, ['symbolic-ref', 'HEAD']).trim()

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  request(child, { type: 'git_status', id: 'unborn-status', cwd: repo })
  const unborn = await waitFor(
    () => events.find((event) => event.type === 'git_status_result'
      && event.id === 'unborn-status'),
    'unborn status')
  assert.deepEqual(unborn.repositoryEvidence.head, {
    state: 'unborn', symbolicRef: unbornRef,
  })
  assert.deepEqual(unborn.repositoryEvidence.registeredWorktrees, [{
    path: fs.realpathSync(repo), state: 'unborn', symbolicRef: unbornRef,
  }])

  fs.writeFileSync(path.join(repo, 'seed.txt'), 'seed\n')
  runGit(repo, ['add', '--', 'seed.txt'])
  runGit(repo, ['commit', '-qm', 'initial'])
  const target = runGit(repo, ['rev-parse', 'HEAD']).trim()
  fs.appendFileSync(path.join(repo, 'seed.txt'), 'second\n')
  runGit(repo, ['add', '--', 'seed.txt'])
  runGit(repo, ['commit', '-qm', 'second'])
  const detachedHead = runGit(repo, ['rev-parse', 'HEAD']).trim()
  runGit(repo, ['checkout', '-q', '--detach', 'HEAD'])

  request(child, {
    type: 'git_status', id: 'detached-status', cwd: repo,
    candidateOIDs: [target], frozenTargetOID: target,
  })
  const detached = await waitFor(
    () => events.find((event) => event.type === 'git_status_result'
      && event.id === 'detached-status'),
    'detached status')
  assert.deepEqual(detached.repositoryEvidence.head, {
    state: 'detached', oid: detachedHead,
  })
  assert.equal(detached.repositoryEvidence.head.symbolicRef, undefined)
  assert.deepEqual(detached.repositoryEvidence.frozenTarget, {
    requestedOID: target, resolvedOID: target,
    relationship: 'headAhead', ahead: 1, behind: 0,
  })
})

test('Git evidence captures an attached HEAD upstream by full ref and immutable OID', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo)
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'seed.txt'), 'seed\n')
  runGit(repo, ['add', '--', 'seed.txt'])
  runGit(repo, ['commit', '-qm', 'initial'])
  const upstreamOID = runGit(repo, ['rev-parse', 'HEAD']).trim()
  runGit(repo, ['branch', 'integration-target'])
  runGit(repo, ['branch', '--set-upstream-to=integration-target'])
  fs.appendFileSync(path.join(repo, 'seed.txt'), 'ahead\n')
  runGit(repo, ['add', '--', 'seed.txt'])
  runGit(repo, ['commit', '-qm', 'ahead'])
  const headOID = runGit(repo, ['rev-parse', 'HEAD']).trim()
  const symbolicRef = runGit(repo, ['symbolic-ref', 'HEAD']).trim()

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  request(child, { type: 'git_status', id: 'upstream-status', cwd: repo })
  const status = await waitFor(
    () => events.find((event) => event.type === 'git_status_result'
      && event.id === 'upstream-status'),
    'upstream status')
  assert.deepEqual(status.repositoryEvidence.head, {
    state: 'attached', oid: headOID, symbolicRef,
    upstreamRef: 'refs/heads/integration-target', upstreamOID,
    ahead: 1, behind: 0,
  })
})

test('Commit refuses an index holding files the caller was not shown', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo, { recursive: true })
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'seed.txt'), 'seed\n')
  runGit(repo, ['add', '--', '.'])
  runGit(repo, ['commit', '-qm', 'initial'])

  // Two conversations stage into one shared index. The panel only ever listed `mine.txt`.
  fs.writeFileSync(path.join(repo, 'mine.txt'), 'mine\n')
  fs.writeFileSync(path.join(repo, 'theirs.txt'), 'theirs\n')
  runGit(repo, ['add', '--', 'mine.txt', 'theirs.txt'])

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  request(child, {
    type: 'git_commit', id: 'commit-contaminated', cwd: repo,
    message: 'Only my file', expectedPaths: ['mine.txt'],
  })
  const refused = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'commit-contaminated'),
    'contaminated-index refusal')
  assert.equal(refused.ok, false)
  assert.match(refused.message, /theirs\.txt/)
  assert.match(refused.message, /Nothing was committed/)
  // The refusal must be a refusal, not a partial commit.
  assert.equal(runGit(repo, ['rev-list', '--count', 'HEAD']).trim(), '1')
  assert.equal(
    runGit(repo, ['diff', '--cached', '--name-only']).split('\n').filter(Boolean).sort().join(','),
    'mine.txt,theirs.txt')

  // Declaring the whole index commits it, so the guard blocks surprise and nothing else.
  request(child, {
    type: 'git_commit', id: 'commit-agreed', cwd: repo,
    message: 'Both files', expectedPaths: ['mine.txt', 'theirs.txt'],
  })
  const agreed = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'commit-agreed'),
    'agreed commit')
  assert.equal(agreed.ok, true)
  assert.equal(runGit(repo, ['rev-list', '--count', 'HEAD']).trim(), '2')
})

test('Commit without a declared expectation keeps the pre-existing whole-index behaviour', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo, { recursive: true })
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'seed.txt'), 'seed\n')
  runGit(repo, ['add', '--', '.'])
  runGit(repo, ['commit', '-qm', 'initial'])
  fs.writeFileSync(path.join(repo, 'one.txt'), 'one\n')
  runGit(repo, ['add', '--', 'one.txt'])

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  // An older app build sends no expectedPaths. The guard must not turn that into a refusal.
  request(child, { type: 'git_commit', id: 'commit-legacy', cwd: repo, message: 'Legacy' })
  const done = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'commit-legacy'),
    'legacy commit')
  assert.equal(done.ok, true)
  assert.equal(runGit(repo, ['rev-list', '--count', 'HEAD']).trim(), '2')
})

test('Commit tolerates a staged rename it was shown by both of its paths', async (t) => {
  const { child, events, root } = startAgentd(t)
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo, { recursive: true })
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'before.txt'), 'body\n')
  runGit(repo, ['add', '--', '.'])
  runGit(repo, ['commit', '-qm', 'initial'])
  runGit(repo, ['mv', '--', 'before.txt', 'after.txt'])

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  // GitFile.operationPaths sends both sides of a rename. Whether git reports the destination
  // alone or both sides, the declared set covers it and the commit must not be refused.
  request(child, {
    type: 'git_commit', id: 'commit-rename', cwd: repo,
    message: 'Rename', expectedPaths: ['before.txt', 'after.txt'],
  })
  const done = await waitFor(
    () => events.find((event) => event.type === 'git_done' && event.id === 'commit-rename'),
    'rename commit')
  assert.equal(done.ok, true)
  assert.equal(runGit(repo, ['rev-list', '--count', 'HEAD']).trim(), '2')
})

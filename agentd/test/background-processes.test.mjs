// FR-117: tracking the background work an agent leaves running.
//
// The load-bearing test here is `a detached process stays visible after it reparents`. That case is
// the entire reason the tracker follows pids instead of just walking the tree each poll — measured
// on macOS, `nohup … &` leaves a process with ppid 1, so a pure descendant walk goes blind precisely
// when work detaches in order to survive.
import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  conversationOwner,
  createProcessTracker,
  describeCommand,
  descendantPids,
  isAdoptableOrphan,
  isInfrastructure,
  parseElapsedSeconds,
  parseProcessTable,
  usableWorkspaceRoots,
} from '../src/background-processes.mjs'

// pid ppid uid etime lstart command — uid 501, a 10:00 elapsed and one stable process generation
// unless a row overrides them.
const table = (rows) => rows
  .map(([pid, ppid, cmd, uid = 501, etime = '10:00', startedAt = 'Tue Aug 11 09:00:00 2026']) =>
    `${pid} ${ppid} ${uid} ${etime} ${startedAt} ${cmd}`)
  .join('\n')

const deferred = () => {
  let resolve
  let reject
  const promise = new Promise((res, rej) => { resolve = res; reject = rej })
  return { promise, resolve, reject }
}

test('parses a ps table', () => {
  const rows = parseProcessTable(table([
    [100, 1, '/bin/bash -c sleep 1'],
    [200, 100, 'node w.mjs', 501, '02:30', 'Tue Aug 11 09:07:30 2026'],
  ]))

  assert.deepEqual(rows, [
    {
      pid: 100, ppid: 1, uid: 501, elapsedSec: 600,
      startedAt: 'Tue Aug 11 09:00:00 2026', command: '/bin/bash -c sleep 1',
    },
    {
      pid: 200, ppid: 100, uid: 501, elapsedSec: 150,
      startedAt: 'Tue Aug 11 09:07:30 2026', command: 'node w.mjs',
    },
  ])
})

test('parses every ps elapsed-time shape', () => {
  assert.equal(parseElapsedSeconds('05'), null, 'seconds alone is not a valid etime')
  assert.equal(parseElapsedSeconds('02:30'), 150)
  assert.equal(parseElapsedSeconds('01:02:30'), 3750)
  assert.equal(parseElapsedSeconds('2-01:02:30'), 176_550)
  assert.equal(parseElapsedSeconds('garbage'), null)
})

test('a truncated row does not discard the whole snapshot', () => {
  // A machine under load can cut the final line. Losing every process because of one bad row would
  // blank the panel at exactly the moment something is churning.
  const rows = parseProcessTable(
    `${table([[100, 1, 'node a.mjs'], [200, 100, 'node b.mjs']])}\ngarbage\n300 200`)

  assert.deepEqual(rows.map((r) => r.pid), [100, 200])
})

test('finds descendants transitively', () => {
  const rows = parseProcessTable(table([
    [10, 1, 'agentd'], [20, 10, 'claude'], [30, 20, 'bash'], [40, 30, 'node run.mjs'],
    [99, 1, 'unrelated'],
  ]))

  assert.deepEqual([...descendantPids(rows, 10)].sort((a, b) => a - b), [20, 30, 40])
})

test('a pid cycle terminates instead of hanging', () => {
  // pid reuse can produce a cycle in a snapshot. Recursing would blow the stack; this must return.
  const rows = parseProcessTable(table([[10, 1, 'a'], [20, 10, 'b'], [10, 20, 'a-again']]))

  const found = descendantPids(rows, 10)
  assert.ok(found.has(20))
})

test('agentd machinery is not reported as agent background work', () => {
  assert.equal(isInfrastructure('node /app/agentd/src/agentd.mjs'), true)
  assert.equal(isInfrastructure('node .../claude-agent-sdk/cli.js'), true)
  assert.equal(isInfrastructure('npx mcp-server-filesystem'), true)
  assert.equal(isInfrastructure('bash -c until test -f /tmp/done; do sleep 5; done'), false)
})

test('labels prefer the script being run over the shell payload', () => {
  assert.equal(describeCommand('/bin/bash -c export PATH=…; node run-batch.mjs --category X'),
    'run-batch.mjs')
  assert.equal(describeCommand('/opt/homebrew/bin/node /x/y/summarize.mjs'), 'summarize.mjs')
  assert.equal(describeCommand('sleep 300'), 'sleep')
})

test('short-lived commands are not reported', () => {
  // Every Bash tool call is a descendant for a moment. Reporting them would make the panel unusable.
  let clock = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => table([[10, 1, 'agentd'], [20, 10, 'bash -c ls']]),
    minAgeMs: 20_000,
    now: () => clock,
  })

  return tracker.poll().then(async (first) => {
    assert.deepEqual(first, [])
    clock = 5_000
    assert.deepEqual(await tracker.poll(), [], 'still too young at 5s')
  })
})

test('a long-running descendant is reported once it passes the age floor', async () => {
  let clock = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => table([[10, 1, 'agentd'], [20, 10, 'node watcher.mjs']]),
    minAgeMs: 20_000,
    now: () => clock,
  })

  await tracker.poll()
  clock = 25_000
  const reported = await tracker.poll()

  assert.equal(reported.length, 1)
  assert.equal(reported[0].label, 'watcher.mjs')
  assert.equal(reported[0].detached, false)
  assert.equal(reported[0].ageMs, 25_000)
})

test('a detached process stays visible after it reparents to launchd', async () => {
  // THE case this tracker exists for. `nohup … &` leaves the process alive with ppid 1 once its
  // spawning shell exits, so it is no longer a descendant of agentd — a per-poll tree walk would
  // report it once and then lose it. Capture-then-follow keeps it, flagged as detached.
  let clock = 0
  let reparented = false
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => table(reparented
      ? [[10, 1, 'agentd'], [30, 1, 'bash -c until test -f /tmp/done; do sleep 5; done']]
      : [[10, 1, 'agentd'], [20, 10, 'bash -c nohup …'],
         [30, 20, 'bash -c until test -f /tmp/done; do sleep 5; done']]),
    minAgeMs: 1_000,
    now: () => clock,
  })

  await tracker.poll()             // captured while still in the tree
  reparented = true                // spawning shell exits; pid 30 reparents to 1
  clock = 30_000
  const reported = await tracker.poll()

  const watcher = reported.find((p) => p.pid === 30)
  assert.ok(watcher, 'a detached watcher must remain visible')
  assert.equal(watcher.detached, true, 'and be marked as no longer a descendant')
})

test('a process that exits is dropped', async () => {
  let clock = 0
  let alive = true
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => table(alive
      ? [[10, 1, 'agentd'], [20, 10, 'node watcher.mjs']]
      : [[10, 1, 'agentd']]),
    minAgeMs: 0,
    now: () => clock,
  })

  await tracker.poll()
  clock = 30_000
  assert.equal((await tracker.poll()).length, 1)
  alive = false
  assert.deepEqual(await tracker.poll(), [])
  assert.equal(tracker.isTracked(20), false, 'and forgotten, so its pid cannot later be killed')
})

test('a failed process snapshot preserves tracked Stop authority', async () => {
  let failSnapshot = false
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    snapshot: async () => {
      if (failSnapshot) throw new Error('ps timed out')
      return table([[10, 1, 'agentd'], [20, 10, 'node watcher.mjs']])
    },
  })

  await tracker.poll()
  assert.equal(tracker.isTracked(20), true)

  failSnapshot = true
  await assert.rejects(tracker.poll(), /ps timed out/)
  assert.equal(
    tracker.isTracked(20), true,
    'missing evidence must not silently revoke the user\'s ability to stop known work')
})

test('a failed pre-kill validation retains tracking and can recover', async () => {
  let failSnapshot = false
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    snapshot: async () => {
      if (failSnapshot) throw new Error('ps timed out')
      return table([[10, 1, 'agentd'], [20, 10, 'node watcher.mjs']])
    },
  })

  await tracker.poll()
  failSnapshot = true
  await assert.rejects(tracker.validateTracked(20), /ps timed out/)
  assert.equal(tracker.isTracked(20), true)

  failSnapshot = false
  assert.equal(await tracker.validateTracked(20), true)
})

test('only captured pids are killable', async () => {
  // agentd must never terminate an arbitrary pid handed to it over the wire — only work it watched
  // the agent start.
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => table([[10, 1, 'agentd'], [20, 10, 'node watcher.mjs']]),
    minAgeMs: 0,
  })

  await tracker.poll()
  assert.equal(tracker.isTracked(20), true)
  assert.equal(tracker.isTracked(1), false, 'launchd is not killable')
  assert.equal(tracker.isTracked(99999), false, 'nor is an untracked pid')
})


// MARK: - Adopting orphans (the case capture-then-follow cannot reach)

const ORPHAN = { pid: 30, ppid: 1, uid: 501, elapsedSec: 60, command: 'bash -c until test -f x; do sleep 5; done' }
const CONTEXT = { rootUid: 501, rootElapsedSec: 600, workspaceRoots: ['/Users/dev/proj'] }

test('an orphan rooted in the workspace, started after agentd, same user, is adopted', () => {
  assert.equal(isAdoptableOrphan(ORPHAN, { ...CONTEXT, cwd: '/Users/dev/proj/sub' }), true)
})

test('every identity check can veto adoption on its own', () => {
  const cwd = '/Users/dev/proj'
  // A live child is handled by the descendant path; adopting it here would double-count.
  assert.equal(isAdoptableOrphan({ ...ORPHAN, ppid: 42 }, { ...CONTEXT, cwd }), false)
  // Another user's process is never ours.
  assert.equal(isAdoptableOrphan({ ...ORPHAN, uid: 0 }, { ...CONTEXT, cwd }), false)
  // Older than agentd means it predates this daemon — it cannot be work this agent started.
  assert.equal(isAdoptableOrphan({ ...ORPHAN, elapsedSec: 9_999 }, { ...CONTEXT, cwd }), false)
  // Outside the workspace: this is the check that protects the user's own detached jobs.
  assert.equal(isAdoptableOrphan(ORPHAN, { ...CONTEXT, cwd: '/Users/dev/somewhere-else' }), false)
  // Unknown cwd is not a maybe. Without it there is no evidence of ownership.
  assert.equal(isAdoptableOrphan(ORPHAN, { ...CONTEXT, cwd: null }), false)
  // agentd's own machinery is never "background work the agent started".
  assert.equal(isAdoptableOrphan({ ...ORPHAN, command: 'node agentd.mjs' }, { ...CONTEXT, cwd }), false)
})

test('a prefix that is not a path boundary does not count as inside the workspace', () => {
  // /Users/dev/project-backup must not match a /Users/dev/proj root.
  assert.equal(
    isAdoptableOrphan(ORPHAN, { ...CONTEXT, cwd: '/Users/dev/proj-backup' }), false)
})

test('a fast-detaching watcher the tracker never saw as a descendant is still adopted', async () => {
  // THE gap this closes. Measured live: `nohup … &` can reparent before the next poll, so the
  // process is never a descendant at any instant the tracker looks.
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    workspaceRoots: ['/Users/dev/proj'],
    cwdOf: async () => '/Users/dev/proj',
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [30, 1, 'bash -c until test -f /tmp/done; do sleep 5; done', 501, '01:00'],
    ]),
  })

  const reported = await tracker.poll()
  const adopted = reported.find((p) => p.pid === 30)

  assert.ok(adopted, 'a never-seen-as-descendant orphan must still be reported')
  assert.equal(adopted.adopted, true)
  assert.equal(adopted.detached, true)
  assert.ok(adopted.ageMs >= 60_000, 'and dated from its real elapsed time, not from adoption')
  assert.equal(tracker.isTracked(30), true)
})

test("a user's own detached process outside the workspace is never adopted or killable", async () => {
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    workspaceRoots: ['/Users/dev/proj'],
    cwdOf: async () => '/Users/dev/private-thing',
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [77, 1, 'bash -c my-own-long-job', 501, '01:00'],
    ]),
  })

  assert.deepEqual(await tracker.poll(), [])
  assert.equal(tracker.isTracked(77), false, 'and so it can never be killed from the panel')
})

test('a workspace root too broad to discriminate is refused', () => {
  // The cwd check is the only thing separating the agent's work from the user's. A root of `/` or
  // the home directory matches nearly everything a person runs, so adoption would start offering a
  // Stop button on unrelated jobs. dev.sh defaults MECHANICIAN_CWD to $HOME, so this is reachable.
  assert.deepEqual(usableWorkspaceRoots(['/Users/dev/proj'], '/Users/dev'), ['/Users/dev/proj'])
  assert.deepEqual(usableWorkspaceRoots(['/Users/dev'], '/Users/dev'), [])
  assert.deepEqual(usableWorkspaceRoots(['/Users/dev/'], '/Users/dev'), [], 'trailing slash too')
  assert.deepEqual(usableWorkspaceRoots(['/Users'], '/Users/dev'), [], 'an ancestor of home too')
  assert.deepEqual(usableWorkspaceRoots(['/'], '/Users/dev'), [])
  assert.deepEqual(usableWorkspaceRoots([null, ''], '/Users/dev'), [])
})

test('with no usable workspace root, nothing is adopted', async () => {
  const tracker = createProcessTracker({
    rootPid: 10, minAgeMs: 0,
    workspaceRoots: ['/Users/dev'],     // == home, therefore unusable
    homeDir: '/Users/dev',
    cwdOf: async () => '/Users/dev/anything',
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [30, 1, 'bash -c some-detached-job', 501, '01:00'],
    ]),
  })

  assert.deepEqual(await tracker.poll(), [], 'adoption must be off rather than indiscriminate')
})

test('concurrent poll callers share one snapshot and release the lock after completion', async () => {
  const firstSnapshot = deferred()
  let snapshots = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => {
      snapshots += 1
      if (snapshots === 1) return firstSnapshot.promise
      return table([[10, 1, 'node agentd-host']])
    },
  })

  const first = tracker.poll()
  const concurrent = tracker.poll()
  assert.strictEqual(concurrent, first)
  assert.equal(snapshots, 1)

  firstSnapshot.resolve(table([[10, 1, 'node agentd-host']]))
  assert.deepEqual(await first, [])
  assert.deepEqual(await concurrent, [])
  await tracker.poll()
  assert.equal(snapshots, 2, 'a settled pass must release the single-flight slot')
})

test('a failed poll releases the single-flight slot', async () => {
  let snapshots = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => {
      snapshots += 1
      if (snapshots === 1) throw new Error('fixture snapshot failure')
      return table([[10, 1, 'node agentd-host']])
    },
  })

  await assert.rejects(tracker.poll(), /fixture snapshot failure/)
  assert.deepEqual(await tracker.poll(), [])
  assert.equal(snapshots, 2)
})

test('an outside-workspace cwd is looked up once for one live process generation', async () => {
  let cwdLookups = 0
  const snapshot = table([
    [10, 1, 'node agentd-host', 501, '10:00', 'Tue Aug 11 09:00:00 2026'],
    [30, 1, 'bash -c user-job', 501, '01:00', 'Tue Aug 11 09:09:00 2026'],
  ])
  const tracker = createProcessTracker({
    rootPid: 10,
    workspaceRoots: ['/Users/dev/proj'],
    snapshot: async () => snapshot,
    cwdOf: async () => { cwdLookups += 1; return '/Users/dev/private-thing' },
  })

  assert.deepEqual(await tracker.poll(), [])
  assert.deepEqual(await tracker.poll(), [])
  assert.equal(cwdLookups, 1, 'a rejected live pid must not be re-lsof\'d every poll')
  assert.equal(tracker.isTracked(30), false)
})

test('a null cwd result is cached fail-closed', async () => {
  let cwdLookups = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    workspaceRoots: ['/Users/dev/proj'],
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [30, 1, 'bash -c inaccessible-job', 501, '01:00'],
    ]),
    cwdOf: async () => { cwdLookups += 1; return null },
  })

  await tracker.poll()
  await tracker.poll()
  assert.equal(cwdLookups, 1)
  assert.equal(tracker.isTracked(30), false)
})

test('a newly learned workspace requires fresh cwd evidence before adoption', async () => {
  let roots = ['/Users/dev/proj-a']
  let cwdLookups = 0
  const snapshot = table([
    [10, 1, 'node agentd-host', 501, '10:00'],
    [30, 1, 'bash -c workspace-job', 501, '01:00'],
  ])
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    workspaceRoots: () => roots,
    snapshot: async () => snapshot,
    cwdOf: async () => { cwdLookups += 1; return '/Users/dev/proj-b' },
  })

  assert.deepEqual(await tracker.poll(), [])
  roots = [...roots, '/Users/dev/proj-b']
  const reported = await tracker.poll()

  assert.equal(cwdLookups, 2, 'cached outside evidence must not become kill authority')
  assert.equal(reported[0]?.pid, 30)
  assert.equal(tracker.isTracked(30), true)
})

test('pid reuse invalidates cached cwd evidence', async () => {
  let startedAt = 'Tue Aug 11 09:09:00 2026'
  let processCwd = '/Users/dev/private-thing'
  let cwdLookups = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    workspaceRoots: ['/Users/dev/proj'],
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [30, 1, 'bash -c reused-pid', 501, '01:00', startedAt],
    ]),
    cwdOf: async () => { cwdLookups += 1; return processCwd },
  })

  assert.deepEqual(await tracker.poll(), [])
  startedAt = 'Tue Aug 11 09:10:00 2026'
  processCwd = '/Users/dev/proj'
  const reported = await tracker.poll()

  assert.equal(cwdLookups, 2)
  assert.equal(reported[0]?.pid, 30)
})

test('a reused tracked pid loses kill authority when the replacement is outside the workspace', async () => {
  let startedAt = 'Tue Aug 11 09:09:00 2026'
  let processCwd = '/Users/dev/proj'
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    workspaceRoots: ['/Users/dev/proj'],
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [30, 1, 'bash -c reused-pid', 501, '01:00', startedAt],
    ]),
    cwdOf: async () => processCwd,
  })

  await tracker.poll()
  assert.equal(tracker.isTracked(30), true)
  startedAt = 'Tue Aug 11 09:10:00 2026'
  processCwd = '/Users/dev/private-thing'
  assert.deepEqual(await tracker.poll(), [])
  assert.equal(tracker.isTracked(30), false)
})

test('kill validation rejects a pid replaced since the last poll', async () => {
  let startedAt = 'Tue Aug 11 09:09:00 2026'
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [30, 10, 'bash -c tracked-job', 501, '01:00', startedAt],
    ]),
  })

  await tracker.poll()
  assert.equal(tracker.isTracked(30), true)
  startedAt = 'Tue Aug 11 09:10:00 2026'

  assert.equal(await tracker.validateTracked(30), false)
  assert.equal(tracker.isTracked(30), false)
})

test('kill validation accepts the same live process generation and fails closed if it disappears', async () => {
  let includeProcess = true
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      ...(includeProcess
        ? [[30, 10, 'bash -c tracked-job', 501, '01:00', 'Tue Aug 11 09:09:00 2026']]
        : []),
    ]),
  })

  await tracker.poll()
  assert.equal(await tracker.validateTracked(30), true)
  includeProcess = false
  assert.equal(await tracker.validateTracked(30), false)
  assert.equal(tracker.isTracked(30), false)
})

test('stale kill validation cannot authorize or delete a generation replaced by a concurrent poll', async () => {
  const staleValidation = deferred()
  const generationA = table([
    [10, 1, 'node agentd-host', 501, '10:00'],
    [30, 10, 'bash -c tracked-job-a', 501, '01:00', 'Tue Aug 11 09:09:00 2026'],
  ])
  const generationB = table([
    [10, 1, 'node agentd-host', 501, '10:00'],
    [30, 10, 'bash -c tracked-job-b', 501, '00:01', 'Tue Aug 11 09:10:00 2026'],
  ])
  let snapshots = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    snapshot: async () => {
      snapshots += 1
      if (snapshots === 1) return generationA
      if (snapshots === 2) return staleValidation.promise
      return generationB
    },
  })

  await tracker.poll()
  const validation = tracker.validateTracked(30)
  await tracker.poll()
  assert.equal(tracker.isTracked(30), true, 'the concurrent poll tracks generation B')
  staleValidation.resolve(generationA)

  assert.equal(await validation, false, 'generation A evidence cannot authorize generation B')
  assert.equal(tracker.isTracked(30), true, 'nor may stale validation delete generation B')
})

test('a pid reused while cwd lookup is pending cannot be adopted', async () => {
  const lookup = deferred()
  let snapshots = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    minAgeMs: 0,
    workspaceRoots: ['/Users/dev/proj'],
    snapshot: async () => {
      snapshots += 1
      return table([
        [10, 1, 'node agentd-host', 501, '10:00'],
        [30, 1, 'bash -c reused-during-lookup', 501, '01:00',
          snapshots === 1 ? 'Tue Aug 11 09:09:00 2026' : 'Tue Aug 11 09:10:00 2026'],
      ])
    },
    cwdOf: async () => lookup.promise,
  })

  const poll = tracker.poll()
  await Promise.resolve()
  lookup.resolve('/Users/dev/proj')

  assert.deepEqual(await poll, [])
  assert.equal(tracker.isTracked(30), false)
  assert.equal(snapshots, 2, 'a positive cwd lookup must trigger identity confirmation')
})

test('one poll performs only the bounded number of orphan cwd lookups', async () => {
  let cwdLookups = 0
  const candidates = Array.from({ length: 20 }, (_, index) => [
    30 + index, 1, `bash -c user-job-${index}`, 501, `00:${String(index + 1).padStart(2, '0')}`,
    `Tue Aug 11 09:09:${String(index).padStart(2, '0')} 2026`,
  ])
  const tracker = createProcessTracker({
    rootPid: 10,
    workspaceRoots: ['/Users/dev/proj'],
    maxOrphanLookupsPerPoll: 3,
    snapshot: async () => table([[10, 1, 'node agentd-host', 501, '10:00'], ...candidates]),
    cwdOf: async () => { cwdLookups += 1; return '/Users/dev/private-thing' },
  })

  await tracker.poll()
  assert.equal(cwdLookups, 3)
})

test('the production default checks only one new orphan cwd per pass', async () => {
  let cwdLookups = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    workspaceRoots: ['/Users/dev/proj'],
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [30, 1, 'bash -c first-user-job', 501, '00:01'],
      [31, 1, 'bash -c second-user-job', 501, '00:02'],
    ]),
    cwdOf: async () => { cwdLookups += 1; return '/Users/dev/private-thing' },
  })

  await tracker.poll()
  assert.equal(cwdLookups, 1)
  await tracker.poll()
  assert.equal(cwdLookups, 2, 'the next pass advances past the cached first candidate')
  await tracker.poll()
  assert.equal(cwdLookups, 2, 'each live generation is inspected at most once')
})

test('aborting a poll stops before the next orphan cwd lookup', async () => {
  const firstLookup = deferred()
  const controller = new AbortController()
  let cwdLookups = 0
  const tracker = createProcessTracker({
    rootPid: 10,
    workspaceRoots: ['/Users/dev/proj'],
    snapshot: async () => table([
      [10, 1, 'node agentd-host', 501, '10:00'],
      [30, 1, 'bash -c first-job', 501, '00:01'],
      [31, 1, 'bash -c second-job', 501, '00:02'],
    ]),
    cwdOf: async () => {
      cwdLookups += 1
      if (cwdLookups === 1) return firstLookup.promise
      return '/Users/dev/private-thing'
    },
  })

  const poll = tracker.poll({ signal: controller.signal })
  await Promise.resolve()
  assert.equal(cwdLookups, 1)
  controller.abort(new Error('fixture stop'))
  firstLookup.resolve('/Users/dev/private-thing')
  await assert.rejects(poll, /fixture stop/)
  assert.equal(cwdLookups, 1)
})

test("the app's own terminal shell is not agent background work", () => {
  // The terminal panel's shell is a child of agentd, so the descendant walk finds it. Offering a
  // Stop button on the user's interactive shell would be wrong and alarming.
  assert.equal(isInfrastructure('/bin/zsh -il'), true)
  assert.equal(isInfrastructure('/bin/bash --login'), true)
  // An agent's shell always carries a command, and must still be reported.
  assert.equal(isInfrastructure('bash -c until test -f /tmp/done; do sleep 5; done'), false)
  assert.equal(isInfrastructure('/bin/sh -c node run-batch.mjs'), false)
})

test('provider runtimes agentd owns are not agent background work', () => {
  // The Codex app-server is started and owned by agentd. It showed up in the panel during the first
  // live test with a Stop button, which would have broken the provider rather than tidied anything.
  assert.equal(isInfrastructure(
    '/Applications/ChatGPT.app/Contents/Resources/codex -c mcp="…" app-server --stdio'), true)
  assert.equal(isInfrastructure('codex app-server'), true)
  assert.equal(isInfrastructure(
    '/Applications/Mechanician.app/Contents/Resources/agentd/node_modules/@openai/'
      + 'codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex-code-mode-host'), true)
  // A user's own codex invocation in a shell is still their work, not ours to hide... but it is also
  // not agent background work unless the agent started it, which the descendant/adopt checks decide.
  assert.equal(isInfrastructure('bash -c codex --help'), false)
})

test('a process is stamped with the conversation whose turn was running when it appeared', async () => {
  let clock = 0
  let owner = 'conv-A'
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => table([[10, 1, 'agentd'], [20, 10, 'bash -c sleep 300']]),
    minAgeMs: 0,
    now: () => clock,
    ownerOf: () => owner,
  })

  const first = await tracker.poll()
  assert.equal(first[0].conversationId, 'conv-A')

  // Attribution is stamped once. A later poll during a DIFFERENT conversation must not relabel work
  // that conversation never started.
  owner = 'conv-B'
  clock += 10_000
  const second = await tracker.poll()
  assert.equal(second[0].conversationId, 'conv-A')
})

test('work started outside any turn is left unattributed rather than guessed at', async () => {
  const tracker = createProcessTracker({
    rootPid: 10,
    snapshot: async () => table([[10, 1, 'agentd'], [20, 10, 'bash -c sleep 300']]),
    minAgeMs: 0,
    now: () => 0,
    ownerOf: () => null,
  })

  assert.equal((await tracker.poll())[0].conversationId, null)
})

test('conversationOwner refuses to guess when it cannot be certain', () => {
  assert.equal(conversationOwner([{ convId: 'conv-A' }]), 'conv-A')
  assert.equal(conversationOwner([]), null, 'no turn running')
  // Two turns at once: attributing to either would put one conversation's work on another's count.
  assert.equal(conversationOwner([{ convId: 'conv-A' }, { convId: 'conv-B' }]), null)
  assert.equal(conversationOwner([{ convId: null }]), null)
  assert.equal(conversationOwner(undefined), null)
})

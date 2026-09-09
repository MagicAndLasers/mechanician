// Tracking the background work an agent leaves running (FR-117).
//
// The agent's Bash tool can start work that outlives the tool call — poll loops, watchers, long
// builds, detached chains. Until now none of it was visible: the app had no model of it, so a user
// could not see what was running on their machine on the agent's behalf, let alone stop it.
//
// WHY THIS IS NOT JUST A DESCENDANT WALK. Measured on macOS: a process started with `nohup … &`
// keeps running with ppid 1 once its spawning shell exits. It does not retain agentd's process group
// or session either. So at the moment you enumerate, the most interesting background work — the kind
// deliberately detached to survive — is no longer a descendant of anything agentd can reach.
//
// It IS a descendant briefly, before its parent exits. So the tracker CAPTURES processes while they
// are still in the tree and then FOLLOWS the same pid/uid/start generation for as long as it lives.
// Descendant enumeration finds the work; identity-following keeps it visible after it detaches.
//
// Process-table and cwd I/O are injected — parsing, tree-walking, caching and classification remain
// testable without spawning anything.

/// One `ps` row, normalized.
/// @typedef {{pid:number, ppid:number, uid:number, elapsedSec:number, startedAt:string, command:string}} ProcessRow

/// `ps` elapsed time: [[dd-]hh:]mm:ss. Used to tell "started after agentd" from "was already here",
/// which is the difference between the agent's orphan and one of the user's own.
export function parseElapsedSeconds(text) {
  const raw = String(text ?? '').trim()
  const match = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/.exec(raw)
  if (!match) return null
  const [, days, hours, minutes, seconds] = match
  return Number(days || 0) * 86400 + Number(hours || 0) * 3600
    + Number(minutes) * 60 + Number(seconds)
}

/// Parse `LC_ALL=C ps -axo pid=,ppid=,uid=,etime=,lstart=,command=`. `lstart` is a practical process
/// generation token when paired with pid and uid: a pid alone is unsafe because macOS reuses it,
/// while `etime` changes on every poll. Tolerant by design: a machine under load can
/// produce a truncated final line, and losing the whole snapshot over one bad row would blind the
/// panel at exactly the moment something is churning.
export function parseProcessTable(text) {
  const rows = []
  for (const line of String(text ?? '').split('\n')) {
    const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d:-]+)\s+(\S+\s+\S+\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.*)$/.exec(line)
    if (!match) continue
    const command = match[6].trim()
    const elapsedSec = parseElapsedSeconds(match[4])
    if (!command || elapsedSec === null) continue
    rows.push({
      pid: Number(match[1]),
      ppid: Number(match[2]),
      uid: Number(match[3]),
      elapsedSec,
      startedAt: match[5],
      command,
    })
  }
  return rows
}

function processIdentity(row) {
  return row ? `${row.pid}:${row.uid}:${row.startedAt}` : null
}

function throwIfAborted(signal) {
  if (!signal?.aborted) return
  if (typeof signal.throwIfAborted === 'function') signal.throwIfAborted()
  const error = new Error('background process poll aborted')
  error.name = 'AbortError'
  throw error
}

/// Every pid reachable downward from `rootPid`. Iterative rather than recursive: a pid table can
/// contain a cycle after pid reuse, and a recursive walk would blow the stack instead of returning.
export function descendantPids(rows, rootPid) {
  const childrenByParent = new Map()
  for (const row of rows) {
    if (!childrenByParent.has(row.ppid)) childrenByParent.set(row.ppid, [])
    childrenByParent.get(row.ppid).push(row.pid)
  }
  const found = new Set()
  const queue = [rootPid]
  while (queue.length) {
    const pid = queue.pop()
    for (const child of childrenByParent.get(pid) ?? []) {
      if (found.has(child)) continue // cycle guard
      found.add(child)
      queue.push(child)
    }
  }
  return found
}

/// Commands that are agentd's own machinery rather than work the agent started. Showing these would
/// bury the one or two processes a user actually wants to see under a dozen they cannot act on.
const INFRASTRUCTURE = [
  /claude-agent-sdk/, /\bclaude\b.*--(output-format|input-format)/,
  /agentd\.mjs/, /ambientd\.mjs/,
  /mcp-server|modelcontextprotocol/,
  // Provider runtimes agentd itself starts and owns: the Codex app-server, and any node the daemon
  // spawns for a lane. These are as much "the app running" as agentd is — a Stop button on them
  // would break the provider, not tidy up after an agent.
  /\bcodex\b.*\bapp-server\b/, /\bcodex\b.*--stdio\b/, /\bcodex-code-mode-host\b/,
  /\bps\b\s+-axo/,
  // The app's own terminal panel. Its shell is a child of agentd, so the descendant walk finds it —
  // but it is the USER's shell, not work an agent left running, and offering to Stop it would be
  // both wrong and alarming. An agent's shell always carries `-c <command>`; an interactive or
  // login shell does not.
  /(^|\/)(z|ba|k|fi|c)?sh\b(?![^]*\s-c\s)[^]*\s-{1,2}(i|l|il|li|login|interactive)\b/,
]

export function isInfrastructure(command) {
  return INFRASTRUCTURE.some((re) => re.test(command))
}

/// A short label for the panel. A raw `bash -c` payload can be hundreds of characters of shell, so
/// prefer the recognizable script or binary being run.
export function describeCommand(command) {
  const script = /([\w.-]+\.(?:mjs|js|ts|sh|py))\b/.exec(command)
  if (script) return script[1]
  const firstWord = command.trim().split(/\s+/)[0] ?? command
  return firstWord.split('/').pop() || command
}

/// Whether an orphan is plausibly the agent's own detached work.
///
/// Measured: a process backgrounded with `nohup … &` can reparent to launchd BEFORE the tracker's
/// next poll, so it is never seen as a descendant and capture-then-follow misses it entirely. That
/// is the common shape, so it cannot simply be accepted as a gap.
///
/// Adoption is therefore deliberately conservative — ALL FOUR must hold. A user's own detached
/// process (a terminal job, a background build they started) must never be adopted, because adopted
/// pids become killable from the panel and killing someone's unrelated work would be far worse than
/// failing to list ours.
export function isAdoptableOrphan(row, { rootUid, rootElapsedSec, workspaceRoots, cwd }) {
  if (!row || row.ppid !== 1) return false                    // 1. reparented, not a live child
  if (row.uid !== rootUid) return false                       // 2. same user as agentd
  if (!(row.elapsedSec < rootElapsedSec)) return false        // 3. started AFTER agentd
  if (isInfrastructure(row.command)) return false
  // 4. rooted inside a workspace agentd is responsible for. This is the discriminating check: a
  // user's unrelated detached job is overwhelmingly unlikely to be running from the agent's cwd.
  if (!cwd) return false
  return workspaceRoots.some((root) => root && (cwd === root || cwd.startsWith(`${root}/`)))
}

/// Workspace roots too broad to discriminate anything.
///
/// The cwd check is the only thing separating the agent's detached work from the user's own, so a
/// root of `/`, the home directory, or an ancestor of home makes it meaningless — nearly every
/// process a person runs lives under home. Adoption is then silently offering a Stop button on the
/// user's unrelated jobs, which is worse than not listing ours. Such a root is dropped, and with no
/// usable root adoption is off.
export function usableWorkspaceRoots(roots, homeDir) {
  const home = homeDir ? String(homeDir).replace(/\/+$/, '') : null
  return (roots ?? [])
    .map((root) => (root ? String(root).replace(/\/+$/, '') : ''))
    .filter((root) => root
      && root !== '/'
      && root !== home
      && !(home && home.startsWith(`${root}/`)))
}

/// Which conversation owns work first seen right now.
///
/// One daemon serves every conversation on its lane, so without this the panel reports a count that
/// belongs to the window rather than to what you are looking at. Attribution is stamped once, when a
/// pid is first seen, because that is the only moment the link is knowable — afterwards the process
/// is just a pid in `ps`.
///
/// Returns null when it cannot be certain: no turn running, or several at once. An unattributed
/// process is still tracked and still killable from the process-wide panel; it simply does not
/// inflate any single conversation's count with a guess.
export function conversationOwner(activeTurns) {
  const turns = [...(activeTurns ?? [])]
  if (turns.length !== 1) return null
  const convId = turns[0]?.convId
  return typeof convId === 'string' && convId ? convId : null
}

/**
 * Track background processes across polls.
 *
 * @param {object} options
 * @param {number} options.rootPid                 usually process.pid (agentd)
 * @param {(options?:object) => Promise<string>} options.snapshot  returns `ps` output
 * @param {number} [options.minAgeMs]              age before a process is "background"
 * @param {() => number} [options.now]
 * @param {string[]|(() => string[])} [options.workspaceRoots]
 * @param {(pid:number, options?:object) => Promise<string|null>} [options.cwdOf]
 * @param {number} [options.maxOrphanLookupsPerPoll] hard cap on cwd probes in one pass
 */
export function createProcessTracker({
  rootPid, snapshot, minAgeMs = 20_000, now = Date.now,
  workspaceRoots = [], cwdOf = null, homeDir = null, ownerOf = null,
  maxOrphanLookupsPerPoll = 1,
}) {
  // Accepts an array or a function: the daemon learns new workspace roots as turns arrive, and a
  // snapshot taken at construction would be permanently empty on a fresh daemon.
  const currentRoots = () => usableWorkspaceRoots(
    typeof workspaceRoots === 'function' ? workspaceRoots() : workspaceRoots, homeDir)
  /** @type {Map<number, {pid:number, command:string, label:string, firstSeen:number, detached:boolean}>} */
  const tracked = new Map()
  // A cwd miss is fail-closed evidence, never authority to kill. Cache it for this exact live
  // process generation so the hundreds of unrelated launchd children are not re-lsof'd forever.
  // Cached paths are rechecked freshly if a newly learned workspace root would make them match.
  /** @type {Map<number, {identity:string, cwd:string|null}>} */
  const inspectedOrphans = new Map()
  /** @type {Map<number, string>} */
  const trackedIdentities = new Map()
  let pollInFlight = null

  const rememberTracked = (row, entry) => {
    tracked.set(row.pid, entry)
    trackedIdentities.set(row.pid, processIdentity(row))
    inspectedOrphans.delete(row.pid)
  }

  const forgetTracked = (pid) => {
    tracked.delete(pid)
    trackedIdentities.delete(pid)
  }

  async function pollOnce({ signal } = {}) {
    throwIfAborted(signal)
    const rows = parseProcessTable(await snapshot({ signal }))
    throwIfAborted(signal)
    const alive = new Map(rows.map((r) => [r.pid, r]))
    const descendants = descendantPids(rows, rootPid)
    const at = now()
    // Resolved once per poll: every pid first seen in this pass belongs to the same turn.
    const owner = typeof ownerOf === 'function' ? ownerOf() : null

    // A process that exited must not leave cache or kill authority behind. The stable `lstart`
    // token also detects a pid that exited and was reused between two snapshots.
    for (const [pid, cached] of [...inspectedOrphans]) {
      if (processIdentity(alive.get(pid)) !== cached.identity) inspectedOrphans.delete(pid)
    }
    for (const [pid, identity] of [...trackedIdentities]) {
      if (processIdentity(alive.get(pid)) !== identity) forgetTracked(pid)
    }

    // Capture: anything currently below us that is not our own machinery.
    for (const pid of descendants) {
      const row = alive.get(pid)
      if (!row || isInfrastructure(row.command)) continue
      if (!tracked.has(pid)) {
        rememberTracked(row, {
          pid,
          command: row.command,
          label: describeCommand(row.command),
          firstSeen: at,
          detached: false,
          conversationId: owner,
        })
      }
    }

    // Adopt: orphans that pass every identity check. Without this the tracker misses work that
    // detached faster than one poll interval — which is most of what an agent backgrounds.
    const roots = currentRoots()
    if (cwdOf && roots.length) {
      const root = alive.get(rootPid)
      const candidates = rows
        .filter((row) => !tracked.has(row.pid)
          && row.ppid === 1
          && row.uid === root?.uid
          && root
          && row.elapsedSec < root.elapsedSec
          && !isInfrastructure(row.command))
        // Freshly detached work is the useful signal. Check it before old session services when the
        // per-poll budget is full.
        .sort((a, b) => a.elapsedSec - b.elapsedSec || b.pid - a.pid)
      let lookups = 0
      for (const row of candidates) {
        throwIfAborted(signal)
        const identity = processIdentity(row)
        const cached = inspectedOrphans.get(row.pid)
        if (cached?.identity === identity) {
          // A cached miss remains fail-closed. If a new workspace would turn the old path into a
          // match, require fresh cwd evidence before granting kill authority.
          if (!cached.cwd || !isAdoptableOrphan(row, {
            rootUid: root.uid, rootElapsedSec: root.elapsedSec, workspaceRoots: roots,
            cwd: cached.cwd,
          })) continue
          inspectedOrphans.delete(row.pid)
        }
        if (lookups >= maxOrphanLookupsPerPoll) break
        lookups += 1
        const orphanCwd = await cwdOf(row.pid, { signal })
        throwIfAborted(signal)
        if (!isAdoptableOrphan(row, {
          rootUid: root.uid, rootElapsedSec: root.elapsedSec, workspaceRoots: roots, cwd: orphanCwd,
        })) {
          inspectedOrphans.set(row.pid, { identity, cwd: orphanCwd })
          continue
        }

        // lsof can outlive its target. Confirm that the pid still names the same process generation
        // before the tracker makes it killable.
        const confirmation = parseProcessTable(await snapshot({ signal }))
          .find((candidate) => candidate.pid === row.pid)
        throwIfAborted(signal)
        if (processIdentity(confirmation) !== identity) continue
        rememberTracked(row, {
          pid: row.pid,
          command: row.command,
          label: describeCommand(row.command),
          // Age from its real elapsed time, not from when we noticed — an adopted orphan has
          // usually been running a while, and dating it from adoption would hide that.
          firstSeen: at - row.elapsedSec * 1000,
          detached: true,
          adopted: true,
          conversationId: owner,
        })
      }
    }

    // Follow: keep reporting a captured pid after it reparents away, and drop it when it exits.
    // Without this the tracker would go blind exactly when a process detaches to survive — which
    // is the case this feature exists for.
    for (const [pid, entry] of [...tracked]) {
      const row = alive.get(pid)
      if (!row || trackedIdentities.get(pid) !== processIdentity(row)) {
        forgetTracked(pid)
        continue
      }
      entry.detached = !descendants.has(pid)
    }

    return [...tracked.values()]
      .filter((entry) => at - entry.firstSeen >= minAgeMs)
      .map((entry) => ({ ...entry, ageMs: at - entry.firstSeen }))
      .sort((a, b) => b.ageMs - a.ageMs)
  }

  return {
    /// One poll. Returns the reportable set: tracked processes older than `minAgeMs`, whether or not
    /// they are still descendants.
    poll(options = {}) {
      if (pollInFlight) return pollInFlight
      pollInFlight = pollOnce(options).finally(() => { pollInFlight = null })
      return pollInFlight
    },

    /// Whether a pid is one we captured. The kill control checks this: agentd must never terminate
    /// an arbitrary pid supplied over the wire, only work it watched the agent start.
    isTracked(pid) {
      return tracked.has(Number(pid))
    },

    async validateTracked(pid, options = {}) {
      const normalizedPid = Number(pid)
      const expectedIdentity = trackedIdentities.get(normalizedPid)
      if (!expectedIdentity) return false
      throwIfAborted(options.signal)
      const row = parseProcessTable(await snapshot(options))
        .find((candidate) => candidate.pid === normalizedPid)
      throwIfAborted(options.signal)
      // A monitor poll may have updated this pid while the validation snapshot was in flight. Old
      // evidence must never authorize a newer tracked generation or delete its entry.
      if (trackedIdentities.get(normalizedPid) !== expectedIdentity) return false
      if (processIdentity(row) === expectedIdentity) return true
      forgetTracked(normalizedPid)
      return false
    },

    forget(pid) {
      forgetTracked(Number(pid))
    },
  }
}

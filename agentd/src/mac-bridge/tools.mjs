// The three things this Mac can offer an assistant that a cloud model cannot reach.
//
// Every argument that reaches a process does so through execFile with an argument array — never a
// shell string. A shortcut name is additionally checked against the machine's real list rather than
// pattern-matched, because "is this a name the user actually has" is the only validation that
// cannot be argued with.

import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const run = promisify(execFile)
const here = path.dirname(fileURLToPath(import.meta.url))

const SHORTCUTS_BIN = '/usr/bin/shortcuts'
const RUN_TIMEOUT_MS = 120_000
const ON_DEVICE_TIMEOUT_MS = 60_000

export async function listShortcuts({ exec = run } = {}) {
  const { stdout } = await exec(SHORTCUTS_BIN, ['list'], { timeout: 15_000 })
  return stdout.split('\n').map((line) => line.trim()).filter(Boolean)
}

/**
 * Run one of the user's Shortcuts. `name` must match a shortcut that exists; anything else is
 * refused by name rather than sanitized, so there is no escaping question to get wrong.
 */
export async function runShortcut({ name, input }, { exec = run, list = listShortcuts } = {}) {
  if (typeof name !== 'string' || !name.trim()) {
    throw new Error('A shortcut name is required.')
  }
  const available = await list({ exec })
  if (!available.includes(name)) {
    throw new Error(`No shortcut named “${name}” exists on this Mac.`)
  }
  const args = ['run', name]
  let inputFile
  try {
    if (typeof input === 'string' && input.length) {
      // Passing input as a file keeps arbitrary text out of argv, where it would be visible to
      // every other process on the machine via ps.
      inputFile = path.join(
        fs.mkdtempSync(path.join(os.tmpdir(), 'mac-bridge-')), 'input.txt')
      fs.writeFileSync(inputFile, input, { mode: 0o600 })
      args.push('--input-path', inputFile)
    }
    const { stdout, stderr } = await exec(SHORTCUTS_BIN, args, { timeout: RUN_TIMEOUT_MS })
    const output = (stdout || '').trim()
    return output || (stderr || '').trim() || `Ran “${name}”.`
  } finally {
    if (inputFile) fs.rmSync(path.dirname(inputFile), { recursive: true, force: true })
  }
}

/// Where the compiled on-device helper is cached. Keyed by a hash of the source so an edited helper
/// rebuilds instead of silently running the previous one.
export function onDeviceBinaryPath(source = path.join(here, 'on-device.swift')) {
  const digest = createHash('sha256').update(fs.readFileSync(source)).digest('hex').slice(0, 12)
  return path.join(os.tmpdir(), `mechanician-on-device-${digest}`)
}

export async function ensureOnDeviceBinary({ exec = run, source = path.join(here, 'on-device.swift') } = {}) {
  // A shipped app cannot depend on swiftc: it belongs to the developer tools, and invoking it on a
  // Mac without them pops the "install developer tools" dialog instead of answering a prompt. The
  // release build compiles this helper and drops it beside the source, so the compile path below is
  // only ever taken in a working tree.
  const prebuilt = path.join(here, 'on-device')
  if (fs.existsSync(prebuilt)) return prebuilt

  const binary = onDeviceBinaryPath(source)
  if (fs.existsSync(binary)) return binary
  if (!fs.existsSync('/usr/bin/swiftc')) {
    throw new Error('The on-device model helper is unavailable in this build.')
  }
  await exec('/usr/bin/swiftc', ['-O', source, '-o', binary], { timeout: 180_000 })
  return binary
}

/**
 * Ask Apple's on-device model. Free, private, offline — the reason an agent would route cheap
 * classification or extraction here instead of spending cloud tokens on it.
 */
export async function askOnDevice({ prompt }, { exec = run, ensure = ensureOnDeviceBinary } = {}) {
  if (typeof prompt !== 'string' || !prompt.trim()) {
    throw new Error('A prompt is required.')
  }
  const binary = await ensure({ exec })
  try {
    const { stdout } = await exec(binary, [prompt], { timeout: ON_DEVICE_TIMEOUT_MS })
    return stdout.trim()
  } catch (error) {
    // swiftc/exec surface the helper's stderr here; it already explains itself (for example that
    // Apple Intelligence is switched off), so pass that through rather than a generic failure.
    const detail = (error?.stderr || error?.message || '').toString().trim()
    throw new Error(detail || 'The on-device model could not answer.')
  }
}

export const TOOL_DEFINITIONS = [
  {
    name: 'list_shortcuts',
    title: 'List Shortcuts',
    description:
      "List the Shortcuts available on this Mac. These are the user's own automations and are the "
      + 'set of names accepted by run_shortcut.',
    inputSchema: {},
  },
  {
    name: 'run_shortcut',
    title: 'Run a Shortcut',
    description:
      'Run one of this Mac\'s Shortcuts by name and return its output. The name must come from '
      + 'list_shortcuts. Shortcuts can have real side effects, so prefer reading before acting.',
    inputSchema: {
      name: { type: 'string', description: 'Exact shortcut name, as returned by list_shortcuts.' },
      input: { type: 'string', description: 'Optional text input passed to the shortcut.' },
    },
  },
  {
    name: 'ask_on_device',
    title: 'Ask the on-device model',
    description:
      "Answer a self-contained prompt with Apple's on-device foundation model. Runs locally: no "
      + 'network, no cost, nothing leaves this Mac. Good for classification, extraction, short '
      + 'rewrites and triage; it is a small model, so do not use it for long reasoning.',
    inputSchema: {
      prompt: { type: 'string', description: 'A self-contained instruction or question.' },
    },
  },
]

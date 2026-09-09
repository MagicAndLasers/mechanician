import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'

import {
  escapingWriteTarget,
  pathContains,
  resolveExistingAncestor,
  writeEscapeAllowKey,
} from '../src/write-containment.mjs'

function makeWorkspace() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-containment-'))
  // realpath: macOS temp dirs are symlinked through /private.
  return fs.realpathSync(root)
}

// These fixtures necessarily live under the real temp directory, which the guard always allows.
// Point the allowance elsewhere so a fixture escape is not swallowed by it.
const ISOLATED = {
  temporaryDirectories: [path.join(os.tmpdir(), 'mechanician-not-a-real-tmp')],
}

test('writes inside the workspace are not escapes', () => {
  const root = makeWorkspace()
  fs.mkdirSync(path.join(root, 'app'), { recursive: true })
  assert.equal(
    escapingWriteTarget('Edit', { file_path: path.join(root, 'app/File.swift') }, root),
    null)
})

test('a write to a path that does not exist yet is still contained', () => {
  const root = makeWorkspace()
  assert.equal(
    escapingWriteTarget('Write', { file_path: path.join(root, 'new/deep/file.txt') }, root),
    null)
})

test('a traversal out of the workspace is an escape', () => {
  const root = makeWorkspace()
  const target = escapingWriteTarget(
    'Write', { file_path: path.join(root, '..', 'elsewhere.txt') }, root, ISOLATED)
  assert.ok(target, 'expected an escape')
  assert.ok(!target.startsWith(root + path.sep))
})

/// The separator matters. `<root>-codex` used to look like it was inside `<root>`, which would
/// have silently allowed writes into a sibling checkout of the same repo.
test('a sibling directory sharing the workspace name prefix is an escape', () => {
  const root = makeWorkspace()
  const sibling = `${root}-codex`
  fs.mkdirSync(sibling, { recursive: true })
  assert.ok(
    escapingWriteTarget('Edit', { file_path: path.join(sibling, 'x.swift') }, root, ISOLATED))
  assert.equal(pathContains(root, sibling), false)
})

test('the temp directory is always writable', () => {
  const root = makeWorkspace()
  assert.equal(
    escapingWriteTarget(
      'Write', { file_path: path.join(os.tmpdir(), 'scratch.txt') }, root),
    null)
})

/// The reported case. On macOS `os.tmpdir()` is the PER-USER temp ($TMPDIR, `/var/folders/<...>/T`)
/// and `/tmp` is a symlink to `/private/tmp`, so allowing only `os.tmpdir()` left the directory
/// everyone actually means by "temp" outside every writable root. It prompted in every permission
/// mode, including bypassPermissions, because containment runs ahead of the mode check.
test('the system temp directories are writable, not just the per-user one', () => {
  const root = makeWorkspace()
  for (const target of [
    '/tmp/scratch.txt',
    '/tmp/nested/scratch.txt',
    '/private/tmp/scratch.txt',
    '/var/tmp/scratch.txt',
  ]) {
    assert.equal(
      escapingWriteTarget('Write', { file_path: target }, root), null,
      `${target} must not require approval`)
  }
})

/// The allowance must stay an allowance, not a hole. A path that merely shares the prefix of a
/// temp root is still an escape, by the same separator rule the sibling-checkout case covers.
test('a sibling of a system temp root is still an escape', () => {
  const root = makeWorkspace()
  assert.ok(
    escapingWriteTarget('Write', { file_path: '/tmpfoo/x.txt' }, root),
    '/tmpfoo is not /tmp')
  assert.ok(
    escapingWriteTarget('Write', { file_path: '/var/tmpfoo/x.txt' }, root),
    '/var/tmpfoo is not /var/tmp')
})

/// Bash is out of scope on purpose: its target is not knowable before it runs.
test('tools without a knowable path are not gated', () => {
  const root = makeWorkspace()
  assert.equal(escapingWriteTarget('Bash', { command: `rm -rf ${root}/..` }, root), null)
  assert.equal(escapingWriteTarget('Read', { file_path: '/etc/hosts' }, root), null)
})

test('malformed input never fabricates an escape', () => {
  const root = makeWorkspace()
  assert.equal(escapingWriteTarget('Edit', {}, root), null)
  assert.equal(escapingWriteTarget('Edit', { file_path: '' }, root), null)
  assert.equal(escapingWriteTarget('Edit', { file_path: 42 }, root), null)
  assert.equal(escapingWriteTarget('Edit', null, root), null)
})

/// A symlink inside the workspace pointing out of it must not launder a write.
test('a symlink out of the workspace resolves to its real target', () => {
  const root = makeWorkspace()
  const outside = makeWorkspace()
  const link = path.join(root, 'escape-hatch')
  fs.symlinkSync(outside, link)
  const target = escapingWriteTarget(
    'Write', { file_path: path.join(link, 'x.txt') }, root, ISOLATED)
  assert.ok(target, 'a symlinked path must resolve to its real location')
  assert.ok(target.startsWith(outside))
})

/// Grants are per folder, which is what keeps the prompt count survivable: on this machine's real
/// history 1076 escaping writes reduce to 31 decisions.
test('grants are keyed by containing folder, not by file', () => {
  const a = writeEscapeAllowKey('/Users/x/dev/other/src/One.swift')
  const b = writeEscapeAllowKey('/Users/x/dev/other/src/Two.swift')
  assert.equal(a, b)
  assert.notEqual(a, writeEscapeAllowKey('/Users/x/dev/other/lib/Three.swift'))
})

test('resolveExistingAncestor keeps the non-existent tail', () => {
  const root = makeWorkspace()
  const resolved = resolveExistingAncestor(path.join(root, 'a/b/c.txt'))
  assert.equal(resolved, path.join(root, 'a/b/c.txt'))
})

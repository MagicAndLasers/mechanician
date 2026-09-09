import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

import {
  effectiveWorkspaceInstructions,
  isReservedWorkspaceID,
  readBoundedRootInstructions,
  readWorkspaceInstructionContext,
} from '../src/workspace-instructions.mjs'

function fixture(t) {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-instructions-'))
  fs.mkdirSync(path.join(support, 'workspaces'), { recursive: true })
  t.after(() => fs.rmSync(support, { recursive: true, force: true }))
  return support
}

test('Home reads only its app-owned settings and never the home-folder CLAUDE file', (t) => {
  const support = fixture(t)
  fs.writeFileSync(path.join(support, 'home-workspace.json'), JSON.stringify({
    instructions: 'Home policy',
  }))

  const context = readWorkspaceInstructionContext({ supportDirectory: support })

  assert.equal(context.target, 'home')
  assert.equal(context.cwd, null)
  assert.equal(effectiveWorkspaceInstructions(context, 'anthropic_api'),
    'Workspace Instructions (Mechanician):\nHome policy')
})

test('a Project gives Claude bounded root guidance first and app instructions last', (t) => {
  const support = fixture(t)
  const root = path.join(support, 'repo')
  const id = 'A9EAA4D5-8906-4F61-81C2-6CD74571AE11'
  fs.mkdirSync(root)
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), 'Repository policy')
  fs.writeFileSync(path.join(support, 'workspaces', `${id}.json`), JSON.stringify({
    id, cwd: root, instructions: 'App policy',
  }))

  const context = readWorkspaceInstructionContext({
    supportDirectory: support, workspaceID: id,
  })

  assert.equal(context.cwd, root)
  assert.equal(effectiveWorkspaceInstructions(context, 'anthropic_api'),
    'Repository instructions (CLAUDE.md):\nRepository policy\n\n'
      + 'Workspace Instructions (Mechanician):\nApp policy')
  assert.equal(effectiveWorkspaceInstructions(context, 'openai_api'), 'App policy',
    'OpenAI must not receive a Claude repository file')
})

test('the canonical Workspace record wins over a divergent rolling-upgrade fallback', (t) => {
  const support = fixture(t)
  const id = 'A9EAA4D5-8906-4F61-81C2-6CD74571AE12'
  fs.mkdirSync(path.join(support, 'projects'), { recursive: true })
  fs.writeFileSync(path.join(support, 'projects', `${id}.json`), JSON.stringify({
    id, instructions: 'Legacy policy',
  }))
  fs.writeFileSync(path.join(support, 'workspaces', `${id}.json`), JSON.stringify({
    id, instructions: 'Canonical policy',
  }))

  const context = readWorkspaceInstructionContext({ supportDirectory: support, workspaceID: id })

  assert.equal(context.appText, 'Canonical policy')
})

test('a legacy Workspace remains readable during the pre-migration rolling-upgrade window', (t) => {
  const support = fixture(t)
  const id = 'A9EAA4D5-8906-4F61-81C2-6CD74571AE13'
  fs.mkdirSync(path.join(support, 'projects'), { recursive: true })
  fs.writeFileSync(path.join(support, 'projects', `${id}.json`), JSON.stringify({
    id, instructions: 'Legacy policy',
  }))

  const context = readWorkspaceInstructionContext({ supportDirectory: support, workspaceID: id })

  assert.equal(context.appText, 'Legacy policy')
})

test('a dangling workspace id never falls through to Home', (t) => {
  const support = fixture(t)
  fs.writeFileSync(path.join(support, 'home-workspace.json'), JSON.stringify({
    instructions: 'Home policy',
  }))

  const context = readWorkspaceInstructionContext({
    supportDirectory: support, workspaceID: 'DELETED',
  })

  assert.equal(context.target, 'unresolved:DELETED')
  assert.equal(effectiveWorkspaceInstructions(context, 'anthropic_api'), null)
})

test('the reserved Help workspace never resolves for unattended work', (t) => {
  const support = fixture(t)
  const id = 'D353F793-FC8A-497C-BF64-BD396EF2F367'
  fs.writeFileSync(path.join(support, 'workspaces', `${id}.json`), JSON.stringify({
    id, cwd: support, instructions: 'Must remain interactive',
  }))

  assert.equal(isReservedWorkspaceID(id.toLowerCase()), true)
  const context = readWorkspaceInstructionContext({ supportDirectory: support, workspaceID: id })
  assert.equal(context.target, `unresolved:${id}`)
  assert.equal(context.cwd, null)
  assert.equal(effectiveWorkspaceInstructions(context, 'anthropic_api'), null)
})

// The Memory workspace was reserved until 2026-09-02. Its row survives on existing installs as an
// ordinary folderless Workspace someone may rename, use or delete, so it must resolve like any
// other: holding it would strand a task for a repair that has nothing left to repair. This asserts
// the release rather than leaving it to the absence of an id in a set, because the id is still
// present on real machines and a silent re-add would be indistinguishable from the old behaviour.
test('the retired Memory workspace resolves as an ordinary folderless Workspace', (t) => {
  const support = fixture(t)
  const id = '3E3B9C4A-6A1E-4E9C-9C51-7B1D2A5F0E44'
  fs.writeFileSync(path.join(support, 'workspaces', `${id}.json`), JSON.stringify({
    id, cwd: '', instructions: 'Ordinary now',
  }))

  assert.equal(isReservedWorkspaceID(id.toLowerCase()), false)
  const context = readWorkspaceInstructionContext({ supportDirectory: support, workspaceID: id })
  assert.equal(context.target, `project:${id}`)
  assert.equal(context.cwd, null)
  assert.equal(context.appText, 'Ordinary now')
})

test('the unattended denylist covers every fixed app-owned reserved Workspace id', () => {
  const swift = fs.readFileSync(new URL(
    '../../app/Sources/Mechanician/ReservedWorkspace.swift', import.meta.url,
  ), 'utf8')
  const ids = [...swift.matchAll(/UUID\(uuidString: "([0-9A-F-]+)"\)!/g)]
    .map((match) => match[1])

  assert.ok(ids.length > 0, 'the Swift registry must expose at least one fixed reserved id')
  for (const id of ids) {
    assert.equal(isReservedWorkspaceID(id), true, `${id} is missing from the unattended denylist`)
  }
})

test('an invalid workspace id cannot escape the workspaces directory', (t) => {
  const support = fixture(t)
  fs.writeFileSync(path.join(support, 'home-workspace.json'), JSON.stringify({
    id: 'outside',
    instructions: 'Must not be reached',
  }))

  const context = readWorkspaceInstructionContext({
    supportDirectory: support, workspaceID: '../home-workspace',
  })

  assert.equal(context.target, 'unresolved:../home-workspace')
  assert.equal(effectiveWorkspaceInstructions(context, 'anthropic_api'), null)
})

test('repository instruction reads reject symlinks, binary files, and oversized files', (t) => {
  const support = fixture(t)
  const outside = path.join(support, 'outside.md')
  fs.writeFileSync(outside, 'secret')
  fs.symlinkSync(outside, path.join(support, 'CLAUDE.md'))
  assert.equal(readBoundedRootInstructions(support), null)

  fs.unlinkSync(path.join(support, 'CLAUDE.md'))
  fs.writeFileSync(path.join(support, 'CLAUDE.md'), Buffer.from([65, 0, 66]))
  assert.equal(readBoundedRootInstructions(support), null)

  fs.writeFileSync(path.join(support, 'CLAUDE.md'), '12345')
  assert.equal(readBoundedRootInstructions(support, 'CLAUDE.md', 4), null)
})

test('the projection answers instead of the frozen files once SQLite owns the library', (t) => {
  const support = fixture(t)
  const projection = path.join(support, 'ambient-projection')
  const root = path.join(support, 'repo')
  const id = 'A9EAA4D5-8906-4F61-81C2-6CD74571AE11'
  fs.mkdirSync(root)
  fs.mkdirSync(projection, { recursive: true })
  // What the cutover froze: an old cwd and old instructions that must no longer be answered with.
  fs.writeFileSync(path.join(support, 'home-workspace.json'), JSON.stringify({
    instructions: 'Home policy as it stood at the cutover',
  }))
  fs.writeFileSync(path.join(support, 'workspaces', `${id}.json`), JSON.stringify({
    id, cwd: path.join(support, 'gone'), instructions: 'Stale app policy',
  }))
  fs.writeFileSync(path.join(projection, 'workspaces.json'), JSON.stringify({
    home: { instructions: 'Home policy edited after the cutover' },
    workspaces: [{ id, cwd: root, instructions: 'App policy edited after the cutover' }],
  }))

  const workspace = readWorkspaceInstructionContext({
    supportDirectory: support, projectionDirectory: projection, workspaceID: id,
  })
  assert.equal(workspace.target, `project:${id}`)
  assert.equal(workspace.cwd, root)
  assert.equal(workspace.appText, 'App policy edited after the cutover')

  const home = readWorkspaceInstructionContext({
    supportDirectory: support, projectionDirectory: projection,
  })
  assert.equal(home.appText, 'Home policy edited after the cutover')
})

test('a Workspace created after the cutover resolves, instead of running from the home folder', (t) => {
  const support = fixture(t)
  const projection = path.join(support, 'ambient-projection')
  const root = path.join(support, 'new-repo')
  const id = 'B1C3E5F7-1111-4222-8333-444455556666'
  fs.mkdirSync(root)
  fs.mkdirSync(projection, { recursive: true })
  // Deliberately absent from `workspaces/`: it never existed when the snapshot was taken.
  fs.writeFileSync(path.join(projection, 'workspaces.json'), JSON.stringify({
    home: { instructions: '' },
    workspaces: [{ id, cwd: root, instructions: 'New workspace policy' }],
  }))

  const context = readWorkspaceInstructionContext({
    supportDirectory: support, projectionDirectory: projection, workspaceID: id,
  })
  assert.equal(context.target, `project:${id}`)
  assert.equal(context.cwd, root)
})

test('a Workspace deleted after the cutover stops resolving through its frozen file', (t) => {
  const support = fixture(t)
  const projection = path.join(support, 'ambient-projection')
  const id = 'C2D4E6F8-1111-4222-8333-444455556666'
  fs.mkdirSync(projection, { recursive: true })
  fs.writeFileSync(path.join(support, 'workspaces', `${id}.json`), JSON.stringify({
    id, cwd: support, instructions: 'Deleted workspace policy',
  }))
  fs.writeFileSync(path.join(projection, 'workspaces.json'), JSON.stringify({
    home: { instructions: '' }, workspaces: [],
  }))

  const context = readWorkspaceInstructionContext({
    supportDirectory: support, projectionDirectory: projection, workspaceID: id,
  })
  assert.equal(context.target, `unresolved:${id}`)
  assert.equal(context.cwd, null)
  assert.equal(context.appText, null)
})

test('a legacy library keeps reading its own files when no projection exists', (t) => {
  const support = fixture(t)
  const projection = path.join(support, 'ambient')
  const id = 'D3E5F7A9-1111-4222-8333-444455556666'
  fs.mkdirSync(projection, { recursive: true })
  fs.writeFileSync(path.join(support, 'workspaces', `${id}.json`), JSON.stringify({
    id, cwd: support, instructions: 'Legacy policy',
  }))

  const context = readWorkspaceInstructionContext({
    supportDirectory: support, projectionDirectory: projection, workspaceID: id,
  })
  assert.equal(context.target, `project:${id}`)
  assert.equal(context.appText, 'Legacy policy')
})

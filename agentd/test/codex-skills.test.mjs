import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'

import {
  codexCommandsFromSkillsList,
  discoverCodexSkills,
  requestCodexSkills,
} from '../src/codex-skills.mjs'

function skill(root, relative, frontmatter) {
  const directory = path.join(root, 'skills', relative)
  fs.mkdirSync(directory, { recursive: true })
  fs.writeFileSync(path.join(directory, 'SKILL.md'), `---\n${frontmatter}\n---\n\n# Body\n`)
}

test('Codex built-in and user skills become dollar-prefixed picker entries', (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-skills-'))
  t.after(() => fs.rmSync(home, { recursive: true, force: true }))
  skill(home, '.system/imagegen', 'name: imagegen\ndescription: "Generate an image."')
  skill(home, 'team-review', "name: team-review\ndescription: 'Review with the team.'")

  assert.deepEqual(discoverCodexSkills(home), [
    {
      name: 'imagegen', description: 'Generate an image.', argumentHint: '',
      invocationPrefix: '$',
    },
    {
      name: 'team-review', description: 'Review with the team.', argumentHint: '',
      invocationPrefix: '$',
    },
  ])
})

test('user skill overrides a system skill and malformed or symlinked entries are ignored', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-skills-'))
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-skills-outside-'))
  t.after(() => {
    fs.rmSync(root, { recursive: true, force: true })
    fs.rmSync(outside, { recursive: true, force: true })
  })
  skill(root, '.system/review', 'name: review\ndescription: System')
  skill(root, 'review', 'name: review\ndescription: User')
  skill(root, 'unsafe', 'name: "../../escape"\ndescription: No')
  skill(outside, 'linked', 'name: linked\ndescription: No')
  fs.symlinkSync(path.join(outside, 'skills', 'linked'), path.join(root, 'skills', 'linked'))

  assert.deepEqual(discoverCodexSkills(root), [{
    name: 'review', description: 'User', argumentHint: '', invocationPrefix: '$',
  }])
})

test('App Server inventory includes enabled system, repository, and namespaced plugin skills', () => {
  const cwd = '/work/project'
  const result = codexCommandsFromSkillsList({
    data: [{
      cwd,
      skills: [
        { name: 'imagegen', description: 'Images', enabled: true, scope: 'system' },
        { name: 'team-review', description: 'Repository review', enabled: true, scope: 'repo' },
        {
          name: 'spreadsheets:spreadsheets',
          description: 'Build spreadsheets',
          enabled: true,
          scope: 'user',
        },
        { name: 'disabled', description: 'Hidden', enabled: false, scope: 'user' },
      ],
      errors: [],
    }],
  }, cwd)

  assert.deepEqual(result.commands, [
    {
      name: 'imagegen', description: 'Images', argumentHint: '',
      invocationPrefix: '$',
    },
    {
      name: 'spreadsheets:spreadsheets', description: 'Build spreadsheets', argumentHint: '',
      invocationPrefix: '$',
    },
    {
      name: 'team-review', description: 'Repository review', argumentHint: '',
      invocationPrefix: '$',
    },
  ])
  assert.deepEqual(result.errors, [])
})

test('App Server inventory keeps the first same-name skill and bounds provider text', () => {
  const cwd = '/work/project'
  const result = codexCommandsFromSkillsList({
    data: [{
      cwd,
      skills: [
        { name: 'review', description: 'First', enabled: true },
        { name: 'review', description: 'Second', enabled: true },
        {
          name: 'fallback-description',
          interface: { shortDescription: 'From interface' },
          enabled: true,
        },
        { name: '../../unsafe', description: 'No', enabled: true },
      ],
      errors: [{ message: 'one optional skill was malformed' }],
    }],
  }, cwd)

  assert.equal(result.commands.find((command) => command.name === 'review').description, 'First')
  assert.equal(
    result.commands.find((command) => command.name === 'fallback-description').description,
    'From interface')
  assert.equal(result.commands.some((command) => command.name === '../../unsafe'), false)
  assert.equal(result.errors.length, 1)
})

test('requestCodexSkills uses the authoritative cwd-scoped protocol with a forced reload', async () => {
  const calls = []
  const app = {
    async request(method, params, timeoutMs) {
      calls.push({ method, params, timeoutMs })
      return { data: [{ cwd: '/work/project', skills: [], errors: [] }] }
    },
  }

  const result = await requestCodexSkills(app, { cwd: '/work/project', timeoutMs: 1234 })

  assert.deepEqual(calls, [{
    method: 'skills/list',
    params: { cwds: ['/work/project'], forceReload: true },
    timeoutMs: 1234,
  }])
  assert.deepEqual(result.commands, [])
})

test('a malformed skills/list response fails explicitly so the daemon can retain its last catalog', () => {
  assert.throws(
    () => codexCommandsFromSkillsList({ data: [] }, '/work/project'),
    /returned no inventory/)
})

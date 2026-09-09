import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const RUNTIME_SOURCE = join(REPO, 'scripts/runtime')

/// The bundle layout the app puts on PATH, with a stub `node` that reports how it was called.
function fixtureResources() {
  const root = mkdtempSync(join(tmpdir(), 'mechanician-runtime-wrappers.'))
  const resources = join(root, 'Resources')
  mkdirSync(join(resources, 'npm', 'bin'), { recursive: true })
  mkdirSync(join(resources, 'runtime'), { recursive: true })
  writeFileSync(join(resources, 'node'), '#!/bin/sh\necho "argv:$*"\necho "prefix:$npm_config_prefix"\n')
  chmodSync(join(resources, 'node'), 0o755)
  for (const cli of ['npm-cli.js', 'npx-cli.js']) writeFileSync(join(resources, 'npm', 'bin', cli), '')
  for (const wrapper of readdirSync(RUNTIME_SOURCE)) {
    cpSync(join(RUNTIME_SOURCE, wrapper), join(resources, 'runtime', wrapper))
    chmodSync(join(resources, 'runtime', wrapper), 0o755)
  }
  symlinkSync('../node', join(resources, 'runtime', 'node'))
  return { root, resources }
}

function runOnPath(command, pathEntries, home) {
  return spawnSync('/bin/zsh', ['-f', '-c', command], {
    env: { PATH: pathEntries.join(':'), HOME: home },
    encoding: 'utf8',
  })
}

test('a bare npm resolves through the bundled runtime directory', () => {
  const { root, resources } = fixtureResources()
  try {
    for (const command of ['npm', 'npx']) {
      const result = runOnPath(`${command} --version`, [join(resources, 'runtime'), '/usr/bin', '/bin'], root)
      assert.equal(result.status, 0, `${command} failed: ${result.stderr}`)
      // The wrapper must reach the CLI beside the payload, one level up from its own directory.
      assert.match(result.stdout, new RegExp(`argv:.*/npm/bin/${command}-cli\\.js --version`))
    }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('a bare node resolves to the bundled runtime on a Mac that has none', () => {
  const { root, resources } = fixtureResources()
  try {
    const result = runOnPath('node --version', [join(resources, 'runtime'), '/usr/bin', '/bin'], root)
    assert.equal(result.status, 0, result.stderr)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('npm installs globally outside the signed application bundle', () => {
  const { root, resources } = fixtureResources()
  try {
    const result = runOnPath('npm --version', [join(resources, 'runtime'), '/usr/bin', '/bin'], root)
    const prefix = /prefix:(.*)/.exec(result.stdout)?.[1] ?? ''
    // npm derives its global prefix from the Node executable's grandparent, which in a real bundle
    // is the sealed `Mechanician.app/Contents`. `npm install -g` must not aim there.
    assert.ok(prefix.length > 0, `no npm_config_prefix exported: ${result.stdout}`)
    assert.ok(!prefix.includes('.app/Contents'), `global prefix targets the app bundle: ${prefix}`)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('an unexecutable directory named for a command reads as a permission failure', () => {
  // This is the reported bug in one assertion. `Contents/Resources` held the npm payload as a bare
  // directory and was itself on PATH, so a bare `npm` found a directory, and zsh answered
  // "permission denied" with status 126 — which an agent relays to the person as a blocked command.
  const root = mkdtempSync(join(tmpdir(), 'mechanician-runtime-shadow.'))
  try {
    mkdirSync(join(root, 'npm'))
    const result = runOnPath('npm --version', [root, '/usr/bin', '/bin'], root)
    assert.equal(result.status, 126)
    assert.match(result.stderr, /permission denied/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('the build stages every wrapper into the runtime directory and refuses an incomplete one', () => {
  const build = readFileSync(join(REPO, 'build-app.sh'), 'utf8')
  assert.match(build, /RUNTIME_BIN="\$APP\/Contents\/Resources\/runtime"/)
  assert.match(build, /for wrapper in "\$REPO"\/scripts\/runtime\/\*/)
  assert.match(build, /ln -sf \.\.\/node "\$RUNTIME_BIN\/node"/)
  // A half-staged runtime leaves stdio MCP servers dead on a stock Mac; fail the build instead.
  assert.match(build, /for required in node npm npx/)
  // No wrapper may be staged directly into Resources, where the payload directory shadows it.
  assert.ok(
    !/scripts\/runtime\/\w+" "\$APP\/Contents\/Resources\/\w+"/.test(build),
    'a runtime wrapper is still staged directly into Contents/Resources')
})

import assert from 'node:assert/strict'
import test from 'node:test'
import crypto from 'node:crypto'
import fs from 'node:fs'

const repoRoot = new URL('../../', import.meta.url)
const read = (path, encoding = 'utf8') => fs.readFileSync(new URL(path, repoRoot), encoding)
const packageJSON = JSON.parse(read('agentd/package.json'))
const packageLock = JSON.parse(read('agentd/package-lock.json'))
const packageResolved = JSON.parse(read('app/Package.resolved'))
const packageManifest = read('app/Package.swift')
const notices = read('THIRD-PARTY-NOTICES.md')
const buildScript = read('build-app.sh')

const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

function captured(source, pattern, label) {
  const value = source.match(pattern)?.[1]
  assert.ok(value, `${label} is missing`)
  return value
}

function assertNoticed(name, version) {
  assert.match(
    notices,
    new RegExp(`\\*\\*${escapeRegExp(name)} ${escapeRegExp(version)}(?=[ *(])`),
    `${name} ${version} is missing from THIRD-PARTY-NOTICES.md`)
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

test('every direct production npm dependency is exact, locked, and noticed', () => {
  const lockRootDependencies = packageLock.packages[''].dependencies

  for (const [name, version] of Object.entries(packageJSON.dependencies)) {
    assert.match(version, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, `${name} must use an exact version`)
    assert.equal(lockRootDependencies[name], version, `${name} root lock pin`)
    assert.equal(packageLock.packages[`node_modules/${name}`]?.version, version, `${name} installed lock pin`)
    assertNoticed(name, version)
  }
})

test('the bundled Node, npm, Codex, Mermaid, and display font stay pinned and noticed', () => {
  const nodeVersion = captured(buildScript, /DEFAULT_NODE_VERSION="v([^"]+)"/, 'Node version pin')
  const npmVersion = captured(buildScript, /DEFAULT_NPM_VERSION="([^"]+)"/, 'npm version pin')
  const codexVersion = captured(buildScript, /BUNDLED_CODEX_VERSION="([^"]+)"/, 'Codex version pin')
  const mermaidBytes = read('app/Resources/mermaid.min.js', null)
  const mermaidSource = mermaidBytes.toString('utf8')
  const fontBytes = read('app/Resources/dm-serif-display-latin.woff2', null)

  assertNoticed('Node.js', nodeVersion)
  assertNoticed('npm', npmVersion)
  assert.equal(codexVersion, packageJSON.dependencies['@openai/codex'])
  assertNoticed('@openai/codex', codexVersion)
  assert.match(
    buildScript,
    /EXPECTED_NPM_VERSION="\$\{MECHANICIAN_NPM_VERSION:-\$DEFAULT_NPM_VERSION\}"/,
    'a Node archive override must be able to declare its expected npm version')
  assert.match(
    buildScript,
    /\[ "\$BUNDLED_NPM_VERSION" = "\$EXPECTED_NPM_VERSION" \]/,
    'the archive-embedded npm version must be checked during packaging')

  const mermaidVersion = '11.17.0'
  assert.match(mermaidSource, new RegExp(`version:"${escapeRegExp(mermaidVersion)}"`))
  assert.equal(sha256(mermaidBytes), '8d8e0eec56d3a83b4b3c87f42050845546dee93ebe1875d2117c12e6947c0cb3')
  assertNoticed('Mermaid', mermaidVersion)
  assert.equal(sha256(fontBytes), 'f273cf2c9ce9bc7d6b0f4fcb8aee72f8cf5a249991308b6a144217e0760c5d3f')
  assert.match(notices, /\*\*DM Serif Display Regular\*\*/)
  assert.ok(buildScript.includes(
    'cp "$REPO/app/Resources/mermaid.min.js" "$APP/Contents/Resources/mermaid.min.js"'))
  assert.ok(buildScript.includes(
    'PRODUCT_DISPLAY_FONT="$REPO/app/Resources/dm-serif-display-latin.woff2"'))
})

test('the notice follows every SwiftPM product linked into the application', () => {
  const pins = new Map(packageResolved.pins.map((pin) => [pin.identity.toLowerCase(), pin]))
  const linkedProducts = [...packageManifest.matchAll(
    /\.product\(name:\s*"([^"]+)",\s*package:\s*"([^"]+)"\)/g)]

  assert.ok(linkedProducts.length > 0, 'Package.swift must expose linked products to this check')
  for (const [, product, packageName] of linkedProducts) {
    const pin = pins.get(packageName.toLowerCase())
    assert.ok(pin, `${packageName} has no Package.resolved pin`)
    assert.ok(pin.state.version, `${packageName} is not pinned to a release version`)
    assertNoticed(product, pin.state.version)
  }
})

test('the top-level inventory covers direct dependencies and sparse transitive licenses', () => {
  const copiedDestinations = new Set([...buildScript.matchAll(
    /^copy_license\s+"[^"]+"\s+"([^"]+)"$/gm)].map((match) => match[1]))
  const directLicenseDestinations = new Map([
    ['@anthropic-ai/claude-agent-sdk', 'Anthropic-Claude-Agent-SDK.txt'],
    ['@modelcontextprotocol/sdk', 'Model-Context-Protocol-SDK-MIT.txt'],
    ['@openai/codex', 'OpenAI-Codex-Apache-2.0.txt'],
    ['diff', 'diff-BSD-3-Clause.txt'],
    ['isomorphic-git', 'isomorphic-git-MIT.txt'],
    ['node-pty', 'node-pty-MIT.txt'],
    ['zod', 'zod-MIT.txt']
  ])
  const sparseTransitiveLicenses = new Map([
    ['clean-git-ref', ['2.0.1', 'Apache-2.0']],
    ['diff3', ['0.0.3', 'MIT']],
    ['minimisted', ['2.0.1', 'MIT']],
    ['standardwebhooks', ['1.0.0', 'MIT']]
  ])

  assert.deepEqual(
    [...directLicenseDestinations.keys()].sort(),
    Object.keys(packageJSON.dependencies).sort(),
    'every direct production dependency needs an explicit top-level license inventory entry')
  for (const [name, destination] of directLicenseDestinations) {
    assert.ok(copiedDestinations.has(destination), `${name} license is not copied to the inventory`)
  }
  for (const destination of [
    'Node.js.txt',
    'npm.txt',
    'Sparkle-MIT.txt',
    'SwiftTerm-MIT.txt',
    'DM-Serif-Display-OFL.txt',
    'Mermaid-MIT.txt',
    'SwiftPM-Package.resolved.json',
    'npm-package-lock.json',
    'agentd-sbom.cdx.json'
  ]) {
    assert.ok(copiedDestinations.has(destination), `${destination} is not copied to the inventory`)
  }

  for (const [name, [version, license]] of sparseTransitiveLicenses) {
    const locked = packageLock.packages[`node_modules/${name}`]
    assert.equal(locked?.version, version, `${name} version changed; re-audit its published license files`)
    assert.equal(locked?.license, license, `${name} license declaration changed`)
    assert.ok(
      notices.includes(`\`${name} ${version}\``),
      `${name} ${version} sparse-license note is missing`)
  }

  const standardwebhooksLicense = read('agentd/licenses/standardwebhooks-MIT.txt', null)
  assert.equal(
    sha256(standardwebhooksLicense),
    '5ec8c7b26b64d881a6706617bed25c049f97f2f35de034c756de8546fd6dbe27')
  assert.ok(buildScript.includes(
    'copy_license "$REPO/agentd/licenses/standardwebhooks-MIT.txt" "standardwebhooks-MIT.txt"'))
  assert.ok(buildScript.includes(
    'copy_license "$AGENTD_STAGE/node_modules/@modelcontextprotocol/sdk/LICENSE" "Model-Context-Protocol-SDK-MIT.txt"'))
})

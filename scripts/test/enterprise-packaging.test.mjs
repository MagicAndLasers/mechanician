import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..')

function fixtureApp(root) {
  const app = join(root, 'Mechanician.app')
  const macOS = join(app, 'Contents', 'MacOS')
  mkdirSync(macOS, { recursive: true })
  cpSync('/usr/bin/true', join(macOS, 'Mechanician'))
  chmodSync(join(macOS, 'Mechanician'), 0o755)
  writeFileSync(join(app, 'Contents', 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Mechanician</string>
<key>CFBundleIdentifier</key><string>ai.mechanician.app</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>456</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>\n`)
  return app
}

test('release manifest binds exact artifact facts to the standard app identity', () => {
  const root = mkdtempSync(join(tmpdir(), 'mechanician-release-manifest-test.'))
  try {
    const app = fixtureApp(root)
    const artifact = join(root, 'Mechanician-1.2.3.pkg')
    const output = join(root, 'release.json')
    writeFileSync(artifact, 'exact artifact bytes')
    execFileSync(process.execPath, [
      join(REPO, 'scripts/generate-release-manifest.mjs'),
      '--app', app,
      '--base-url', 'https://downloads.example.invalid/releases/',
      '--output', output,
      '--artifact', `pkg=${artifact}`,
    ], { env: {
      ...process.env,
      MECHANICIAN_MANIFEST_TEAM_ID: 'ABCDE12345',
      MECHANICIAN_SIGNING_TEAM_ID: 'ABCDE12345',
    } })

    const manifest = JSON.parse(readFileSync(output, 'utf8'))
    assert.equal(manifest.schemaVersion, 1)
    const fixtureArchitectures = execFileSync('/usr/bin/lipo', ['-archs', '/usr/bin/true'], {
      encoding: 'utf8',
    }).trim().split(/\s+/)
    assert.deepEqual(manifest.app, {
      version: '1.2.3',
      build: '456',
      bundleIdentifier: 'ai.mechanician.app',
      teamIdentifier: 'ABCDE12345',
      minimumMacOS: '26.0',
      architectures: fixtureArchitectures,
    })
    assert.equal(manifest.artifacts.pkg.bytes, 20)
    assert.equal(
      manifest.artifacts.pkg.sha256,
      createHash('sha256').update('exact artifact bytes').digest('hex')
    )
    assert.equal(
      manifest.artifacts.pkg.url,
      'https://downloads.example.invalid/releases/Mechanician-1.2.3.pkg'
    )
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('managed-preferences generator emits a lintable forced policy for the app domain', () => {
  const root = mkdtempSync(join(tmpdir(), 'mechanician-mobileconfig-test.'))
  try {
    const output = join(root, 'Mechanician.mobileconfig')
    execFileSync(process.execPath, [
      join(REPO, 'scripts/generate-managed-preferences-profile.mjs'),
      '--config', join(REPO, 'docs/enterprise/managed-preferences-build.example.json'),
      '--output', output,
    ])
    execFileSync('/usr/bin/plutil', ['-lint', output])
    const json = JSON.parse(execFileSync(
      '/usr/bin/plutil', ['-convert', 'json', '-o', '-', output], { encoding: 'utf8' }
    ))
    const managed = json.PayloadContent[0].PayloadContent['ai.mechanician.app']
      .Forced[0].mcx_preference_settings.MechanicianManagedConfiguration
    assert.equal(managed.schemaVersion, 1)
    assert.equal(managed.policy.updateAuthority, 'sparkle')
    assert.equal(managed.policy.allowUnattendedTasks, false)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('managed-preferences generator rejects misspelled or contradictory policy', () => {
  const root = mkdtempSync(join(tmpdir(), 'mechanician-mobileconfig-invalid-test.'))
  try {
    const base = JSON.parse(readFileSync(
      join(REPO, 'docs/enterprise/managed-preferences-build.example.json'),
      'utf8'
    ))
    base.managedConfiguration.policy = {
      updateAuthority: 'mdm',
      sparkleAutomaticChecks: false,
      allowUnattendedTask: false,
    }
    const config = join(root, 'invalid.json')
    writeFileSync(config, JSON.stringify(base))
    const result = spawnSync(process.execPath, [
      join(REPO, 'scripts/generate-managed-preferences-profile.mjs'),
      '--config', config,
      '--output', join(root, 'invalid.mobileconfig'),
    ], { encoding: 'utf8' })

    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /unknown key: allowUnattendedTask/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('enterprise package contains only the standard app beneath Applications', () => {
  const root = mkdtempSync(join(tmpdir(), 'mechanician-pkg-test.'))
  try {
    const app = fixtureApp(root)
    const output = join(root, 'Mechanician.pkg')
    const result = spawnSync(
      join(REPO, 'scripts/create-enterprise-pkg.sh'), [app, output, '--unsigned'],
      { encoding: 'utf8' }
    )
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    const payload = execFileSync('/usr/sbin/pkgutil', ['--payload-files', output], {
      encoding: 'utf8',
    }).split('\n').filter(Boolean)
    assert(payload.some((path) => path === './Applications/Mechanician.app'))
    assert(payload.every((rawPath) => {
      const path = rawPath.replace(/^\.\//, '')
      return path === '.'
        || path === 'Applications'
        || path === '._Applications'
        || path === 'Applications/Mechanician.app'
        || path === 'Applications/._Mechanician.app'
        || path.startsWith('Applications/Mechanician.app/')
    }))
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('enterprise profile verifier rejects an unsigned lookalike', () => {
  const root = mkdtempSync(join(tmpdir(), 'mechanician-profile-verifier-test.'))
  try {
    const profile = join(root, 'Unsigned.mechanician-profile')
    writeFileSync(profile, JSON.stringify({
      documentVersion: 1,
      profile: { schemaVersion: 1, tenantId: 'example' },
      signature: Buffer.alloc(64).toString('base64'),
    }))
    const result = spawnSync(
      join(REPO, 'scripts/verify-enterprise-profile.swift'), [profile], { encoding: 'utf8' }
    )
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /signature is invalid/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('enterprise deployment parser accepts every required option before signature validation', () => {
  const root = mkdtempSync(join(tmpdir(), 'mechanician-deployment-parser-test.'))
  try {
    const artifact = {
      url: 'https://downloads.example.invalid/Mechanician-artifact',
      bytes: 1,
      sha256: 'a'.repeat(64),
    }
    const release = join(root, 'release.json')
    writeFileSync(release, JSON.stringify({
      schemaVersion: 1,
      product: 'Mechanician',
      app: {
        version: '1.2.3',
        build: '456',
        bundleIdentifier: 'ai.mechanician.app',
        teamIdentifier: '5YPG2C4S34',
        minimumMacOS: '26.0',
        architectures: ['arm64'],
      },
      artifacts: {
        dmg: artifact,
        pkg: artifact,
        provenance: artifact,
        sbom: artifact,
      },
    }))
    const profile = join(root, 'Unsigned.mechanician-profile')
    writeFileSync(profile, JSON.stringify({
      documentVersion: 1,
      profile: { schemaVersion: 1, tenantId: 'example', update: { revision: 1 } },
      signature: Buffer.alloc(64).toString('base64'),
    }))
    const result = spawnSync(process.execPath, [
      join(REPO, 'scripts/generate-enterprise-deployment.mjs'),
      '--release-manifest', release,
      '--signed-profile', profile,
      '--distribution-mode', 'manual',
      '--network-json-url', '/enterprise/network-allowlist.json',
      '--network-csv-url', '/enterprise/network-allowlist.csv',
      '--support-url', 'https://support.example.invalid/mechanician',
      '--output', join(root, 'deployment.json'),
    ], { encoding: 'utf8' })

    assert.notEqual(result.status, 0)
    assert.doesNotMatch(result.stderr, /unknown argument/)
    assert.match(result.stderr, /signature is invalid/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

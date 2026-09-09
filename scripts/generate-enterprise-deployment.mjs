#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

function fail(message) {
  process.stderr.write(`!! ${message}\n`)
  process.exit(1)
}

const options = {}
const args = process.argv.slice(2)
for (let index = 0; index < args.length; index += 2) {
  const flag = args[index]
  const value = args[index + 1]
  if (!value) fail(`${flag ?? 'argument'} requires a value`)
  const key = {
    '--release-manifest': 'releaseManifest',
    '--signed-profile': 'signedProfile',
    '--distribution-mode': 'distributionMode',
    '--managed-preferences': 'managedPreferences',
    '--managed-preferences-url': 'managedPreferencesURL',
    '--setup-kit': 'setupKit',
    '--setup-kit-url': 'setupKitURL',
    '--network-json-url': 'networkJSONURL',
    '--network-csv-url': 'networkCSVURL',
    '--support-url': 'supportURL',
    '--output': 'output',
  }[flag]
  if (!key) fail(`unknown argument: ${flag}`)
  options[key] = value
}

for (const required of [
  'releaseManifest', 'signedProfile', 'distributionMode', 'networkJSONURL',
  'networkCSVURL', 'supportURL', 'output',
]) {
  if (!options[required]) fail(`missing required option: ${required}`)
}
const modes = new Set(['manual', 'configuration-mdm', 'self-service', 'automatic'])
if (!modes.has(options.distributionMode)) fail('unsupported distribution mode')
if (options.distributionMode !== 'manual' && !options.managedPreferences) {
  fail('managed deployment mode requires --managed-preferences')
}
if (['self-service', 'automatic'].includes(options.distributionMode) && !options.managedPreferencesURL) {
  fail('managed deployment mode requires --managed-preferences-url')
}
if (Boolean(options.setupKit) !== Boolean(options.setupKitURL)) {
  fail('--setup-kit and --setup-kit-url must be supplied together')
}
if (Boolean(options.managedPreferences) !== Boolean(options.managedPreferencesURL)) {
  fail('--managed-preferences and --managed-preferences-url must be supplied together')
}

const requireURL = (value, label, allowSameOrigin = false) => {
  if (allowSameOrigin && value.startsWith('/') && !value.startsWith('//')) return value
  let parsed
  try { parsed = new URL(value) } catch { fail(`${label} is not a URL`) }
  if (parsed.protocol !== 'https:') fail(`${label} must use HTTPS`)
  return parsed.toString()
}
options.networkJSONURL = requireURL(options.networkJSONURL, 'network JSON URL', true)
options.networkCSVURL = requireURL(options.networkCSVURL, 'network CSV URL', true)
options.supportURL = requireURL(options.supportURL, 'support URL', true)
if (options.setupKitURL) options.setupKitURL = requireURL(options.setupKitURL, 'setup kit URL', true)
if (options.managedPreferencesURL) {
  options.managedPreferencesURL = requireURL(
    options.managedPreferencesURL, 'managed preferences URL', true
  )
}

let release
try { release = JSON.parse(readFileSync(options.releaseManifest, 'utf8')) } catch (error) {
  fail(`could not read release manifest: ${error.message}`)
}
if (release.schemaVersion !== 1 || release.product !== 'Mechanician') {
  fail('release manifest is not Mechanician schema version 1')
}
if (release.app?.bundleIdentifier !== 'ai.mechanician.app'
  || release.app?.teamIdentifier !== '5YPG2C4S34'
  || !Array.isArray(release.app?.architectures)
  || release.app.architectures.length !== 1
  || release.app.architectures[0] !== 'arm64') {
  fail('release manifest does not describe the supported standard Apple-silicon app')
}
for (const required of ['dmg', 'pkg', 'provenance', 'sbom']) {
  if (!release.artifacts?.[required]) fail(`release manifest is missing ${required}`)
}

const verifier = resolve(dirname(fileURLToPath(import.meta.url)), 'verify-enterprise-profile.swift')
const verification = spawnSync(verifier, [options.signedProfile], { encoding: 'utf8' })
if (verification.status !== 0) fail((verification.stderr || 'signed profile verification failed').trim())
let signedEnvelope
try { signedEnvelope = JSON.parse(readFileSync(options.signedProfile, 'utf8')) } catch (error) {
  fail(`could not read signed profile: ${error.message}`)
}
const revision = signedEnvelope.profile?.update?.revision
if (!Number.isSafeInteger(revision) || revision < 1) fail('signed profile needs a positive revision')
const declaredUpdateMode = signedEnvelope.profile?.update?.profileUpdateMode ?? 'automatic'
if (!['manual', 'automatic'].includes(declaredUpdateMode)) fail('signed profile update mode is invalid')

const artifactFromFile = (path, url) => {
  const facts = statSync(path)
  if (!facts.isFile() || facts.size < 1) fail(`artifact must be a non-empty regular file: ${path}`)
  return {
    url,
    bytes: facts.size,
    sha256: createHash('sha256').update(readFileSync(path)).digest('hex'),
  }
}
const copyReleaseArtifact = (kind) => {
  const artifact = release.artifacts[kind]
  requireURL(artifact.url, `${kind} URL`)
  if (!Number.isSafeInteger(artifact.bytes) || artifact.bytes < 1
    || !/^[a-f0-9]{64}$/.test(artifact.sha256 ?? '')) {
    fail(`release ${kind} artifact facts are invalid`)
  }
  return { url: artifact.url, bytes: artifact.bytes, sha256: artifact.sha256 }
}

const artifacts = {
  dmg: copyReleaseArtifact('dmg'),
  pkg: copyReleaseArtifact('pkg'),
  sbom: copyReleaseArtifact('sbom'),
  provenance: copyReleaseArtifact('provenance'),
}
if (options.setupKit) {
  artifacts.setupKit = artifactFromFile(options.setupKit, options.setupKitURL)
}
if (options.managedPreferences) {
  artifacts.managedPreferences = artifactFromFile(
    options.managedPreferences, options.managedPreferencesURL
  )
}

const deployment = {
  schemaVersion: 1,
  distributionMode: options.distributionMode,
  app: {
    version: release.app.version,
    build: release.app.build,
    bundleIdentifier: release.app.bundleIdentifier,
    teamIdentifier: release.app.teamIdentifier,
    minimumMacOS: release.app.minimumMacOS,
    architecture: 'arm64',
  },
  artifacts,
  configuration: {
    revision,
    sha256: createHash('sha256').update(readFileSync(options.signedProfile)).digest('hex'),
    updateMode: options.distributionMode === 'manual' ? declaredUpdateMode : 'mdm',
  },
  networkManifest: {
    jsonURL: options.networkJSONURL,
    csvURL: options.networkCSVURL,
  },
  supportURL: options.supportURL,
}

writeFileSync(options.output, `${JSON.stringify(deployment, null, 2)}\n`, { mode: 0o644 })
process.stdout.write(`==> wrote enterprise deployment manifest: ${options.output}\n`)

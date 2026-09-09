#!/usr/bin/env node

import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFileSync, statSync, writeFileSync } from 'node:fs'
import { basename } from 'node:path'

function fail(message) {
  process.stderr.write(`!! ${message}\n`)
  process.exit(1)
}

const args = process.argv.slice(2)
const options = { artifacts: [] }
for (let index = 0; index < args.length; index += 1) {
  const flag = args[index]
  const value = args[index + 1]
  if (!value) fail(`${flag} requires a value`)
  if (flag === '--artifact') options.artifacts.push(value)
  else if (flag === '--app') options.app = value
  else if (flag === '--base-url') options.baseURL = value
  else if (flag === '--output') options.output = value
  else fail(`unknown argument: ${flag}`)
  index += 1
}

if (!options.app || !options.baseURL || !options.output || options.artifacts.length === 0) {
  fail('usage: generate-release-manifest.mjs --app APP --base-url URL --output FILE --artifact kind=FILE [...]')
}

let baseURL
try {
  baseURL = new URL(options.baseURL.endsWith('/') ? options.baseURL : `${options.baseURL}/`)
} catch {
  fail('base URL is invalid')
}
if (baseURL.protocol !== 'https:') fail('base URL must use HTTPS')

const info = `${options.app}/Contents/Info.plist`
const plist = (key) => execFileSync(
  '/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, info], { encoding: 'utf8' }
).trim()

const executableName = plist('CFBundleExecutable')
if (plist('CFBundleIdentifier') !== 'ai.mechanician.app') {
  fail('release manifest requires the standard ai.mechanician.app identity')
}
const executable = `${options.app}/Contents/MacOS/${executableName}`
let architectures
try {
  architectures = execFileSync('/usr/bin/lipo', ['-archs', executable], { encoding: 'utf8' })
    .trim().split(/\s+/).filter(Boolean)
} catch {
  fail('could not read the app executable architectures')
}

let teamIdentifier = process.env.MECHANICIAN_MANIFEST_TEAM_ID?.trim()
if (!teamIdentifier) {
  const result = spawnSync(
    '/usr/bin/codesign', ['-d', '--verbose=4', options.app],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
  )
  const detail = `${result.stdout ?? ''}\n${result.stderr ?? ''}`
  const match = detail.match(/^TeamIdentifier=(.+)$/m)
  teamIdentifier = match?.[1]?.trim()
}
if (!teamIdentifier || teamIdentifier === 'not set') {
  fail('signed app has no TeamIdentifier; set MECHANICIAN_MANIFEST_TEAM_ID only for a local fixture')
}
const expectedTeamIdentifier = process.env.MECHANICIAN_SIGNING_TEAM_ID?.trim() || '5YPG2C4S34'
if (teamIdentifier !== expectedTeamIdentifier) {
  fail(`app TeamIdentifier ${teamIdentifier} does not match ${expectedTeamIdentifier}`)
}

const artifacts = {}
for (const specification of options.artifacts) {
  const separator = specification.indexOf('=')
  if (separator <= 0 || separator === specification.length - 1) {
    fail(`artifact must use kind=FILE: ${specification}`)
  }
  const kind = specification.slice(0, separator)
  const path = specification.slice(separator + 1)
  if (!/^[a-z][a-zA-Z0-9]*$/.test(kind)) fail(`invalid artifact kind: ${kind}`)
  if (artifacts[kind]) fail(`duplicate artifact kind: ${kind}`)
  const fileName = basename(path)
  const facts = statSync(path)
  if (!facts.isFile() || facts.size < 1) fail(`artifact must be a non-empty regular file: ${path}`)
  const bytes = facts.size
  const sha256 = createHash('sha256').update(readFileSync(path)).digest('hex')
  artifacts[kind] = {
    fileName,
    url: new URL(encodeURIComponent(fileName), baseURL).toString(),
    bytes,
    sha256,
  }
}

const manifest = {
  schemaVersion: 1,
  product: 'Mechanician',
  app: {
    version: plist('CFBundleShortVersionString'),
    build: plist('CFBundleVersion'),
    bundleIdentifier: plist('CFBundleIdentifier'),
    teamIdentifier,
    minimumMacOS: plist('LSMinimumSystemVersion'),
    architectures,
  },
  artifacts,
}

writeFileSync(options.output, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 })
process.stdout.write(`==> wrote release manifest: ${options.output}\n`)

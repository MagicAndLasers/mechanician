#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
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
  if (flag === '--config') options.config = value
  else if (flag === '--signed-profile') options.signedProfile = value
  else if (flag === '--output') options.output = value
  else fail(`unknown argument: ${flag}`)
}
if (!options.config || !options.output) {
  fail('usage: generate-managed-preferences-profile.mjs --config CONFIG.json [--signed-profile FILE] --output PROFILE.mobileconfig')
}

let config
try {
  config = JSON.parse(readFileSync(options.config, 'utf8'))
} catch (error) {
  fail(`could not read deployment configuration: ${error.message}`)
}

const exactKeys = (object, expected, label) => {
  if (!object || typeof object !== 'object' || Array.isArray(object)) fail(`${label} must be an object`)
  const unknown = Object.keys(object).find((key) => !expected.includes(key))
  if (unknown) fail(`${label} contains unknown key: ${unknown}`)
}
exactKeys(config, [
  'schemaVersion', 'bundleIdentifier', 'payloadIdentifier', 'payloadUUID',
  'managedPreferencesIdentifier', 'managedPreferencesUUID', 'displayName', 'organization',
  'removalDisallowed', 'managedConfiguration',
], 'deployment configuration')
if (config.schemaVersion !== 1) fail('deployment configuration schemaVersion must be 1')
if (config.bundleIdentifier !== 'ai.mechanician.app') {
  fail('this release supports managed preferences only for ai.mechanician.app')
}

const requireText = (value, label) => {
  if (typeof value !== 'string' || value.trim() === '' || /[\u0000-\u001f\u007f]/.test(value)) {
    fail(`${label} must be non-empty text without control characters`)
  }
  return value
}
const uuidPattern = /^[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/i
for (const [field, label] of [
  ['payloadIdentifier', 'payload identifier'],
  ['managedPreferencesIdentifier', 'managed preferences identifier'],
  ['displayName', 'display name'],
  ['organization', 'organization'],
]) requireText(config[field], label)
for (const field of ['payloadUUID', 'managedPreferencesUUID']) {
  if (!uuidPattern.test(config[field] ?? '')) fail(`${field} must be an RFC 4122 UUID`)
}
if (typeof config.removalDisallowed !== 'boolean') fail('removalDisallowed must be a Boolean')
exactKeys(config.managedConfiguration, [
  'schemaVersion', 'policyIdentifier', 'revision', 'policy',
], 'managedConfiguration')
if (config.managedConfiguration.schemaVersion !== 1) {
  fail('managedConfiguration.schemaVersion must be 1')
}

const managed = config.managedConfiguration
if (managed.policyIdentifier !== undefined) {
  const identifier = requireText(managed.policyIdentifier, 'managedConfiguration.policyIdentifier')
  if (identifier.length > 128) fail('managedConfiguration.policyIdentifier is too long')
}
if (managed.revision !== undefined
    && (!Number.isSafeInteger(managed.revision) || managed.revision < 1)) {
  fail('managedConfiguration.revision must be a positive integer')
}
if (managed.policy !== undefined) {
  exactKeys(managed.policy, [
    'allowedProviderAccesses',
    'maximumInteractivePermissionMode',
    'allowUnattendedTasks',
    'allowLocalProfile',
    'allowLocalConfigurationOverrides',
    'allowUserConfiguredExtensions',
    'allowPublicExtensionDiscovery',
    'updateAuthority',
    'sparkleUpdateChannel',
    'sparkleAutomaticChecks',
    'minimumAppBuild',
  ], 'managedConfiguration.policy')

  const policy = managed.policy
  if (policy.allowedProviderAccesses !== undefined) {
    if (!Array.isArray(policy.allowedProviderAccesses)
        || policy.allowedProviderAccesses.length === 0) {
      fail('managedConfiguration.policy.allowedProviderAccesses must be a non-empty array')
    }
    const lanePattern = /^[A-Za-z0-9._-]{1,128}$/
    if (policy.allowedProviderAccesses.some(
      (lane) => typeof lane !== 'string' || !lanePattern.test(lane.trim()))) {
      fail('managedConfiguration.policy.allowedProviderAccesses contains an invalid lane')
    }
  }
  if (policy.maximumInteractivePermissionMode !== undefined
      && !['plan', 'default', 'acceptEdits', 'bypassPermissions']
        .includes(policy.maximumInteractivePermissionMode)) {
    fail('managedConfiguration.policy.maximumInteractivePermissionMode is invalid')
  }
  for (const key of [
    'allowUnattendedTasks',
    'allowLocalProfile',
    'allowLocalConfigurationOverrides',
    'allowUserConfiguredExtensions',
    'allowPublicExtensionDiscovery',
    'sparkleAutomaticChecks',
  ]) {
    if (policy[key] !== undefined && typeof policy[key] !== 'boolean') {
      fail(`managedConfiguration.policy.${key} must be a Boolean`)
    }
  }
  if (policy.updateAuthority !== undefined
      && !['sparkle', 'mdm'].includes(policy.updateAuthority)) {
    fail('managedConfiguration.policy.updateAuthority is invalid')
  }
  if (policy.sparkleUpdateChannel !== undefined
      && !['stable', 'daily'].includes(policy.sparkleUpdateChannel)) {
    fail('managedConfiguration.policy.sparkleUpdateChannel is invalid')
  }
  if (policy.minimumAppBuild !== undefined
      && (!Number.isSafeInteger(policy.minimumAppBuild) || policy.minimumAppBuild < 1)) {
    fail('managedConfiguration.policy.minimumAppBuild must be a positive integer')
  }
  if (policy.updateAuthority === 'mdm'
      && (policy.sparkleUpdateChannel !== undefined
        || policy.sparkleAutomaticChecks !== undefined)) {
    fail('MDM update authority cannot include Sparkle settings')
  }
}

const forbiddenKey = /(password|secret|token|cookie|authorization|api.?key|private.?key)/i
const inspectForSecrets = (value, path = 'managedConfiguration') => {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => inspectForSecrets(entry, `${path}[${index}]`))
  } else if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      if (forbiddenKey.test(key)) fail(`${path}.${key} looks like a credential field`)
      inspectForSecrets(child, `${path}.${key}`)
    }
  }
}
inspectForSecrets(config.managedConfiguration)

const managedConfiguration = structuredClone(config.managedConfiguration)
if (options.signedProfile) {
  const verifier = resolve(dirname(fileURLToPath(import.meta.url)), 'verify-enterprise-profile.swift')
  const verification = spawnSync(verifier, [options.signedProfile], { encoding: 'utf8' })
  if (verification.status !== 0) fail((verification.stderr || 'signed profile verification failed').trim())
  managedConfiguration.signedProfile = readFileSync(options.signedProfile)
}

const payload = {
  PayloadContent: [{
    PayloadContent: {
      [config.bundleIdentifier]: {
        Forced: [{
          mcx_preference_settings: {
            MechanicianManagedConfiguration: managedConfiguration,
          },
        }],
      },
    },
    PayloadDisplayName: `${config.displayName} Managed Preferences`,
    PayloadIdentifier: config.managedPreferencesIdentifier,
    PayloadType: 'com.apple.ManagedClient.preferences',
    PayloadUUID: config.managedPreferencesUUID.toUpperCase(),
    PayloadVersion: 1,
  }],
  PayloadDescription: `Applies forced enterprise policy to ${config.displayName}.`,
  PayloadDisplayName: config.displayName,
  PayloadIdentifier: config.payloadIdentifier,
  PayloadOrganization: config.organization,
  PayloadRemovalDisallowed: config.removalDisallowed,
  PayloadScope: 'System',
  PayloadType: 'Configuration',
  PayloadUUID: config.payloadUUID.toUpperCase(),
  PayloadVersion: 1,
}

const escapeXML = (value) => value
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&apos;')

const plistValue = (value, indent = '  ') => {
  if (Buffer.isBuffer(value)) {
    const data = value.toString('base64').match(/.{1,68}/g) ?? []
    return `<data>\n${data.map((line) => `${indent}  ${line}`).join('\n')}\n${indent}</data>`
  }
  if (typeof value === 'string') return `<string>${escapeXML(value)}</string>`
  if (typeof value === 'boolean') return value ? '<true/>' : '<false/>'
  if (Number.isSafeInteger(value)) return `<integer>${value}</integer>`
  if (Array.isArray(value)) {
    if (value.length === 0) return '<array/>'
    return `<array>\n${value.map((entry) => `${indent}${plistValue(entry, `${indent}  `)}`).join('\n')}\n${indent.slice(2)}</array>`
  }
  if (value && typeof value === 'object') {
    const entries = Object.keys(value).sort().map((key) => (
      `${indent}<key>${escapeXML(key)}</key>\n${indent}${plistValue(value[key], `${indent}  `)}`
    ))
    return `<dict>\n${entries.join('\n')}\n${indent.slice(2)}</dict>`
  }
  fail(`unsupported property-list value: ${String(value)}`)
}

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
${plistValue(payload)}
</plist>
`
writeFileSync(options.output, xml, { mode: 0o644 })

const lint = spawnSync('/usr/bin/plutil', ['-lint', options.output], { encoding: 'utf8' })
if (lint.status !== 0) fail((lint.stdout || lint.stderr || 'plutil rejected output').trim())
process.stdout.write(`==> wrote managed preferences profile: ${options.output}\n`)

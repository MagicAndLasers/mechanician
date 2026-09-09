#!/usr/bin/env node
// Narrow command-line boundary used by the native app. Sensitive source bytes live in a private
// temporary file and never cross argv/stdout; stdout contains only the bounded export report.
import fs from 'node:fs'

import {
  MAX_RECORD_BYTES,
  PROFILE_LOCAL_FULL,
  PROFILE_SHARE_SNAPSHOT,
  writeExperimentalConversationRecord,
} from './experimental-binding.mjs'

function argumentsByName(argv) {
  const result = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!key?.startsWith('--') || value == null) throw new Error('invalid exporter arguments')
    result.set(key.slice(2), value)
  }
  return result
}

try {
  const args = argumentsByName(process.argv.slice(2))
  const source = args.get('source')
  const destination = args.get('destination')
  const profile = args.get('profile')
  if (!source || !destination) throw new Error('source and destination are required')
  if (![PROFILE_LOCAL_FULL, PROFILE_SHARE_SNAPSHOT].includes(profile)) {
    throw new Error('profile is required and must be recognized')
  }
  if (fs.statSync(source).size > MAX_RECORD_BYTES) {
    throw new Error(`source exceeds the ${MAX_RECORD_BYTES}-byte experimental limit`)
  }
  const sidecar = JSON.parse(fs.readFileSync(source, 'utf8'))
  const report = writeExperimentalConversationRecord({
    sidecar,
    profile,
    producer: {
      version: args.get('producer-version') ?? null,
      build: args.get('producer-build') ?? null,
      sourceRevision: args.get('producer-source') ?? null,
    },
  }, destination)
  process.stdout.write(`${JSON.stringify(report)}\n`)
} catch (error) {
  process.stderr.write(`Conversation Record export failed: ${error?.message ?? String(error)}\n`)
  process.exitCode = 1
}

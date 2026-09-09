#!/usr/bin/env node
// Generate the provider-fact constants both languages read, from shared/provider-facts.json.
//
//   node scripts/generate-provider-facts.mjs           # rewrite the generated files
//   node scripts/generate-provider-facts.mjs --check   # fail if they are out of date (used by CI)
//
// Why this exists: these lists were hand-mirrored in JavaScript and Swift, with comments instructing
// the reader to keep them identical. One pair drifted anyway, and the drift opened the daemon's own
// "last gate before the wire" on two routes. A comment is not a mechanism.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..')
const SOURCE_REL = 'shared/provider-facts.json'
const JS_REL = 'agentd/src/generated/provider-facts.mjs'
const SWIFT_REL = 'app/Sources/Mechanician/Generated/ProviderFacts.swift'

const source = JSON.parse(readFileSync(join(REPO, SOURCE_REL), 'utf8'))
const facts = source.facts

/// Order is not cosmetic here: a generator whose output depends on object iteration order produces a
/// spurious diff the first time someone reorders the source, and the check stage would then fail for
/// a change that altered nothing.
const names = Object.keys(facts).sort()

function validate() {
  const problems = []
  for (const name of names) {
    const fact = facts[name]
    if (!Array.isArray(fact?.values)) { problems.push(`${name}: missing values array`); continue }
    if (!fact.values.every((v) => typeof v === 'string' && v.length > 0)) {
      problems.push(`${name}: values must be non-empty strings`)
    }
    if (new Set(fact.values).size !== fact.values.length) problems.push(`${name}: duplicate values`)
    if (!Array.isArray(fact.why) || fact.why.length === 0) problems.push(`${name}: missing why`)
  }
  // The one cross-fact invariant worth enforcing at generation time rather than discovering at
  // runtime: a model cannot get 1M on a third-party route unless it gets 1M at all.
  const native = new Set(facts.nativeMillionTokenModels?.values ?? [])
  for (const model of facts.thirdPartyMillionTokenModels?.values ?? []) {
    if (!native.has(model)) {
      problems.push(`thirdPartyMillionTokenModels: ${model} is not in nativeMillionTokenModels`)
    }
  }
  // Prefix stripping is longest-first, so a shorter prefix of a longer one must come after it or the
  // longer one is unreachable and a Bedrock inference profile canonicalizes to the wrong name.
  const prefixes = facts.thirdPartyModelIDPrefixes?.values ?? []
  for (let i = 0; i < prefixes.length; i += 1) {
    for (let j = i + 1; j < prefixes.length; j += 1) {
      if (prefixes[i].startsWith(prefixes[j])) continue
      if (prefixes[j].startsWith(prefixes[i])) {
        problems.push(
          `thirdPartyModelIDPrefixes: "${prefixes[i]}" precedes and shadows "${prefixes[j]}"`)
      }
    }
  }
  if (problems.length) {
    console.error('!! shared/provider-facts.json is invalid:')
    for (const problem of problems) console.error(`   ${problem}`)
    process.exit(1)
  }
}

const BANNER = [
  'GENERATED FILE — DO NOT EDIT.',
  '',
  `Source:    ${SOURCE_REL}`,
  'Regenerate: node scripts/generate-provider-facts.mjs',
  '',
  'Edit the source and regenerate. scripts/check.sh fails when this file does not match the',
  'source, so the daemon and the app cannot disagree about a provider fact without the build',
  'saying so. That is the whole point: these lists used to be kept identical by hand, and one',
  'pair drifted.',
]

function jsComment(lines, indent = '') {
  return lines.map((line) => (line ? `${indent}// ${line}` : `${indent}//`)).join('\n')
}

function swiftComment(lines, indent = '') {
  return lines.map((line) => (line ? `${indent}/// ${line}` : `${indent}///`)).join('\n')
}

function camel(name) { return name }
function pascal(name) { return name.charAt(0).toUpperCase() + name.slice(1) }

function renderJS() {
  const blocks = names.map((name) => {
    const fact = facts[name]
    // A Set for membership facts, an ordered array where order is load-bearing.
    const ordered = name === 'thirdPartyModelIDPrefixes'
    const literal = fact.values.map((v) => `  ${JSON.stringify(v)},`).join('\n')
    const body = ordered
      ? `export const ${camel(name)} = Object.freeze([\n${literal}\n])`
      : `export const ${camel(name)} = new Set([\n${literal}\n])`
    return `${jsComment(fact.why)}\n${body}`
  })
  return `${jsComment(BANNER)}\n\n${blocks.join('\n\n')}\n`
}

function renderSwift() {
  const blocks = names.map((name) => {
    const fact = facts[name]
    const ordered = name === 'thirdPartyModelIDPrefixes'
    const literal = fact.values.map((v) => `        ${JSON.stringify(v)},`).join('\n')
    const type = ordered ? '[String]' : 'Set<String>'
    const open = ordered ? '[' : '['
    return `${swiftComment(fact.why, '    ')}\n`
      + `    static let ${camel(name)}: ${type} = ${open}\n${literal}\n    ]`
  })
  return `${swiftComment(BANNER)}\n\n`
    + 'enum ProviderFacts {\n'
    + `${blocks.join('\n\n')}\n`
    + '}\n'
}

function writeOrCheck(relative, contents, check) {
  const path = join(REPO, relative)
  let existing = null
  try { existing = readFileSync(path, 'utf8') } catch { existing = null }
  if (existing === contents) return true
  if (check) {
    console.error(`!! ${relative} is out of date with ${SOURCE_REL}`)
    console.error('   run: node scripts/generate-provider-facts.mjs')
    return false
  }
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, contents)
  console.log(`==> wrote ${relative}`)
  return true
}

validate()
const check = process.argv.includes('--check')
const ok = [
  writeOrCheck(JS_REL, renderJS(), check),
  writeOrCheck(SWIFT_REL, renderSwift(), check),
].every(Boolean)
if (!ok) process.exit(1)
if (check) console.log('==> provider facts are current')

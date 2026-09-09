#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { execFileSync } from 'node:child_process'
import { DatabaseSync } from 'node:sqlite'
import { fileURLToPath, pathToFileURL } from 'node:url'

export const HELP_APPLICATION_ID = 0x4D484C50 // MHLP
export const HELP_SCHEMA_VERSION = 4

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const DEFAULT_REPO = path.resolve(SCRIPT_DIR, '..')
const DEFAULT_SOURCE = path.join(DEFAULT_REPO, 'help', 'corpus.json')
const ID_PATTERN = /^[a-z0-9][a-z0-9.-]{0,95}$/
const TENANT_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/
const SHA256_PATTERN = /^[a-f0-9]{64}$/
const LIFECYCLES = new Set(['current', 'historical'])
const ARTICLE_KINDS = new Set([
  'howTo', 'architecture', 'extensionPoint', 'troubleshooting', 'history',
])
const EVIDENCE_KINDS = new Set(['source', 'test', 'architecture', 'canonicalDoc', 'release', 'history'])
const DEMO_SESSIONS = new Set(['interactive'])
const DEMO_MODES = new Set(['readOnlyOkay', 'planCompatibleAction', 'executionEnabled'])
const DEMO_RISKS = new Set([
  'readOnly', 'sensitiveRead', 'reversibleLocal', 'additive', 'destructive', 'dynamic',
])
const DEMO_REVERSIBILITY = new Set([
  'notNeeded', 'automatic', 'manual', 'notGuaranteed', 'dynamic',
])
const DEMO_CONFIRMATIONS = new Set(['none', 'beforeDemo', 'beforeAct'])
const DEMO_STEP_KINDS = new Set(['observe', 'ask', 'act', 'explain'])
const DEMO_VERIFICATION_KINDS = new Set(['toolSucceeded', 'visualState', 'userObserved'])
const DEMO_FALLBACK_WHEN = new Set([
  'toolUnavailable', 'emptyResult', 'permissionDenied', 'actionFailed', 'verificationFailed',
])
const DEMO_FALLBACK_ACTIONS = new Set(['explain', 'useDemo'])
const GUIDE_SURFACES = new Set([
  'helpWorkspaceInspector',
  'conversationWorkspace',
])
const GUIDE_TARGETS = new Set([
  'helpInspectorTab',
  'helpTopics',
  'helpSearchField',
  'helpArticleContent',
  'helpArticleEvidence',
  'helpDemonstrations',
  'conversationFilesTab',
  'conversationChangesTab',
  'conversationArtifactsTab',
  'conversationAgentsTab',
  'conversationSkillsTab',
  'conversationModelControl',
  'conversationEffortControl',
  'conversationPermissionControl',
  'conversationComposer',
])
const GUIDE_REVEAL_ACTIONS = new Set([
  'none',
  'showHelpInspector',
  'showHelpTopics',
  'showGuideArticle',
  'showGuideEvidence',
  'showGuideDemonstrations',
  'showFilesInspector',
  'showChangesInspector',
  'showArtifactsInspector',
  'showAgentsInspector',
  'showSkillsInspector',
  'showConversationControls',
])
const GUIDE_COMPLETIONS = new Set([
  'targetVisible',
  'targetActivated',
  'textEntered',
  'userAdvance',
])
const GUIDE_REVEAL_TARGETS = new Map([
  ['showHelpInspector', new Set(['helpInspectorTab'])],
  ['showHelpTopics', new Set(['helpTopics', 'helpSearchField'])],
  ['showGuideArticle', new Set(['helpArticleContent'])],
  ['showGuideEvidence', new Set(['helpArticleEvidence'])],
  ['showGuideDemonstrations', new Set(['helpDemonstrations'])],
  ['showFilesInspector', new Set(['conversationFilesTab'])],
  ['showChangesInspector', new Set(['conversationChangesTab'])],
  ['showArtifactsInspector', new Set(['conversationArtifactsTab'])],
  ['showAgentsInspector', new Set(['conversationAgentsTab'])],
  ['showSkillsInspector', new Set(['conversationSkillsTab'])],
  ['showConversationControls', new Set([
    'conversationModelControl', 'conversationEffortControl',
    'conversationPermissionControl', 'conversationComposer',
  ])],
])
const GUIDE_SURFACE_TARGETS = new Map([
  ['helpWorkspaceInspector', new Set([
    'helpInspectorTab', 'helpTopics', 'helpSearchField', 'helpArticleContent',
    'helpArticleEvidence', 'helpDemonstrations',
  ])],
  ['conversationWorkspace', new Set([
    'conversationFilesTab', 'conversationChangesTab', 'conversationArtifactsTab',
    'conversationAgentsTab', 'conversationSkillsTab', 'conversationModelControl',
    'conversationEffortControl', 'conversationPermissionControl', 'conversationComposer',
  ])],
])
const GUIDE_SURFACE_REVEAL_ACTIONS = new Map([
  ['helpWorkspaceInspector', new Set([
    'none', 'showHelpInspector', 'showHelpTopics', 'showGuideArticle',
    'showGuideEvidence', 'showGuideDemonstrations',
  ])],
  ['conversationWorkspace', new Set([
    'none', 'showFilesInspector', 'showChangesInspector', 'showArtifactsInspector',
    'showAgentsInspector', 'showSkillsInspector', 'showConversationControls',
  ])],
])
const TOOL_NAME_PATTERN = /^[A-Za-z][A-Za-z0-9]{0,119}$/
// Tool names alone are not a safety contract. Keep the step kind and the one recipe-level effect
// class beside every admitted name so an action cannot be disguised as read-only observation.
const DEMO_TOOL_POLICIES = new Map([
  ['CreateOrUpdateArtifact', { stepKind: 'act', effect: 'inAppAdditive' }],
  ['DiscoverAppActions', { stepKind: 'observe', effect: 'inventory' }],
  ['ListCapabilities', { stepKind: 'observe', effect: 'inventory' }],
  ['ListShortcuts', { stepKind: 'observe', effect: 'inventory' }],
  ['RunCapability', { stepKind: 'act', effect: 'externalDynamic' }],
])
const DEMO_TOOLS = new Set(DEMO_TOOL_POLICIES.keys())

function fail(message) {
  throw new Error(`Mechanician Help corpus: ${message}`)
}

function assertObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`)
}

function assertKeys(value, allowed, required, label) {
  assertObject(value, label)
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) fail(`${label} has unknown field ${JSON.stringify(key)}`)
  }
  for (const key of required) {
    if (!(key in value)) fail(`${label} is missing ${JSON.stringify(key)}`)
  }
}

function assertString(value, label, { allowEmpty = false, max = 200_000 } = {}) {
  if (typeof value !== 'string') fail(`${label} must be a string`)
  if (!allowEmpty && value.trim() === '') fail(`${label} must not be empty`)
  if (value.length > max) fail(`${label} is larger than ${max} characters`)
  if (value.includes('\0')) fail(`${label} contains a NUL character`)
  if (value !== value.normalize('NFC')) fail(`${label} must be NFC-normalized`)
}

function assertID(value, label) {
  assertString(value, label, { max: 96 })
  if (!ID_PATTERN.test(value)) fail(`${label} must match ${ID_PATTERN}`)
}

function assertOrdinal(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`${label} must be a non-negative integer`)
}

function assertUnique(values, label) {
  const seen = new Set()
  for (const value of values) {
    if (seen.has(value)) fail(`duplicate ${label} ${JSON.stringify(value)}`)
    seen.add(value)
  }
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`
  if (value && typeof value === 'object') {
    const entries = Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`)
    return `{${entries.join(',')}}`
  }
  return JSON.stringify(value)
}

function assertBoundedArray(value, label, { min = 0, max }) {
  if (!Array.isArray(value)) fail(`${label} must be an array`)
  if (value.length < min || value.length > max) {
    fail(`${label} must contain between ${min} and ${max} items`)
  }
}

function assertVocabulary(value, vocabulary, label) {
  if (!vocabulary.has(value)) fail(`${label} is not supported: ${value}`)
}

function assertGuideCopy(value, label, { max }) {
  assertString(value, label, { max })
  const forbidden = [
    [/\b(?:css|xpath|accessibility)\s+selector\b|\[[a-z][\w-]*(?:[~|^$*]?=)[^\]]+\]|#[a-z][\w-]{2,}/iu, 'selector'],
    [/\b[a-z][\w-]*:(?:nth-(?:child|last-child|of-type|last-of-type)|first-child|last-child|only-child|only-of-type|not|has|is|where)\s*(?:\([^)]*\))?/iu, 'selector'],
    [/\bax(?:role|title|identifier|description|value)\s*(?:==?|~=|\^=|\$=|\*=)/iu, 'selector'],
    [/\b[a-z][a-z0-9+.-]{1,31}:\/\//iu, 'URL or URI'],
    [/\b[a-z][a-z0-9+.-]{1,31}:(?=[^\s])/iu, 'URL or URI'],
    [/\b(?:javascript|data|file):/iu, 'URL or URI'],
    [/\b(?:osascript|applescript|jxa|javascript|shell\s+script|bash|zsh)\b|#!/iu, 'script'],
    [/\b(?:python(?:\d+(?:\.\d+)?)?|ruby|perl|node|php|swift|sh|fish|pwsh|powershell|cmd(?:\.exe)?)\s+(?:-[a-z]|\/[a-z]|--(?:eval|execute)\b)/iu, 'script'],
    [/\b[xy]\s*[:=]\s*-?\d|\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)/iu, 'coordinate'],
    [/\b(?:click|tap|point(?:\s+at)?|position|coordinates?)\s+(?:at\s+)?-?\d+(?:\.\d+)?\s*[,/]\s*-?\d+(?:\.\d+)?\b/iu, 'coordinate'],
    [/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/iu, 'raw identifier'],
    [/\b(?:workspace|window|conversation)(?:\s+|[-_.])?(?:id|identifier)\b/iu, 'raw workspace, window, or conversation identifier'],
    [/\b(?:delete|remove|rename|move|create|edit|modify|write|send|submit|run|execute|install|uninstall|enable|disable|toggle|change)\s+(?:the|this|a|an|your|its|memory|workspace|conversation|window|page|setting|value|file|message|app|control)\b/iu, 'mutation'],
  ]
  for (const [pattern, kind] of forbidden) {
    if (pattern.test(value)) fail(`${label} must not encode a ${kind}`)
  }
}

function countOccurrences(haystack, needle) {
  let count = 0
  let offset = 0
  while (true) {
    const found = haystack.indexOf(needle, offset)
    if (found < 0) return count
    count += 1
    offset = found + Math.max(needle.length, 1)
  }
}

function safeEvidencePath(repoRoot, relativePath, label) {
  assertString(relativePath, `${label}.path`, { max: 500 })
  if (path.isAbsolute(relativePath) || relativePath.split(/[\\/]/).includes('..')) {
    fail(`${label}.path must stay inside the repository`)
  }
  const absolute = path.resolve(repoRoot, relativePath)
  const repoReal = fs.realpathSync(repoRoot)
  let cursor = repoReal
  for (const component of relativePath.split(/[\\/]/).filter(Boolean)) {
    cursor = path.join(cursor, component)
    let stat
    try {
      stat = fs.lstatSync(cursor)
    } catch (error) {
      fail(`${label}.path cannot be inspected: ${relativePath}: ${error.message}`)
    }
    if (stat.isSymbolicLink()) fail(`${label}.path must not contain symlinks: ${relativePath}`)
  }
  const stat = fs.lstatSync(absolute)
  if (!stat.isFile()) fail(`${label}.path must name a regular file: ${relativePath}`)
  const real = fs.realpathSync(absolute)
  if (real !== repoReal && !real.startsWith(`${repoReal}${path.sep}`)) {
    fail(`${label}.path escapes the repository`)
  }
  try {
    execFileSync('git', ['-C', repoRoot, 'ls-files', '--error-unmatch', '--', relativePath], {
      stdio: 'ignore',
    })
  } catch {
    fail(`${label}.path is not tracked: ${relativePath}`)
  }
  return { absolute, real }
}

function validateGuides(source, articles) {
  assertBoundedArray(source.guides, 'guides', { min: 1, max: 128 })
  const articleByID = new Map(articles.map(article => [article.id, article]))
  const articleOrder = new Map(articles.map((article, index) => [article.id, index]))
  const claimByKey = new Map(articles.flatMap(article => article.claims).map(claim => [claim.key, claim]))
  const normalized = source.guides.map((guide, guideIndex) => {
    const label = `guides[${guideIndex}]`
    assertKeys(guide,
      ['id', 'articleID', 'title', 'summary', 'surface', 'lifecycle', 'ordinal', 'claimKeys', 'steps'],
      ['id', 'articleID', 'title', 'summary', 'surface', 'lifecycle', 'ordinal', 'claimKeys', 'steps'],
      label)
    assertID(guide.id, `${label}.id`)
    assertID(guide.articleID, `${label}.articleID`)
    const article = articleByID.get(guide.articleID)
    if (!article) fail(`${label}.articleID references missing article ${guide.articleID}`)
    if (!guide.id.startsWith(`${guide.articleID}.`)) {
      fail(`${label}.id must be namespaced by ${guide.articleID}.`)
    }
    assertGuideCopy(guide.title, `${label}.title`, { max: 160 })
    assertGuideCopy(guide.summary, `${label}.summary`, { max: 600 })
    assertVocabulary(guide.surface, GUIDE_SURFACES, `${label}.surface`)
    assertVocabulary(guide.lifecycle, LIFECYCLES, `${label}.lifecycle`)
    assertOrdinal(guide.ordinal, `${label}.ordinal`)
    if (guide.lifecycle === 'current' && article.lifecycle !== 'current') {
      fail(`current guide ${guide.id} cannot belong to non-current article ${article.id}`)
    }

    assertBoundedArray(guide.claimKeys, `${label}.claimKeys`, { min: 1, max: 16 })
    for (const [claimIndex, claimKey] of guide.claimKeys.entries()) {
      assertID(claimKey, `${label}.claimKeys[${claimIndex}]`)
      const claim = claimByKey.get(claimKey)
      if (!claim) fail(`${label}.claimKeys references missing claim ${claimKey}`)
      if (guide.lifecycle === 'current' && claim.lifecycle !== 'current') {
        fail(`current guide ${guide.id} cannot rely on non-current claim ${claimKey}`)
      }
    }
    assertUnique(guide.claimKeys, `${guide.id} claim key`)

    assertBoundedArray(guide.steps, `${label}.steps`, { min: 1, max: 16 })
    const steps = guide.steps.map((step, stepIndex) => {
      const stepLabel = `${label}.steps[${stepIndex}]`
      assertKeys(step,
        ['id', 'title', 'instruction', 'target', 'revealAction', 'completion'],
        ['id', 'title', 'instruction', 'target', 'revealAction', 'completion'],
        stepLabel)
      assertID(step.id, `${stepLabel}.id`)
      assertGuideCopy(step.title, `${stepLabel}.title`, { max: 160 })
      assertGuideCopy(step.instruction, `${stepLabel}.instruction`, { max: 1_000 })
      assertVocabulary(step.target, GUIDE_TARGETS, `${stepLabel}.target`)
      assertVocabulary(step.revealAction, GUIDE_REVEAL_ACTIONS, `${stepLabel}.revealAction`)
      assertVocabulary(step.completion, GUIDE_COMPLETIONS, `${stepLabel}.completion`)
      if (!GUIDE_SURFACE_TARGETS.get(guide.surface)?.has(step.target)) {
        fail(`${stepLabel}.target cannot appear on surface ${guide.surface}`)
      }
      if (!GUIDE_SURFACE_REVEAL_ACTIONS.get(guide.surface)?.has(step.revealAction)) {
        fail(`${stepLabel}.revealAction cannot run on surface ${guide.surface}`)
      }
      if (step.revealAction !== 'none'
          && !GUIDE_REVEAL_TARGETS.get(step.revealAction)?.has(step.target)) {
        fail(`${stepLabel}.revealAction cannot reveal target ${step.target}`)
      }
      if (step.completion === 'textEntered' && step.target !== 'helpSearchField') {
        fail(`${stepLabel}.completion textEntered requires helpSearchField`)
      }
      return { ...step, ordinal: stepIndex }
    })
    assertUnique(steps.map(step => step.id), `${guide.id} step id`)
    return { ...guide, steps }
  })

  assertUnique(normalized.map(guide => guide.id), 'guide id')
  for (const article of articles) {
    assertUnique(
      normalized.filter(guide => guide.articleID === article.id).map(guide => guide.ordinal),
      `guide ordinal in article ${article.id}`)
  }
  return normalized.sort((a, b) => {
    return articleOrder.get(a.articleID) - articleOrder.get(b.articleID)
      || a.ordinal - b.ordinal
      || a.id.localeCompare(b.id)
  })
}

function validateDemonstrations(source, articles) {
  assertBoundedArray(source.demonstrations, 'demonstrations', { min: 1, max: 256 })
  const articleByID = new Map(articles.map(article => [article.id, article]))
  const articleOrder = new Map(articles.map((article, index) => [article.id, index]))
  const claimByKey = new Map(articles.flatMap(article => article.claims).map(claim => [claim.key, claim]))
  const normalized = source.demonstrations.map((demo, demoIndex) => {
    const label = `demonstrations[${demoIndex}]`
    assertKeys(demo,
      ['id', 'articleID', 'title', 'outcome', 'lifecycle', 'ordinal', 'claimKeys',
        'requirements', 'risk', 'reversibility', 'userConfirmation', 'steps',
        'verification', 'fallback'],
      ['id', 'articleID', 'title', 'outcome', 'lifecycle', 'ordinal', 'claimKeys',
        'requirements', 'risk', 'reversibility', 'userConfirmation', 'steps',
        'verification', 'fallback'], label)
    assertID(demo.id, `${label}.id`)
    assertID(demo.articleID, `${label}.articleID`)
    const article = articleByID.get(demo.articleID)
    if (!article) fail(`${label}.articleID references missing article ${demo.articleID}`)
    if (!demo.id.startsWith(`${demo.articleID}.`)) {
      fail(`${label}.id must be namespaced by ${demo.articleID}.`)
    }
    assertString(demo.title, `${label}.title`, { max: 160 })
    assertString(demo.outcome, `${label}.outcome`, { max: 600 })
    assertVocabulary(demo.lifecycle, LIFECYCLES, `${label}.lifecycle`)
    assertOrdinal(demo.ordinal, `${label}.ordinal`)

    assertBoundedArray(demo.claimKeys, `${label}.claimKeys`, { min: 1, max: 16 })
    for (const [claimIndex, claimKey] of demo.claimKeys.entries()) {
      assertID(claimKey, `${label}.claimKeys[${claimIndex}]`)
      const claim = claimByKey.get(claimKey)
      if (!claim) fail(`${label}.claimKeys references missing claim ${claimKey}`)
      if (demo.lifecycle === 'current' && claim.lifecycle !== 'current') {
        fail(`current demonstration ${demo.id} cannot rely on non-current claim ${claimKey}`)
      }
    }
    assertUnique(demo.claimKeys, `${demo.id} claim key`)
    if (demo.lifecycle === 'current' && article.lifecycle !== 'current') {
      fail(`current demonstration ${demo.id} cannot belong to non-current article ${article.id}`)
    }

    assertKeys(demo.requirements,
      ['session', 'mode', 'tools'], ['session', 'mode', 'tools'], `${label}.requirements`)
    assertVocabulary(
      demo.requirements.session, DEMO_SESSIONS, `${label}.requirements.session`)
    assertVocabulary(demo.requirements.mode, DEMO_MODES, `${label}.requirements.mode`)
    assertBoundedArray(demo.requirements.tools, `${label}.requirements.tools`, { min: 1, max: 12 })
    for (const [toolIndex, tool] of demo.requirements.tools.entries()) {
      assertString(tool, `${label}.requirements.tools[${toolIndex}]`, { max: 120 })
      if (!TOOL_NAME_PATTERN.test(tool)) {
        fail(`${label}.requirements.tools[${toolIndex}] must be a canonical tool name`)
      }
      if (!DEMO_TOOLS.has(tool)) {
        fail(`${label}.requirements.tools[${toolIndex}] is not an approved demonstration tool`)
      }
    }
    assertUnique(demo.requirements.tools, `${demo.id} required tool`)

    assertVocabulary(demo.risk, DEMO_RISKS, `${label}.risk`)
    assertKeys(demo.reversibility,
      ['kind', 'instructions'], ['kind', 'instructions'], `${label}.reversibility`)
    assertVocabulary(
      demo.reversibility.kind, DEMO_REVERSIBILITY, `${label}.reversibility.kind`)
    assertString(demo.reversibility.instructions, `${label}.reversibility.instructions`, { max: 1_000 })
    assertVocabulary(demo.userConfirmation, DEMO_CONFIRMATIONS, `${label}.userConfirmation`)

    assertBoundedArray(demo.steps, `${label}.steps`, { min: 1, max: 16 })
    const steps = demo.steps.map((step, stepIndex) => {
      const stepLabel = `${label}.steps[${stepIndex}]`
      assertKeys(step,
        ['id', 'kind', 'tool', 'instruction'], ['id', 'kind', 'instruction'], stepLabel)
      assertID(step.id, `${stepLabel}.id`)
      assertVocabulary(step.kind, DEMO_STEP_KINDS, `${stepLabel}.kind`)
      assertString(step.instruction, `${stepLabel}.instruction`, { max: 2_000 })
      const usesTool = step.kind === 'observe' || step.kind === 'act'
      if (usesTool) {
        if (!Object.hasOwn(step, 'tool')) fail(`${stepLabel}.tool is required for ${step.kind}`)
        assertString(step.tool, `${stepLabel}.tool`, { max: 120 })
        if (!demo.requirements.tools.includes(step.tool)) {
          fail(`${stepLabel}.tool is missing from demonstration requirements`)
        }
        const policy = DEMO_TOOL_POLICIES.get(step.tool)
        if (!policy) fail(`${stepLabel}.tool is not an approved demonstration tool`)
        if (step.kind !== policy.stepKind) {
          fail(`${stepLabel}.tool ${step.tool} requires an ${policy.stepKind} step`)
        }
      } else if (Object.hasOwn(step, 'tool')) {
        fail(`${stepLabel}.tool is not allowed for ${step.kind}`)
      }
      return { ...step }
    })
    assertUnique(steps.map(step => step.id), `${demo.id} step id`)
    const usedTools = new Set(steps.flatMap(step => step.tool ? [step.tool] : []))
    for (const tool of demo.requirements.tools) {
      if (!usedTools.has(tool)) fail(`${label}.requirements includes unused tool ${tool}`)
    }
    const effectClasses = new Set(demo.requirements.tools.map(tool => {
      return DEMO_TOOL_POLICIES.get(tool).effect
    }).filter(effect => effect !== 'inventory'))
    if (effectClasses.size > 1) {
      fail(`${demo.id} mixes incompatible demonstration tool classes`)
    }
    const effect = effectClasses.values().next().value ?? 'inventory'
    const hasCanonicalToolContract = (() => {
      switch (effect) {
        case 'inventory':
          return demo.requirements.mode === 'readOnlyOkay'
            && demo.risk === 'readOnly'
            && demo.reversibility.kind === 'notNeeded'
            && demo.userConfirmation === 'none'
        case 'externalDynamic':
          return demo.requirements.mode === 'executionEnabled'
            && demo.risk === 'dynamic'
            && demo.reversibility.kind === 'dynamic'
            && demo.userConfirmation === 'beforeAct'
        case 'inAppAdditive':
          return demo.requirements.mode === 'planCompatibleAction'
            && demo.risk === 'additive'
            && demo.reversibility.kind === 'manual'
            && demo.userConfirmation === 'beforeDemo'
        default:
          return false
      }
    })()
    if (!hasCanonicalToolContract) {
      fail(`${demo.id} does not match its ${effect} demonstration tool contract`)
    }
    const hasAct = steps.some(step => step.kind === 'act')
    if (hasAct && demo.requirements.mode === 'readOnlyOkay') {
      fail(`${demo.id} contains an act step but is readOnlyOkay`)
    }
    if (!hasAct && demo.requirements.mode !== 'readOnlyOkay') {
      fail(`${demo.id} declares an action mode but contains no act step`)
    }
    if (hasAct && demo.userConfirmation === 'none') {
      fail(`${demo.id} contains an act step without user confirmation`)
    }
    if (demo.userConfirmation === 'beforeAct' && !hasAct) {
      fail(`${demo.id} requests beforeAct confirmation but contains no act step`)
    }
    if (demo.risk === 'readOnly') {
      if (hasAct || demo.reversibility.kind !== 'notNeeded' || demo.userConfirmation !== 'none') {
        fail(`${demo.id} has an inconsistent readOnly contract`)
      }
    }
    if (demo.risk === 'dynamic' && demo.reversibility.kind !== 'dynamic') {
      fail(`${demo.id} has dynamic risk without dynamic reversibility`)
    }
    if (demo.risk === 'reversibleLocal'
        && !['automatic', 'manual'].includes(demo.reversibility.kind)) {
      fail(`${demo.id} has reversibleLocal risk without an undo contract`)
    }
    if (demo.risk === 'destructive' && demo.reversibility.kind === 'notNeeded') {
      fail(`${demo.id} has destructive risk without a reversal warning`)
    }

    assertBoundedArray(demo.verification, `${label}.verification`, { min: 1, max: 8 })
    const stepByID = new Map(steps.map(step => [step.id, step]))
    const verification = demo.verification.map((item, verificationIndex) => {
      const verificationLabel = `${label}.verification[${verificationIndex}]`
      assertKeys(item,
        ['kind', 'stepID', 'instruction'],
        ['kind', 'stepID', 'instruction'], verificationLabel)
      assertVocabulary(item.kind, DEMO_VERIFICATION_KINDS, `${verificationLabel}.kind`)
      assertID(item.stepID, `${verificationLabel}.stepID`)
      const step = stepByID.get(item.stepID)
      if (!step) fail(`${verificationLabel}.stepID references missing step ${item.stepID}`)
      if (item.kind === 'toolSucceeded' && !step.tool) {
        fail(`${verificationLabel}.stepID must reference a tool step`)
      }
      assertString(item.instruction, `${verificationLabel}.instruction`, { max: 2_000 })
      return { ...item }
    })
    if (hasAct && !verification.some(item => stepByID.get(item.stepID)?.kind === 'act')) {
      fail(`${demo.id} has no post-action verification`)
    }

    assertBoundedArray(demo.fallback, `${label}.fallback`, { min: 1, max: 8 })
    const fallback = demo.fallback.map((item, fallbackIndex) => {
      const fallbackLabel = `${label}.fallback[${fallbackIndex}]`
      assertKeys(item,
        ['when', 'action', 'demoID', 'instruction'],
        ['when', 'action', 'instruction'], fallbackLabel)
      assertVocabulary(item.when, DEMO_FALLBACK_WHEN, `${fallbackLabel}.when`)
      assertVocabulary(item.action, DEMO_FALLBACK_ACTIONS, `${fallbackLabel}.action`)
      assertString(item.instruction, `${fallbackLabel}.instruction`, { max: 2_000 })
      if (item.action === 'useDemo') {
        if (!Object.hasOwn(item, 'demoID')) fail(`${fallbackLabel}.demoID is required for useDemo`)
        assertID(item.demoID, `${fallbackLabel}.demoID`)
      } else if (Object.hasOwn(item, 'demoID')) {
        fail(`${fallbackLabel}.demoID is only allowed for useDemo`)
      }
      return { ...item }
    })
    assertUnique(fallback.map(item => item.when), `${demo.id} fallback condition`)

    const recipe = {
      requirements: { ...demo.requirements, tools: [...demo.requirements.tools] },
      risk: demo.risk,
      reversibility: { ...demo.reversibility },
      userConfirmation: demo.userConfirmation,
      steps,
      verification,
      fallback,
    }
    return {
      ...demo,
      steps,
      verification,
      fallback,
      recipeJSON: canonicalJSON(recipe),
    }
  })

  assertUnique(normalized.map(demo => demo.id), 'demonstration id')
  const demoByID = new Map(normalized.map(demo => [demo.id, demo]))
  for (const demo of normalized) {
    for (const fallback of demo.fallback) {
      if (fallback.action !== 'useDemo') continue
      if (!demoByID.has(fallback.demoID)) {
        fail(`demonstration ${demo.id} fallback references missing demonstration ${fallback.demoID}`)
      }
      if (fallback.demoID === demo.id) fail(`demonstration ${demo.id} cannot fall back to itself`)
    }
  }
  for (const article of articles) {
    assertUnique(
      normalized.filter(demo => demo.articleID === article.id).map(demo => demo.ordinal),
      `demonstration ordinal in article ${article.id}`)
  }

  const visiting = new Set()
  const visited = new Set()
  function visit(demoID) {
    if (visiting.has(demoID)) fail(`demonstration fallback cycle includes ${demoID}`)
    if (visited.has(demoID)) return
    visiting.add(demoID)
    for (const fallback of demoByID.get(demoID).fallback) {
      if (fallback.action === 'useDemo') visit(fallback.demoID)
    }
    visiting.delete(demoID)
    visited.add(demoID)
  }
  for (const demo of normalized) visit(demo.id)

  return normalized.sort((a, b) => {
    return articleOrder.get(a.articleID) - articleOrder.get(b.articleID)
      || a.ordinal - b.ordinal
      || a.id.localeCompare(b.id)
  })
}

export function loadAndValidateCorpus({ sourcePath = DEFAULT_SOURCE, repoRoot = DEFAULT_REPO } = {}) {
  let source
  try {
    source = JSON.parse(fs.readFileSync(sourcePath, 'utf8'))
  } catch (error) {
    fail(`cannot parse ${path.relative(repoRoot, sourcePath)}: ${error.message}`)
  }
  assertKeys(source,
    ['schemaVersion', 'corpusID', 'sections', 'articles', 'demonstrations', 'guides'],
    ['schemaVersion', 'corpusID', 'sections', 'articles', 'demonstrations', 'guides'], 'root')
  if (source.schemaVersion !== HELP_SCHEMA_VERSION) {
    fail(`source schema is ${source.schemaVersion}; expected ${HELP_SCHEMA_VERSION}`)
  }
  assertID(source.corpusID, 'corpusID')
  if (!Array.isArray(source.sections) || !source.sections.length) fail('sections must be a non-empty array')
  if (!Array.isArray(source.articles) || !source.articles.length) fail('articles must be a non-empty array')

  for (const [index, section] of source.sections.entries()) {
    const label = `sections[${index}]`
    assertKeys(section, ['id', 'title', 'ordinal'], ['id', 'title', 'ordinal'], label)
    assertID(section.id, `${label}.id`)
    assertString(section.title, `${label}.title`, { max: 120 })
    assertOrdinal(section.ordinal, `${label}.ordinal`)
  }
  assertUnique(source.sections.map(section => section.id), 'section id')
  assertUnique(source.sections.map(section => section.ordinal), 'section ordinal')
  const sectionIDs = new Set(source.sections.map(section => section.id))

  const evidenceIDs = []
  const normalizedArticles = []
  for (const [index, article] of source.articles.entries()) {
    const label = `articles[${index}]`
    assertKeys(article,
      ['id', 'title', 'icon', 'blurb', 'section', 'kind', 'lifecycle',
        'ordinal', 'aliases', 'markdown', 'evidence', 'claims'],
      ['id', 'title', 'icon', 'blurb', 'section', 'kind', 'lifecycle',
        'ordinal', 'aliases', 'markdown', 'evidence', 'claims'], label)
    assertID(article.id, `${label}.id`)
    assertString(article.title, `${label}.title`, { max: 160 })
    assertString(article.icon, `${label}.icon`, { max: 120 })
    assertString(article.blurb, `${label}.blurb`, { max: 300 })
    assertID(article.section, `${label}.section`)
    if (!sectionIDs.has(article.section)) fail(`${label}.section names missing section ${article.section}`)
    if (!ARTICLE_KINDS.has(article.kind)) fail(`${label}.kind is not supported: ${article.kind}`)
    if (!LIFECYCLES.has(article.lifecycle)) {
      fail(`${label}.lifecycle is not authorable without lifecycle relations: ${article.lifecycle}`)
    }
    assertOrdinal(article.ordinal, `${label}.ordinal`)
    assertString(article.markdown, `${label}.markdown`)
    if (!Array.isArray(article.aliases)) fail(`${label}.aliases must be an array`)
    for (const [aliasIndex, alias] of article.aliases.entries()) {
      assertString(alias, `${label}.aliases[${aliasIndex}]`, { max: 120 })
    }
    assertUnique(article.aliases.map(alias => alias.toLocaleLowerCase('en-US')), `${article.id} alias`)
    if (!Array.isArray(article.evidence) || !article.evidence.length) {
      fail(`${label}.evidence must contain at least one source`)
    }

    const evidence = article.evidence.map((item, evidenceIndex) => {
      const evidenceLabel = `${label}.evidence[${evidenceIndex}]`
      assertKeys(item,
        ['id', 'kind', 'path', 'anchor', 'sourceSHA256'],
        ['id', 'kind', 'path', 'anchor', 'sourceSHA256'], evidenceLabel)
      assertID(item.id, `${evidenceLabel}.id`)
      evidenceIDs.push(item.id)
      if (!EVIDENCE_KINDS.has(item.kind)) fail(`${evidenceLabel}.kind is not supported: ${item.kind}`)
      assertString(item.anchor, `${evidenceLabel}.anchor`, { max: 2_000 })
      assertString(item.sourceSHA256, `${evidenceLabel}.sourceSHA256`, { max: 64 })
      if (!SHA256_PATTERN.test(item.sourceSHA256)) {
        fail(`${evidenceLabel}.sourceSHA256 must be SHA-256`)
      }
      const sourceFile = safeEvidencePath(repoRoot, item.path, evidenceLabel)
      const bytes = fs.readFileSync(sourceFile.absolute)
      const sourceSHA256 = sha256(bytes)
      if (item.sourceSHA256 !== sourceSHA256) {
        fail(`${evidenceLabel}.sourceSHA256 does not match ${item.path}; review the evidence before updating its digest`)
      }
      const text = bytes.toString('utf8')
      const matches = countOccurrences(text, item.anchor)
      if (matches !== 1) {
        fail(`${evidenceLabel}.anchor must occur exactly once in ${item.path}; found ${matches}`)
      }
      return {
        ...item,
        anchorSHA256: sha256(item.anchor),
      }
    })

    if (!Array.isArray(article.claims) || !article.claims.length) {
      fail(`${label}.claims must contain at least one explicitly authored claim`)
    }
    const localEvidenceIDs = new Set(evidence.map(item => item.id))
    const claims = article.claims.map((claim, claimIndex) => {
      const claimLabel = `${label}.claims[${claimIndex}]`
      assertKeys(claim,
        ['key', 'heading', 'body', 'lifecycle', 'ordinal', 'evidenceIDs'],
        ['key', 'heading', 'body', 'lifecycle', 'ordinal', 'evidenceIDs'], claimLabel)
      assertID(claim.key, `${claimLabel}.key`)
      if (!claim.key.startsWith(`${article.id}.`)) {
        fail(`${claimLabel}.key must be namespaced by ${article.id}.`)
      }
      assertString(claim.heading, `${claimLabel}.heading`, { max: 240 })
      assertString(claim.body, `${claimLabel}.body`)
      if (!LIFECYCLES.has(claim.lifecycle)) {
        fail(`${claimLabel}.lifecycle is not authorable without lifecycle relations: ${claim.lifecycle}`)
      }
      assertOrdinal(claim.ordinal, `${claimLabel}.ordinal`)
      if (!Array.isArray(claim.evidenceIDs) || !claim.evidenceIDs.length) {
        fail(`${claimLabel}.evidenceIDs must contain at least one evidence id`)
      }
      for (const [evidenceIndex, evidenceID] of claim.evidenceIDs.entries()) {
        assertID(evidenceID, `${claimLabel}.evidenceIDs[${evidenceIndex}]`)
        if (!localEvidenceIDs.has(evidenceID)) {
          fail(`${claimLabel}.evidenceIDs references missing article evidence ${evidenceID}`)
        }
      }
      assertUnique(claim.evidenceIDs, `${claim.key} evidence id`)
      const linkedEvidence = claim.evidenceIDs.map(id => evidence.find(item => item.id === id))
      if (claim.lifecycle === 'current'
          && linkedEvidence.every(item => item.path.startsWith('docs/history/'))) {
        fail(`current claim ${claim.key} cannot rely only on historical evidence`)
      }
      return {
        ...claim,
        articleID: article.id,
        kind: article.kind,
      }
    })
    assertUnique(claims.map(claim => claim.key), `${article.id} claim key`)
    assertUnique(claims.map(claim => claim.ordinal), `${article.id} claim ordinal`)
    if (article.lifecycle === 'historical' && claims.some(claim => claim.lifecycle !== 'historical')) {
      fail(`historical article ${article.id} cannot contain current claims`)
    }
    if (article.kind === 'history' && claims.some(claim => claim.lifecycle !== 'historical')) {
      fail(`history article ${article.id} must contain only historical claims`)
    }
    if (article.kind !== 'history' && article.lifecycle === 'current'
        && claims.some(claim => claim.lifecycle !== 'current')) {
      fail(`current article ${article.id} needs lifecycle relations before carrying historical claims`)
    }
    const usedEvidenceIDs = new Set(claims.flatMap(claim => claim.evidenceIDs))
    for (const item of evidence) {
      if (!usedEvidenceIDs.has(item.id)) fail(`article ${article.id} has unused evidence ${item.id}`)
    }
    normalizedArticles.push({ ...article, evidence, claims })
  }
  assertUnique(source.articles.map(article => article.id), 'article id')
  assertUnique(evidenceIDs, 'evidence id')
  for (const section of source.sections) {
    assertUnique(
      source.articles.filter(article => article.section === section.id).map(article => article.ordinal),
      `article ordinal in section ${section.id}`)
  }
  assertUnique(normalizedArticles.flatMap(article => article.claims.map(claim => claim.key)), 'claim key')

  const sortedArticles = normalizedArticles.sort((a, b) => {
    const sectionA = source.sections.find(section => section.id === a.section).ordinal
    const sectionB = source.sections.find(section => section.id === b.section).ordinal
    return sectionA - sectionB || a.ordinal - b.ordinal || a.id.localeCompare(b.id)
  })
  const demonstrations = validateDemonstrations(source, sortedArticles)
  const guides = validateGuides(source, sortedArticles)

  return {
    schemaVersion: source.schemaVersion,
    corpusID: source.corpusID,
    sections: [...source.sections].sort((a, b) => a.ordinal - b.ordinal || a.id.localeCompare(b.id)),
    articles: sortedArticles,
    demonstrations,
    guides,
  }
}

function validateMetadata(metadata) {
  const required = ['applicationVersion', 'applicationBuild', 'bundleIdentifier', 'tenantID',
    'sourceCommit', 'sourceDiffSHA256']
  for (const key of required) assertString(metadata[key], `metadata.${key}`, { max: 200 })
  if (!/^[a-f0-9]{40}$/.test(metadata.sourceCommit)) fail('metadata.sourceCommit must be a full Git SHA-1')
  if (!SHA256_PATTERN.test(metadata.sourceDiffSHA256)) fail('metadata.sourceDiffSHA256 must be SHA-256')
  assertString(metadata.tenantID, 'metadata.tenantID', { max: 64 })
  if (!TENANT_ID_PATTERN.test(metadata.tenantID)) {
    fail(`metadata.tenantID must match ${TENANT_ID_PATTERN}`)
  }
}

function statement(db, sql) {
  const prepared = db.prepare(sql)
  prepared.setAllowBareNamedParameters(true)
  return prepared
}

export function compileHelpCorpus({
  outputPath,
  sourcePath = DEFAULT_SOURCE,
  repoRoot = DEFAULT_REPO,
  metadata,
} = {}) {
  if (!outputPath) fail('outputPath is required')
  validateMetadata(metadata)
  const corpus = loadAndValidateCorpus({ sourcePath, repoRoot })
  const digestInput = {
    schemaVersion: corpus.schemaVersion,
    corpusID: corpus.corpusID,
    sections: corpus.sections,
    articles: corpus.articles,
    demonstrations: corpus.demonstrations,
    guides: corpus.guides,
  }
  const contentSHA256 = sha256(canonicalJSON(digestInput))
  const output = path.resolve(outputPath)
  const parent = path.dirname(output)
  fs.mkdirSync(parent, { recursive: true })
  const temporary = `${output}.tmp-${process.pid}`
  fs.rmSync(temporary, { force: true })
  fs.rmSync(`${temporary}-wal`, { force: true })
  fs.rmSync(`${temporary}-shm`, { force: true })

  let db
  try {
    db = new DatabaseSync(temporary)
    db.exec(`
      PRAGMA page_size = 4096;
      PRAGMA encoding = 'UTF-8';
      PRAGMA journal_mode = DELETE;
      PRAGMA synchronous = FULL;
      PRAGMA foreign_keys = ON;
      PRAGMA application_id = ${HELP_APPLICATION_ID};
      PRAGMA user_version = ${HELP_SCHEMA_VERSION};
      CREATE TABLE help_meta (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        corpus_schema INTEGER NOT NULL,
        corpus_id TEXT NOT NULL,
        application_version TEXT NOT NULL,
        application_build TEXT NOT NULL,
        bundle_identifier TEXT NOT NULL,
        tenant_id TEXT NOT NULL,
        source_commit TEXT NOT NULL,
        source_diff_sha256 TEXT NOT NULL,
        content_sha256 TEXT NOT NULL
      ) STRICT;
      CREATE TABLE help_section (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        ordinal INTEGER NOT NULL UNIQUE
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_article (
        id TEXT PRIMARY KEY,
        section_id TEXT NOT NULL REFERENCES help_section(id),
        title TEXT NOT NULL,
        icon TEXT NOT NULL,
        blurb TEXT NOT NULL,
        kind TEXT NOT NULL,
        lifecycle TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        markdown TEXT NOT NULL,
        body_sha256 TEXT NOT NULL,
        UNIQUE(section_id, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_article_alias (
        article_id TEXT NOT NULL REFERENCES help_article(id),
        alias TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        PRIMARY KEY(article_id, alias),
        UNIQUE(article_id, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_claim (
        key TEXT PRIMARY KEY,
        article_id TEXT NOT NULL REFERENCES help_article(id),
        heading TEXT NOT NULL,
        body TEXT NOT NULL,
        kind TEXT NOT NULL,
        lifecycle TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        body_sha256 TEXT NOT NULL,
        UNIQUE(article_id, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_evidence (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        path TEXT NOT NULL,
        anchor TEXT NOT NULL,
        source_sha256 TEXT NOT NULL,
        anchor_sha256 TEXT NOT NULL
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_claim_evidence (
        claim_key TEXT NOT NULL REFERENCES help_claim(key),
        evidence_id TEXT NOT NULL REFERENCES help_evidence(id),
        ordinal INTEGER NOT NULL,
        PRIMARY KEY(claim_key, evidence_id),
        UNIQUE(claim_key, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_relation (
        source_claim_key TEXT NOT NULL REFERENCES help_claim(key),
        target_claim_key TEXT NOT NULL REFERENCES help_claim(key),
        kind TEXT NOT NULL,
        PRIMARY KEY(source_claim_key, target_claim_key, kind)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_demo (
        id TEXT PRIMARY KEY,
        article_id TEXT NOT NULL REFERENCES help_article(id),
        title TEXT NOT NULL,
        outcome TEXT NOT NULL,
        lifecycle TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        recipe_json TEXT NOT NULL,
        recipe_sha256 TEXT NOT NULL,
        UNIQUE(article_id, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_demo_claim (
        demo_id TEXT NOT NULL REFERENCES help_demo(id),
        claim_key TEXT NOT NULL REFERENCES help_claim(key),
        ordinal INTEGER NOT NULL,
        PRIMARY KEY(demo_id, claim_key),
        UNIQUE(demo_id, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_guide (
        id TEXT PRIMARY KEY,
        article_id TEXT NOT NULL REFERENCES help_article(id),
        title TEXT NOT NULL,
        summary TEXT NOT NULL,
        surface TEXT NOT NULL,
        lifecycle TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        UNIQUE(article_id, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_guide_claim (
        guide_id TEXT NOT NULL REFERENCES help_guide(id),
        claim_key TEXT NOT NULL REFERENCES help_claim(key),
        ordinal INTEGER NOT NULL,
        PRIMARY KEY(guide_id, claim_key),
        UNIQUE(guide_id, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE help_guide_step (
        guide_id TEXT NOT NULL REFERENCES help_guide(id),
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        instruction TEXT NOT NULL,
        target TEXT NOT NULL,
        reveal_action TEXT NOT NULL,
        completion TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        PRIMARY KEY(guide_id, id),
        UNIQUE(guide_id, ordinal)
      ) STRICT, WITHOUT ROWID;
      CREATE VIRTUAL TABLE help_claim_fts USING fts5(
        claim_key UNINDEXED,
        article_id UNINDEXED,
        title,
        aliases,
        heading,
        body,
        tokenize = 'unicode61 remove_diacritics 2',
        prefix = '2 3 4'
      );
      CREATE VIRTUAL TABLE help_article_fts USING fts5(
        article_id UNINDEXED,
        title,
        aliases,
        blurb,
        markdown,
        tokenize = 'unicode61 remove_diacritics 2',
        prefix = '2 3 4'
      );
    `)

    const insertMeta = statement(db, `
      INSERT INTO help_meta (
        id, corpus_schema, corpus_id, application_version, application_build,
        bundle_identifier, tenant_id, source_commit, source_diff_sha256, content_sha256
      ) VALUES (1, $schema, $corpus, $version, $build, $bundle, $tenant, $commit, $diff, $digest)
    `)
    const insertSection = statement(db,
      'INSERT INTO help_section (id, title, ordinal) VALUES ($id, $title, $ordinal)')
    const insertArticle = statement(db, `
      INSERT INTO help_article (
        id, section_id, title, icon, blurb, kind, lifecycle, ordinal, markdown, body_sha256
      ) VALUES ($id, $section, $title, $icon, $blurb, $kind, $lifecycle, $ordinal, $markdown, $digest)
    `)
    const insertAlias = statement(db,
      'INSERT INTO help_article_alias (article_id, alias, ordinal) VALUES ($article, $alias, $ordinal)')
    const insertClaim = statement(db, `
      INSERT INTO help_claim (key, article_id, heading, body, kind, lifecycle, ordinal, body_sha256)
      VALUES ($key, $article, $heading, $body, $kind, $lifecycle, $ordinal, $digest)
    `)
    const insertEvidence = statement(db, `
      INSERT INTO help_evidence (id, kind, path, anchor, source_sha256, anchor_sha256)
      VALUES ($id, $kind, $path, $anchor, $sourceDigest, $anchorDigest)
    `)
    const linkEvidence = statement(db, `
      INSERT INTO help_claim_evidence (claim_key, evidence_id, ordinal)
      VALUES ($claim, $evidence, $ordinal)
    `)
    const insertDemo = statement(db, `
      INSERT INTO help_demo (
        id, article_id, title, outcome, lifecycle, ordinal, recipe_json, recipe_sha256
      ) VALUES ($id, $article, $title, $outcome, $lifecycle, $ordinal, $recipe, $digest)
    `)
    const linkDemoClaim = statement(db, `
      INSERT INTO help_demo_claim (demo_id, claim_key, ordinal)
      VALUES ($demo, $claim, $ordinal)
    `)
    const insertGuide = statement(db, `
      INSERT INTO help_guide (id, article_id, title, summary, surface, lifecycle, ordinal)
      VALUES ($id, $article, $title, $summary, $surface, $lifecycle, $ordinal)
    `)
    const linkGuideClaim = statement(db, `
      INSERT INTO help_guide_claim (guide_id, claim_key, ordinal)
      VALUES ($guide, $claim, $ordinal)
    `)
    const insertGuideStep = statement(db, `
      INSERT INTO help_guide_step (
        guide_id, id, title, instruction, target, reveal_action, completion, ordinal
      ) VALUES (
        $guide, $id, $title, $instruction, $target, $reveal, $completion, $ordinal
      )
    `)
    const insertClaimFTS = statement(db, `
      INSERT INTO help_claim_fts (
        rowid, claim_key, article_id, title, aliases, heading, body
      ) VALUES ($rowid, $key, $article, $title, $aliases, $heading, $body)
    `)
    const insertArticleFTS = statement(db, `
      INSERT INTO help_article_fts (rowid, article_id, title, aliases, blurb, markdown)
      VALUES ($rowid, $article, $title, $aliases, $blurb, $markdown)
    `)

    db.exec('BEGIN IMMEDIATE')
    insertMeta.run({
      schema: HELP_SCHEMA_VERSION,
      corpus: corpus.corpusID,
      version: metadata.applicationVersion,
      build: metadata.applicationBuild,
      bundle: metadata.bundleIdentifier,
      tenant: metadata.tenantID,
      commit: metadata.sourceCommit,
      diff: metadata.sourceDiffSHA256,
      digest: contentSHA256,
    })
    for (const section of corpus.sections) insertSection.run(section)

    let articleRowID = 1
    let claimRowID = 1
    for (const article of corpus.articles) {
      insertArticle.run({
        id: article.id,
        section: article.section,
        title: article.title,
        icon: article.icon,
        blurb: article.blurb,
        kind: article.kind,
        lifecycle: article.lifecycle,
        ordinal: article.ordinal,
        markdown: article.markdown,
        digest: sha256(article.markdown),
      })
      const aliases = [...article.aliases].sort((a, b) => a.localeCompare(b, 'en'))
      aliases.forEach((alias, aliasOrdinal) => {
        insertAlias.run({ article: article.id, alias, ordinal: aliasOrdinal })
      })
      const aliasesText = aliases.join(' ')
      insertArticleFTS.run({
        rowid: articleRowID++,
        article: article.id,
        title: article.title,
        aliases: aliasesText,
        blurb: article.blurb,
        markdown: article.markdown,
      })
      for (const evidence of article.evidence) {
        insertEvidence.run({
          id: evidence.id,
          kind: evidence.kind,
          path: evidence.path,
          anchor: evidence.anchor,
          sourceDigest: evidence.sourceSHA256,
          anchorDigest: evidence.anchorSHA256,
        })
      }
      for (const claim of article.claims) {
        insertClaim.run({
          key: claim.key,
          article: article.id,
          heading: claim.heading,
          body: claim.body,
          kind: claim.kind,
          lifecycle: claim.lifecycle,
          ordinal: claim.ordinal,
          digest: sha256(claim.body),
        })
        claim.evidenceIDs.forEach((evidenceID, evidenceOrdinal) => {
          linkEvidence.run({ claim: claim.key, evidence: evidenceID, ordinal: evidenceOrdinal })
        })
        insertClaimFTS.run({
          rowid: claimRowID++,
          key: claim.key,
          article: article.id,
          title: article.title,
          aliases: aliasesText,
          heading: claim.heading,
          body: claim.body,
        })
      }
    }
    for (const demo of corpus.demonstrations) {
      insertDemo.run({
        id: demo.id,
        article: demo.articleID,
        title: demo.title,
        outcome: demo.outcome,
        lifecycle: demo.lifecycle,
        ordinal: demo.ordinal,
        recipe: demo.recipeJSON,
        digest: sha256(demo.recipeJSON),
      })
      demo.claimKeys.forEach((claimKey, claimOrdinal) => {
        linkDemoClaim.run({ demo: demo.id, claim: claimKey, ordinal: claimOrdinal })
      })
    }
    for (const guide of corpus.guides) {
      insertGuide.run({
        id: guide.id,
        article: guide.articleID,
        title: guide.title,
        summary: guide.summary,
        surface: guide.surface,
        lifecycle: guide.lifecycle,
        ordinal: guide.ordinal,
      })
      guide.claimKeys.forEach((claimKey, claimOrdinal) => {
        linkGuideClaim.run({ guide: guide.id, claim: claimKey, ordinal: claimOrdinal })
      })
      guide.steps.forEach(step => {
        insertGuideStep.run({
          guide: guide.id,
          id: step.id,
          title: step.title,
          instruction: step.instruction,
          target: step.target,
          reveal: step.revealAction,
          completion: step.completion,
          ordinal: step.ordinal,
        })
      })
    }
    db.exec('COMMIT')
    db.exec('VACUUM')
    db.close()
    db = undefined

    verifyHelpCorpus(temporary, {
      ...metadata,
      corpusID: corpus.corpusID,
      contentSHA256,
      articleCount: corpus.articles.length,
      claimCount: corpus.articles.reduce((total, article) => total + article.claims.length, 0),
      demoCount: corpus.demonstrations.length,
      guideCount: corpus.guides.length,
    })
    fs.renameSync(temporary, output)
    fs.chmodSync(output, 0o644)
    return { outputPath: output, contentSHA256 }
  } catch (error) {
    try { db?.exec('ROLLBACK') } catch {}
    try { db?.close() } catch {}
    fs.rmSync(temporary, { force: true })
    fs.rmSync(`${temporary}-wal`, { force: true })
    fs.rmSync(`${temporary}-shm`, { force: true })
    throw error
  }
}

export function verifyHelpCorpus(databasePath, expected = {}) {
  const db = new DatabaseSync(databasePath, { readOnly: true })
  try {
    const integrity = db.prepare('PRAGMA integrity_check').get()?.integrity_check
    if (integrity !== 'ok') fail(`integrity_check failed for ${databasePath}: ${integrity ?? 'no result'}`)
    if (db.prepare('PRAGMA foreign_key_check').all().length) fail(`foreign_key_check failed for ${databasePath}`)
    const applicationID = db.prepare('PRAGMA application_id').get()?.application_id
    const schema = db.prepare('PRAGMA user_version').get()?.user_version
    if (applicationID !== HELP_APPLICATION_ID) fail(`wrong application_id in ${databasePath}`)
    if (schema !== HELP_SCHEMA_VERSION) fail(`wrong user_version in ${databasePath}`)
    const meta = db.prepare('SELECT * FROM help_meta').all()
    if (meta.length !== 1) fail(`expected exactly one metadata row in ${databasePath}`)
    const row = meta[0]
    const comparisons = {
      corpus_id: expected.corpusID,
      application_version: expected.applicationVersion,
      application_build: expected.applicationBuild,
      bundle_identifier: expected.bundleIdentifier,
      tenant_id: expected.tenantID,
      source_commit: expected.sourceCommit,
      source_diff_sha256: expected.sourceDiffSHA256,
      content_sha256: expected.contentSHA256,
    }
    for (const [column, value] of Object.entries(comparisons)) {
      if (value !== undefined && row[column] !== value) fail(`${column} does not match in ${databasePath}`)
    }
    const articleCount = db.prepare('SELECT count(*) AS count FROM help_article').get().count
    const claimCount = db.prepare('SELECT count(*) AS count FROM help_claim').get().count
    const demoCount = db.prepare('SELECT count(*) AS count FROM help_demo').get().count
    const guideCount = db.prepare('SELECT count(*) AS count FROM help_guide').get().count
    const claimFTSCount = db.prepare('SELECT count(*) AS count FROM help_claim_fts').get().count
    const articleFTSCount = db.prepare('SELECT count(*) AS count FROM help_article_fts').get().count
    if (expected.articleCount !== undefined && articleCount !== expected.articleCount) fail('article count does not match')
    if (expected.claimCount !== undefined && claimCount !== expected.claimCount) fail('claim count does not match')
    if (expected.demoCount !== undefined && demoCount !== expected.demoCount) fail('demonstration count does not match')
    if (expected.guideCount !== undefined && guideCount !== expected.guideCount) fail('guide count does not match')
    if (guideCount < 1) fail('guide authority is empty')
    if (claimFTSCount !== claimCount || articleFTSCount !== articleCount) fail('FTS row counts do not match authority rows')
    for (const demo of db.prepare('SELECT id, recipe_json, recipe_sha256 FROM help_demo').all()) {
      if (sha256(demo.recipe_json) !== demo.recipe_sha256) fail(`demonstration digest does not match for ${demo.id}`)
    }
    const ungroundedDemo = db.prepare(`
      SELECT d.id FROM help_demo d
      WHERE NOT EXISTS (SELECT 1 FROM help_demo_claim dc WHERE dc.demo_id = d.id)
      LIMIT 1
    `).get()
    if (ungroundedDemo) fail(`demonstration has no claim grounding: ${ungroundedDemo.id}`)
    const invalidGuide = db.prepare(`
      SELECT g.id FROM help_guide g
      JOIN help_article a ON a.id = g.article_id
      WHERE NOT EXISTS (SELECT 1 FROM help_guide_claim gc WHERE gc.guide_id = g.id)
         OR NOT EXISTS (SELECT 1 FROM help_guide_step gs WHERE gs.guide_id = g.id)
         OR (g.lifecycle = 'current' AND (
              a.lifecycle != 'current'
              OR EXISTS (
                SELECT 1 FROM help_guide_claim gc
                JOIN help_claim c ON c.key = gc.claim_key
                WHERE gc.guide_id = g.id AND c.lifecycle != 'current'
              )
            ))
      LIMIT 1
    `).get()
    if (invalidGuide) fail(`guide is not current and grounded: ${invalidGuide.id}`)
    for (const guide of db.prepare(
      'SELECT id, article_id, title, summary, surface, lifecycle, ordinal FROM help_guide').all()) {
      assertID(guide.id, `guide ${guide.id}.id`)
      assertID(guide.article_id, `guide ${guide.id}.articleID`)
      if (!guide.id.startsWith(`${guide.article_id}.`)) {
        fail(`guide ${guide.id}.id must be namespaced by ${guide.article_id}.`)
      }
      assertGuideCopy(guide.title, `guide ${guide.id}.title`, { max: 160 })
      assertGuideCopy(guide.summary, `guide ${guide.id}.summary`, { max: 600 })
      assertVocabulary(guide.surface, GUIDE_SURFACES, `guide ${guide.id}.surface`)
      assertVocabulary(guide.lifecycle, LIFECYCLES, `guide ${guide.id}.lifecycle`)
      assertOrdinal(guide.ordinal, `guide ${guide.id}.ordinal`)
    }
    for (const step of db.prepare(`
      SELECT gs.guide_id, gs.id, gs.title, gs.instruction, gs.target,
             gs.reveal_action, gs.completion, gs.ordinal, g.surface
      FROM help_guide_step gs
      JOIN help_guide g ON g.id = gs.guide_id
      ORDER BY gs.guide_id, gs.ordinal, gs.id
    `).all()) {
      const label = `guide ${step.guide_id} step ${step.id}`
      assertID(step.guide_id, `${label}.guideID`)
      assertID(step.id, `${label}.id`)
      assertGuideCopy(step.title, `${label}.title`, { max: 160 })
      assertGuideCopy(step.instruction, `${label}.instruction`, { max: 1_000 })
      assertVocabulary(step.target, GUIDE_TARGETS, `${label}.target`)
      assertVocabulary(step.reveal_action, GUIDE_REVEAL_ACTIONS, `${label}.revealAction`)
      assertVocabulary(step.completion, GUIDE_COMPLETIONS, `${label}.completion`)
      if (!GUIDE_SURFACE_TARGETS.get(step.surface)?.has(step.target)) {
        fail(`${label}.target cannot appear on surface ${step.surface}`)
      }
      if (!GUIDE_SURFACE_REVEAL_ACTIONS.get(step.surface)?.has(step.reveal_action)) {
        fail(`${label}.revealAction cannot run on surface ${step.surface}`)
      }
      if (step.reveal_action !== 'none'
          && !GUIDE_REVEAL_TARGETS.get(step.reveal_action)?.has(step.target)) {
        fail(`${label}.revealAction cannot reveal target ${step.target}`)
      }
      if (step.completion === 'textEntered' && step.target !== 'helpSearchField') {
        fail(`${label}.completion textEntered requires helpSearchField`)
      }
      assertOrdinal(step.ordinal, `${label}.ordinal`)
    }
    const smoke = db.prepare("SELECT count(*) AS count FROM help_claim_fts WHERE help_claim_fts MATCH 'Mechanician'").get().count
    if (smoke < 1) fail('FTS smoke query returned no results')
    return { meta: row, articleCount, claimCount, demoCount, guideCount }
  } finally {
    db.close()
  }
}

function gitMetadata(repoRoot) {
  const sourceCommit = execFileSync('git', ['-C', repoRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
  // Node's default maxBuffer is 1 MB and this reads the WHOLE uncommitted diff. A large in-progress
  // change therefore failed the corpus build with `spawnSync git ENOBUFS`, which surfaced as three
  // dozen unrelated Help test failures rather than as anything about Help. The identity this
  // computes is a digest of the working tree, so it must not have a size ceiling at all.
  const diff = execFileSync('git', ['-C', repoRoot, 'diff', '--binary', 'HEAD'], {
    maxBuffer: Number.MAX_SAFE_INTEGER,
  })
  return { sourceCommit, sourceDiffSHA256: sha256(diff) }
}

function readPlistValue(plistPath, key) {
  return execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plistPath], {
    encoding: 'utf8',
  }).trim()
}

const VALUE_OPTIONS = new Set([
  'output', 'source', 'repo-root', 'plist', 'app-version', 'app-build', 'bundle-id',
  'tenant-id', 'source-commit', 'source-diff-sha256',
])

export function parseArguments(argv) {
  const result = { check: false }
  const seen = new Set()
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--check') {
      if (seen.has('check')) fail('duplicate option --check')
      seen.add('check')
      result.check = true
      continue
    }
    if (!argument.startsWith('--')) fail(`unknown argument ${argument}`)
    const key = argument.slice(2)
    if (!VALUE_OPTIONS.has(key)) fail(`unknown option ${argument}`)
    if (seen.has(key)) fail(`duplicate option ${argument}`)
    const value = argv[++index]
    if (value === undefined || value.startsWith('--')) fail(`${argument} requires a value`)
    seen.add(key)
    result[key] = value
  }
  if (result.check && result.output !== undefined) fail('--check cannot be combined with --output')
  const hasCommit = result['source-commit'] !== undefined
  const hasDiff = result['source-diff-sha256'] !== undefined
  if (hasCommit !== hasDiff) {
    fail('--source-commit and --source-diff-sha256 must be supplied together')
  }
  return result
}

function resolvedMetadata(args, repoRoot) {
  const plistPath = path.resolve(args.plist ?? path.join(repoRoot, 'app', 'Mechanician-Info.plist'))
  const git = args['source-commit'] !== undefined && args['source-diff-sha256'] !== undefined
    ? {}
    : gitMetadata(repoRoot)
  return {
    applicationVersion: args['app-version'] ?? readPlistValue(plistPath, 'CFBundleShortVersionString'),
    applicationBuild: args['app-build'] ?? readPlistValue(plistPath, 'CFBundleVersion'),
    bundleIdentifier: args['bundle-id'] ?? readPlistValue(plistPath, 'CFBundleIdentifier'),
    tenantID: args['tenant-id'] ?? 'default',
    sourceCommit: args['source-commit'] ?? git.sourceCommit,
    sourceDiffSHA256: args['source-diff-sha256'] ?? git.sourceDiffSHA256,
  }
}

async function main() {
  const args = parseArguments(process.argv.slice(2))
  const repoRoot = path.resolve(args['repo-root'] ?? DEFAULT_REPO)
  const sourcePath = path.resolve(args.source ?? path.join(repoRoot, 'help', 'corpus.json'))
  const metadata = resolvedMetadata(args, repoRoot)
  if (args.check) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-check.'))
    try {
      const first = path.join(directory, 'first.sqlite')
      const second = path.join(directory, 'second.sqlite')
      compileHelpCorpus({ outputPath: first, sourcePath, repoRoot, metadata })
      compileHelpCorpus({ outputPath: second, sourcePath, repoRoot, metadata })
      const firstBytes = fs.readFileSync(first)
      const secondBytes = fs.readFileSync(second)
      if (!firstBytes.equals(secondBytes)) fail('two identical builds were not byte-for-byte deterministic')
      const verified = verifyHelpCorpus(first)
      process.stdout.write(
        `Mechanician Help: ${verified.articleCount} articles, ${verified.claimCount} claims, `
        + `${verified.demoCount} demonstrations, ${verified.guideCount} `
        + `${verified.guideCount === 1 ? 'guide' : 'guides'}, deterministic\n`)
    } finally {
      fs.rmSync(directory, { recursive: true, force: true })
    }
    return
  }
  if (!args.output) fail('--output is required unless --check is used')
  const result = compileHelpCorpus({
    outputPath: path.resolve(args.output),
    sourcePath,
    repoRoot,
    metadata,
  })
  process.stdout.write(`${result.outputPath}\n`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => {
    process.stderr.write(`${error.stack ?? error.message}\n`)
    process.exitCode = 1
  })
}

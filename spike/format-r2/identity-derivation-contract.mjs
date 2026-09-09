// format-review C1.6 spike contract: portable identity, immutable versions, derivation, and private
// registration remain separate domains. This is executable evidence, not a shipping schema or an
// activated file format.
import crypto from 'node:crypto'

export const IDENTITY_CONTRACT_VERSION = 'mechanician.identity-derivation/0-spike'
export const SEMANTIC_DIGEST_PROFILE =
  'ai.mechanician.semantic-portable-content/0-spike'

export const PORTABLE_IDENTITY_CONTRACT = Object.freeze({
  status: 'non-activated-format-review-spike',
  domains: {
    conversationLineage: {
      scope: 'portable',
      mutability: 'stable-across-meaningful-versions',
      meaning: 'one logical Conversation lineage',
      neverMintedFrom: [
        'legacyConversationId', 'path', 'bookmark', 'timestamp',
        'providerSessionId', 'providerResumeHandle', 'exactByteDigest',
      ],
    },
    recordVersion: {
      scope: 'portable',
      mutability: 'immutable',
      meaning: 'one published byte representation of a record',
      distinctFrom: ['conversationLineage', 'exactByteDigest', 'semanticDigest'],
    },
    exactByteDigest: {
      scope: 'portable-validation',
      algorithm: 'sha-256',
      meaning: 'digest of the exact serialized portable bytes',
      implication: 'equal digest means byte equality only after bytes are independently verified',
    },
    semanticDigest: {
      scope: 'profile-relative-validation',
      algorithm: 'sha-256',
      profile: SEMANTIC_DIGEST_PROFILE,
      meaning: 'digest of canonical portable content and disclosure semantics',
      excludes: [
        'lineageId', 'versionId', 'derivationLinks', 'signatureEnvelope',
        'localRegistration', 'byteEncoding',
      ],
      implication: 'equal digest claims equivalence only for the named semantic profile',
    },
    fileInstance: {
      scope: 'private-local',
      meaning: 'one observed file-system instance independent of path and portable lineage',
    },
    registration: {
      scope: 'private-local',
      meaning: 'one Mechanician registration for one file instance',
    },
    runtimeOverlay: {
      scope: 'private-local',
      meaning: 'operative state bound to a registration and file instance, never lineage alone',
    },
    legacyConversationId: {
      scope: 'private-legacy-application',
      meaning: 'today\'s Conversation.id; migration input, never portable identity by inference',
    },
  },
  relationshipTypes: {
    previousVersion: 'direct immutable predecessor in the same lineage',
    derivedFrom: 'source version used by an explicit import, projection, or adaptation',
    amends: 'source version whose claims/content are explicitly corrected, omitted, or redacted',
    forkedFrom: 'source version at which a new writable lineage diverged',
  },
  signatureRule: {
    byteBound: true,
    inheritedByNewVersion: false,
    adaptation:
      'preserve signed source bytes and verification result; derived bytes are unsigned until explicitly signed',
    sameVersionNoOp:
      'an unchanged signed version retains its own signature; this is preservation, not inheritance',
  },
})

export const PORTABLE_IDENTITY_TRANSITION_MATRIX = Object.freeze([
  {
    id: 'meaningful-save', operation: 'meaningful-save',
    lineage: 'preserve', recordVersion: 'mint', exactByteDigest: 'recompute',
    semanticDigest: 'recompute', fileInstance: 'preserve', registration: 'preserve',
    overlay: 'preserve', linksAdded: ['previousVersion'], publication: 'new-version',
    signature: 'do-not-inherit',
  },
  {
    id: 'no-op-save', operation: 'no-op-save',
    lineage: 'preserve', recordVersion: 'preserve', exactByteDigest: 'preserve',
    semanticDigest: 'preserve', fileInstance: 'preserve', registration: 'preserve',
    overlay: 'preserve', linksAdded: [], publication: 'none',
    signature: 'preserve-same-version-only',
  },
  {
    id: 'import-as-new-conversation', operation: 'import-as-new-conversation',
    lineage: 'mint', recordVersion: 'mint', exactByteDigest: 'recompute',
    semanticDigest: 'preserve-if-lossless', fileInstance: 'mint', registration: 'mint',
    overlay: 'mint-and-bind-to-registration', linksAdded: ['derivedFrom'],
    publication: 'new-version', signature: 'do-not-inherit',
  },
  {
    id: 'move-or-rename', operation: 'move-or-rename',
    lineage: 'preserve', recordVersion: 'preserve', exactByteDigest: 'preserve',
    semanticDigest: 'preserve', fileInstance: 'preserve', registration: 'preserve',
    overlay: 'preserve', linksAdded: [], publication: 'none',
    signature: 'preserve-same-version-only',
  },
  {
    id: 'finder-duplicate-before-fork', operation: 'finder-duplicate-before-fork',
    lineage: 'preserve-temporarily', recordVersion: 'preserve-temporarily',
    exactByteDigest: 'preserve', semanticDigest: 'preserve', fileInstance: 'mint',
    registration: 'mint', overlay: 'unattached', linksAdded: [],
    publication: 'none-read-only-pending-fork', signature: 'preserve-same-bytes-only',
  },
  {
    id: 'explicit-fork', operation: 'explicit-fork',
    lineage: 'mint', recordVersion: 'mint', exactByteDigest: 'recompute',
    semanticDigest: 'preserve-until-content-diverges', fileInstance: 'preserve',
    registration: 'preserve', overlay: 'mint-and-bind-to-registration',
    linksAdded: ['forkedFrom'], publication: 'new-version', signature: 'do-not-inherit',
  },
  {
    id: 'amendment', operation: 'amendment',
    lineage: 'preserve', recordVersion: 'mint', exactByteDigest: 'recompute',
    semanticDigest: 'recompute', fileInstance: 'preserve', registration: 'preserve',
    overlay: 'preserve', linksAdded: ['previousVersion', 'amends'],
    publication: 'new-version', signature: 'do-not-inherit',
  },
  {
    id: 'redacted-derived-snapshot', operation: 'redacted-derived-snapshot',
    lineage: 'mint', recordVersion: 'mint', exactByteDigest: 'recompute',
    semanticDigest: 'recompute', fileInstance: 'mint', registration: 'mint',
    overlay: 'mint-and-bind-to-registration', linksAdded: ['derivedFrom', 'amends'],
    publication: 'new-version', signature: 'do-not-inherit',
  },
  {
    id: 'signed-source-adaptation', operation: 'signed-source-adaptation',
    lineage: 'mint', recordVersion: 'mint', exactByteDigest: 'recompute',
    semanticDigest: 'preserve-if-lossless', fileInstance: 'mint', registration: 'mint',
    overlay: 'mint-and-bind-to-registration', linksAdded: ['derivedFrom'],
    publication: 'new-version', signature: 'replace-with-unsigned-derived-status',
  },
])

const RELATIONSHIP_TYPES = new Set(Object.keys(PORTABLE_IDENTITY_CONTRACT.relationshipTypes))
const OPERATIONS = new Set(PORTABLE_IDENTITY_TRANSITION_MATRIX.map((item) => item.operation))
const PORTABLE_ID_PATTERN = /^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const PRIVATE_ID_PATTERNS = {
  fileInstanceId: /^file-instance:[0-9a-f]{32}$/,
  registrationId: /^registration:[0-9a-f]{32}$/,
  overlayId: /^overlay:[0-9a-f]{32}$/,
  legacyConversationId: /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
}

const invariant = (condition, message) => {
  if (!condition) throw new Error(`identity contract invariant failed: ${message}`)
}

function exactKeys(value, allowed, label) {
  invariant(value != null && typeof value === 'object' && !Array.isArray(value),
    `${label} must be an object`)
  const unexpected = Object.keys(value).filter((key) => !allowed.includes(key))
  invariant(unexpected.length === 0, `${label} has unknown keys: ${unexpected.join(', ')}`)
}

function stableValue(value) {
  if (value == null || typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number') {
    invariant(Number.isFinite(value), 'canonical JSON cannot contain a non-finite number')
    return value
  }
  if (Array.isArray(value)) return value.map(stableValue)
  invariant(typeof value === 'object', `canonical JSON cannot contain ${typeof value}`)
  return Object.fromEntries(Object.keys(value).sort().map((key) => {
    invariant(value[key] !== undefined, `canonical JSON cannot contain undefined at ${key}`)
    invariant(key !== '__proto__' && key !== 'constructor' && key !== 'prototype',
      `canonical JSON rejects dangerous key ${key}`)
    return [key, stableValue(value[key])]
  }))
}

export function stableJSON(value) {
  return JSON.stringify(stableValue(value))
}

export function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

export function portableBytes(stateOrPortable) {
  const portable = stateOrPortable.portable ?? stateOrPortable
  return Buffer.from(stableJSON(portable))
}

export function semanticProjection(stateOrPortable) {
  const portable = stateOrPortable.portable ?? stateOrPortable
  return {
    profile: SEMANTIC_DIGEST_PROFILE,
    content: structuredClone(portable.content),
    disclosure: structuredClone(portable.disclosure),
  }
}

export function semanticDigest(stateOrPortable) {
  return sha256(Buffer.from(stableJSON(semanticProjection(stateOrPortable))))
}

function uuidFromDigest(digest, version = '8') {
  const chars = digest.slice(0, 32).split('')
  chars[12] = version
  chars[16] = ['8', '9', 'a', 'b'][parseInt(chars[16], 16) % 4]
  const raw = chars.join('')
  return `${raw.slice(0, 8)}-${raw.slice(8, 12)}-${raw.slice(12, 16)}-${raw.slice(16, 20)}-${raw.slice(20)}`
}

// Production must use its approved unpredictable identity source. Deterministic identities are
// deliberately namespaced as test-only so fixtures and generated evidence remain byte-stable.
export function createDeterministicTestAllocator(seed = 'format-review-c1.6') {
  invariant(typeof seed === 'string' && seed.length > 0, 'test allocator seed is required')
  const counters = new Map()
  return {
    next(domain) {
      invariant([
        'lineage', 'version', 'fileInstance', 'registration', 'overlay',
        'legacyConversation',
      ].includes(domain), `unknown identity domain ${domain}`)
      const ordinal = (counters.get(domain) ?? 0) + 1
      counters.set(domain, ordinal)
      const digest = sha256(`${seed}\u0000${domain}\u0000${ordinal}`)
      if (domain === 'lineage' || domain === 'version') {
        return `urn:uuid:${uuidFromDigest(digest)}`
      }
      if (domain === 'legacyConversation') return uuidFromDigest(digest, '4')
      return `${domain === 'fileInstance' ? 'file-instance' : domain}:${digest.slice(0, 32)}`
    },
  }
}

function sourceReference(state) {
  return {
    lineageId: state.portable.lineageId,
    versionId: state.portable.versionId,
    exactByteDigest: state.validation.exactByteDigest,
  }
}

function relationship(type, state) {
  invariant(RELATIONSHIP_TYPES.has(type), `unknown relationship type ${type}`)
  return { type, target: sourceReference(state), provenance: 'explicit-transition' }
}

function preservedSignedSource(state) {
  if (state.portable.signatureEnvelope == null) return []
  const bytes = portableBytes(state)
  return [{
    versionId: state.portable.versionId,
    exactByteDigest: state.validation.exactByteDigest,
    bytesBase64: bytes.toString('base64'),
    observedVerification: structuredClone(state.validation.signature),
  }]
}

function localRegistration(allocator, lineageId, locator, { attachOverlay = true } = {}) {
  const fileInstanceId = allocator.next('fileInstance')
  const registrationId = allocator.next('registration')
  const overlayId = attachOverlay ? allocator.next('overlay') : null
  return {
    fileInstanceId,
    registrationId,
    overlay: overlayId == null ? null : {
      overlayId, registrationId, fileInstanceId, lineageId,
    },
    locator,
    legacyConversationId: attachOverlay ? allocator.next('legacyConversation') : null,
  }
}

function finalize(state, signatureStatus = null) {
  state.validation = {
    exactByteDigest: sha256(portableBytes(state)),
    semanticDigest: semanticDigest(state),
    semanticProfile: SEMANTIC_DIGEST_PROFILE,
    signature: signatureStatus ?? (
      state.portable.signatureEnvelope == null
        ? { status: 'unsigned', boundExactByteDigest: null }
        : { status: 'verified-test-fixture', boundExactByteDigest: null }
    ),
  }
  if (state.portable.signatureEnvelope != null) {
    state.validation.signature.boundExactByteDigest = state.validation.exactByteDigest
  }
  validateIdentityState(state)
  return state
}

export function makeInitialIdentityState({
  allocator = createDeterministicTestAllocator(),
  content = { title: 'Identity fixture', events: [{ id: 'event-1', text: 'Retained fact' }] },
  locator = '/private/format-review/identity-source.placeholder',
  signed = false,
} = {}) {
  const lineageId = allocator.next('lineage')
  const versionId = allocator.next('version')
  const state = {
    portable: {
      format: IDENTITY_CONTRACT_VERSION,
      lineageId,
      versionId,
      content: structuredClone(content),
      disclosure: { profile: 'live-complete-spike', redacted: false, omittedCategories: [] },
      relationships: [],
      preservedSignedSources: [],
      signatureEnvelope: signed ? {
        algorithm: 'test-fixture-only', signer: 'fixture-key',
        signedVersionId: versionId, value: 'not-a-cryptographic-proof',
      } : null,
    },
    local: localRegistration(allocator, lineageId, locator),
    writable: true,
    validation: null,
  }
  return finalize(state)
}

function validateReference(reference, label) {
  exactKeys(reference, ['lineageId', 'versionId', 'exactByteDigest'], label)
  invariant(PORTABLE_ID_PATTERN.test(reference.lineageId), `${label} lineage is invalid`)
  invariant(PORTABLE_ID_PATTERN.test(reference.versionId), `${label} version is invalid`)
  invariant(/^[0-9a-f]{64}$/.test(reference.exactByteDigest), `${label} digest is invalid`)
}

export function validateIdentityState(state) {
  exactKeys(state, ['portable', 'local', 'writable', 'validation'], 'state')
  exactKeys(state.portable, [
    'format', 'lineageId', 'versionId', 'content', 'disclosure', 'relationships',
    'preservedSignedSources', 'signatureEnvelope',
  ], 'portable record')
  invariant(state.portable.format === IDENTITY_CONTRACT_VERSION, 'format changed')
  invariant(PORTABLE_ID_PATTERN.test(state.portable.lineageId), 'lineage id is invalid')
  invariant(PORTABLE_ID_PATTERN.test(state.portable.versionId), 'version id is invalid')
  invariant(state.portable.lineageId !== state.portable.versionId,
    'lineage and record version identities collided')
  invariant(Array.isArray(state.portable.relationships), 'relationships must be an array')
  for (const [index, link] of state.portable.relationships.entries()) {
    exactKeys(link, ['type', 'target', 'provenance'], `relationship ${index}`)
    invariant(RELATIONSHIP_TYPES.has(link.type), `relationship ${index} has unknown type`)
    invariant(link.provenance === 'explicit-transition',
      `relationship ${index} was not explicitly established`)
    validateReference(link.target, `relationship ${index} target`)
    invariant(link.target.versionId !== state.portable.versionId,
      `relationship ${index} is self-referential`)
    if (link.type === 'previousVersion') {
      invariant(link.target.lineageId === state.portable.lineageId,
        'previousVersion crossed lineages')
    }
    if (link.type === 'forkedFrom') {
      invariant(link.target.lineageId !== state.portable.lineageId,
        'forkedFrom did not mint a new lineage')
    }
  }
  invariant(Array.isArray(state.portable.preservedSignedSources),
    'preserved signed sources must be an array')
  for (const [index, source] of state.portable.preservedSignedSources.entries()) {
    exactKeys(source, [
      'versionId', 'exactByteDigest', 'bytesBase64', 'observedVerification',
    ], `preserved source ${index}`)
    invariant(PORTABLE_ID_PATTERN.test(source.versionId),
      `preserved source ${index} version is invalid`)
    const bytes = Buffer.from(source.bytesBase64, 'base64')
    invariant(bytes.toString('base64') === source.bytesBase64,
      `preserved source ${index} is not canonical base64`)
    invariant(sha256(bytes) === source.exactByteDigest,
      `preserved source ${index} bytes do not match their digest`)
    invariant(source.observedVerification.status === 'verified-test-fixture',
      `preserved source ${index} does not report its source verification status`)
    invariant(source.observedVerification.boundExactByteDigest === source.exactByteDigest,
      `preserved source ${index} verification does not bind its exact bytes`)
  }

  exactKeys(state.local, [
    'fileInstanceId', 'registrationId', 'overlay', 'locator', 'legacyConversationId',
  ], 'local registration')
  invariant(PRIVATE_ID_PATTERNS.fileInstanceId.test(state.local.fileInstanceId),
    'file-instance id is invalid')
  invariant(PRIVATE_ID_PATTERNS.registrationId.test(state.local.registrationId),
    'registration id is invalid')
  invariant(typeof state.local.locator === 'string' && state.local.locator.length > 0,
    'private locator is required')
  if (state.local.legacyConversationId != null) {
    invariant(PRIVATE_ID_PATTERNS.legacyConversationId.test(state.local.legacyConversationId),
      'legacy Conversation.id is invalid')
  }
  if (state.local.overlay == null) {
    invariant(state.writable === false, 'writable registration has no bound overlay')
  } else {
    exactKeys(state.local.overlay, [
      'overlayId', 'registrationId', 'fileInstanceId', 'lineageId',
    ], 'overlay binding')
    invariant(PRIVATE_ID_PATTERNS.overlayId.test(state.local.overlay.overlayId),
      'overlay id is invalid')
    invariant(state.local.overlay.registrationId === state.local.registrationId,
      'overlay is attached to a different registration')
    invariant(state.local.overlay.fileInstanceId === state.local.fileInstanceId,
      'overlay is attached by lineage rather than file instance')
    invariant(state.local.overlay.lineageId === state.portable.lineageId,
      'overlay lineage binding is stale')
  }

  exactKeys(state.validation, [
    'exactByteDigest', 'semanticDigest', 'semanticProfile', 'signature',
  ], 'validation')
  invariant(state.validation.exactByteDigest === sha256(portableBytes(state)),
    'exact-byte digest does not match portable bytes')
  invariant(state.validation.semanticProfile === SEMANTIC_DIGEST_PROFILE,
    'semantic digest profile changed')
  invariant(state.validation.semanticDigest === semanticDigest(state),
    'semantic digest does not match its profile projection')
  exactKeys(state.validation.signature, ['status', 'boundExactByteDigest'],
    'signature validation')
  if (state.portable.signatureEnvelope == null) {
    invariant(['unsigned', 'unsigned-derived'].includes(state.validation.signature.status),
      'unsigned bytes claim an inherited signature')
    invariant(state.validation.signature.boundExactByteDigest == null,
      'unsigned bytes retain a signature binding')
  } else {
    exactKeys(state.portable.signatureEnvelope, [
      'algorithm', 'signer', 'signedVersionId', 'value',
    ], 'signature envelope')
    invariant(state.portable.signatureEnvelope.signedVersionId === state.portable.versionId,
      'signature envelope was inherited from a different record version')
    invariant(state.validation.signature.status === 'verified-test-fixture',
      'signed fixture has invalid verification status')
    invariant(state.validation.signature.boundExactByteDigest ===
      state.validation.exactByteDigest, 'signature status is bound to different bytes')
  }

  const portableText = portableBytes(state).toString('utf8')
  for (const privateValue of [
    state.local.fileInstanceId, state.local.registrationId, state.local.overlay?.overlayId,
    state.local.locator, state.local.legacyConversationId,
  ].filter(Boolean)) {
    invariant(!portableText.includes(privateValue), 'private local identity leaked into portable bytes')
  }
  return true
}

function transitionInput(operation, options, allowed) {
  invariant(OPERATIONS.has(operation), `unknown transition ${operation}`)
  exactKeys(options, allowed, `${operation} options`)
}

function sourceWithNewVersion(source, allocator, content, relationships, disclosure = null) {
  const next = structuredClone(source)
  next.portable.versionId = allocator.next('version')
  next.portable.content = structuredClone(content)
  next.portable.relationships = relationships
  if (disclosure != null) next.portable.disclosure = structuredClone(disclosure)
  next.portable.preservedSignedSources.push(...preservedSignedSource(source))
  next.portable.signatureEnvelope = null
  if (next.local.overlay != null) next.local.overlay.lineageId = next.portable.lineageId
  return finalize(next, { status: 'unsigned-derived', boundExactByteDigest: null })
}

export function applyIdentityTransition(source, operation, options = {}) {
  validateIdentityState(source)
  invariant(OPERATIONS.has(operation), `unknown transition ${operation}`)
  const allocator = options.allocator
  if (operation !== 'no-op-save' && operation !== 'move-or-rename'
      && operation !== 'finder-duplicate-before-fork') {
    invariant(allocator?.next != null, `${operation} requires an identity allocator`)
  }
  switch (operation) {
    case 'no-op-save': {
      transitionInput(operation, options, [])
      return structuredClone(source)
    }
    case 'meaningful-save': {
      transitionInput(operation, options, ['allocator', 'content'])
      invariant(stableJSON(options.content) !== stableJSON(source.portable.content),
        'meaningful save cannot publish unchanged content')
      return sourceWithNewVersion(source, allocator, options.content, [
        ...source.portable.relationships, relationship('previousVersion', source),
      ])
    }
    case 'move-or-rename': {
      transitionInput(operation, options, ['locator'])
      invariant(typeof options.locator === 'string' && options.locator.length > 0,
        'move requires a private locator')
      const moved = structuredClone(source)
      moved.local.locator = options.locator
      validateIdentityState(moved)
      return moved
    }
    case 'import-as-new-conversation':
    case 'signed-source-adaptation': {
      transitionInput(operation, options, ['allocator', 'locator'])
      if (operation === 'signed-source-adaptation') {
        invariant(source.portable.signatureEnvelope != null,
          'signed-source adaptation requires signed source bytes')
      }
      const lineageId = allocator.next('lineage')
      const imported = {
        portable: {
          ...structuredClone(source.portable),
          lineageId,
          versionId: allocator.next('version'),
          relationships: [relationship('derivedFrom', source)],
          preservedSignedSources: preservedSignedSource(source),
          signatureEnvelope: null,
        },
        local: localRegistration(allocator, lineageId, options.locator),
        writable: true,
        validation: null,
      }
      return finalize(imported, { status: 'unsigned-derived', boundExactByteDigest: null })
    }
    case 'finder-duplicate-before-fork': {
      transitionInput(operation, options, ['allocator', 'locator'])
      invariant(options.allocator?.next != null, 'duplicate requires an identity allocator')
      const duplicate = structuredClone(source)
      duplicate.local = localRegistration(options.allocator, source.portable.lineageId,
        options.locator, { attachOverlay: false })
      duplicate.writable = false
      validateIdentityState(duplicate)
      return duplicate
    }
    case 'explicit-fork': {
      transitionInput(operation, options, ['allocator'])
      invariant(source.writable === false && source.local.overlay == null,
        'fork requires a read-only duplicate with no attached overlay')
      const fork = structuredClone(source)
      fork.portable.lineageId = allocator.next('lineage')
      fork.portable.versionId = allocator.next('version')
      fork.portable.relationships = [relationship('forkedFrom', source)]
      fork.portable.preservedSignedSources.push(...preservedSignedSource(source))
      fork.portable.signatureEnvelope = null
      fork.local.overlay = {
        overlayId: allocator.next('overlay'),
        registrationId: fork.local.registrationId,
        fileInstanceId: fork.local.fileInstanceId,
        lineageId: fork.portable.lineageId,
      }
      fork.local.legacyConversationId = allocator.next('legacyConversation')
      fork.writable = true
      return finalize(fork, { status: 'unsigned-derived', boundExactByteDigest: null })
    }
    case 'amendment': {
      transitionInput(operation, options, ['allocator', 'content'])
      invariant(stableJSON(options.content) !== stableJSON(source.portable.content),
        'amendment requires an explicit content change')
      return sourceWithNewVersion(source, allocator, options.content, [
        ...source.portable.relationships,
        relationship('previousVersion', source),
        relationship('amends', source),
      ])
    }
    case 'redacted-derived-snapshot': {
      transitionInput(operation, options, [
        'allocator', 'content', 'locator', 'omittedCategories',
      ])
      invariant(Array.isArray(options.omittedCategories)
        && options.omittedCategories.length > 0,
      'redacted snapshot requires declared omissions')
      invariant(stableJSON(options.content) !== stableJSON(source.portable.content),
        'redacted snapshot requires a content change')
      const lineageId = allocator.next('lineage')
      const redacted = {
        portable: {
          ...structuredClone(source.portable),
          lineageId,
          versionId: allocator.next('version'),
          content: structuredClone(options.content),
          disclosure: {
            profile: 'redacted-derived-spike', redacted: true,
            omittedCategories: [...options.omittedCategories].sort(),
          },
          relationships: [
            relationship('derivedFrom', source), relationship('amends', source),
          ],
          preservedSignedSources: preservedSignedSource(source),
          signatureEnvelope: null,
        },
        local: localRegistration(allocator, lineageId, options.locator),
        writable: true,
        validation: null,
      }
      return finalize(redacted, { status: 'unsigned-derived', boundExactByteDigest: null })
    }
    default:
      throw new Error(`identity contract invariant failed: unknown transition ${operation}`)
  }
}

export function compareIdentityStates(before, after) {
  validateIdentityState(before)
  validateIdentityState(after)
  return {
    sameLineage: before.portable.lineageId === after.portable.lineageId,
    sameRecordVersion: before.portable.versionId === after.portable.versionId,
    exactByteEqual: before.validation.exactByteDigest === after.validation.exactByteDigest,
    semanticEquivalent: before.validation.semanticProfile === after.validation.semanticProfile
      && before.validation.semanticDigest === after.validation.semanticDigest,
    sameFileInstance: before.local.fileInstanceId === after.local.fileInstanceId,
    sameRegistration: before.local.registrationId === after.local.registrationId,
    sameOverlay: before.local.overlay?.overlayId === after.local.overlay?.overlayId,
    addedRelationshipTypes: after.portable.relationships
      .slice(before.portable.relationships.length).map((item) => item.type),
    signatureBefore: before.validation.signature.status,
    signatureAfter: after.validation.signature.status,
  }
}

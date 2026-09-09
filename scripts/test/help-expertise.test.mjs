import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { DatabaseSync } from 'node:sqlite'
import { fileURLToPath } from 'node:url'

import { compileHelpCorpus, loadAndValidateCorpus } from '../build-help-corpus.mjs'

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url))
const REPO = path.resolve(TEST_DIR, '..', '..')
const CORPUS_PATH = path.join(REPO, 'help', 'corpus.json')
const COVERAGE_PATH = path.join(REPO, 'help', 'expertise-coverage.json')
const QUESTIONS_PATH = path.join(REPO, 'help', 'evals', 'golden-questions.json')
const HELP_ID = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/
const COVERAGE_STATUSES = new Set(['covered', 'partial', 'gap'])
const QUESTION_CATEGORIES = new Set(['retrieval', 'citation', 'lifecycle', 'abstention'])
// Mirrors `MechanicianHelpStore`'s question stop words exactly.
const STOP_WORDS = new Set([
  'about', 'and', 'are', 'can', 'does', 'for', 'from', 'how', 'in', 'into', 'is',
  'me', 'mechanician', 'my', 'of', 'on', 'show', 'the', 'this', 'to', 'what',
  'when', 'where', 'why', 'with',
])
const METADATA = {
  applicationVersion: '9.9.9',
  applicationBuild: '999',
  bundleIdentifier: 'ai.mechanician.help-expertise-tests',
  tenantID: 'default',
  sourceCommit: 'e'.repeat(40),
  sourceDiffSHA256: 'f'.repeat(64),
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function exactKeys(object, expected, label) {
  assert.deepEqual(Object.keys(object).sort(), [...expected].sort(), `${label} fields drifted`)
}

function matchExpression(question) {
  const bounded = Buffer.from(question, 'utf8').subarray(0, 4 * 1_024).toString('utf8')
  const rawTokens = (bounded.match(/[\p{L}\p{N}]+/gu) ?? []).map(token => {
    let boundedToken = ''
    let bytes = 0
    for (const scalar of token) {
      const scalarBytes = Buffer.byteLength(scalar, 'utf8')
      if (bytes + scalarBytes <= 64) {
        boundedToken += scalar
        bytes += scalarBytes
      }
    }
    return boundedToken
  })
  const seen = new Set()
  let tokens = rawTokens.filter(token => {
    const normalized = token.normalize('NFD').replace(/\p{M}/gu, '').toLocaleLowerCase('en-US')
    if ((normalized.length <= 1 && !/^\d$/.test(normalized)) || seen.has(normalized)) return false
    seen.add(normalized)
    return true
  })
  const meaningful = tokens.filter(token => !STOP_WORDS.has(token.toLocaleLowerCase('en-US')))
  if (meaningful.length) tokens = meaningful
  tokens = tokens.slice(0, 12)
  if (!tokens.length) return undefined
  return tokens.map(token => `"${token.replaceAll('"', '""')}"`).join(' OR ')
}

function search(db, question, includeHistory, limit) {
  const match = matchExpression(question)
  if (!match) return []
  const rows = db.prepare(`
    SELECT f.claim_key, c.lifecycle AS claim_lifecycle, a.lifecycle AS article_lifecycle,
           bm25(help_claim_fts, 0.0, 0.0, 10.0, 8.0, 4.0, 1.0) AS rank
    FROM help_claim_fts f
    JOIN help_claim c ON c.key = f.claim_key
    JOIN help_article a ON a.id = c.article_id
    WHERE help_claim_fts MATCH ?
      AND (? = 1 OR (c.lifecycle = 'current' AND a.lifecycle = 'current'))
    ORDER BY CASE COALESCE(NULLIF(a.lifecycle, 'current'), c.lifecycle)
               WHEN 'current' THEN 0
               WHEN 'historical' THEN 1
               WHEN 'superseded' THEN 2
               WHEN 'retired' THEN 3
               ELSE 4
             END,
             rank,
             f.rowid
    LIMIT ?
  `).all(match, includeHistory ? 1 : 0, limit)
  const evidence = db.prepare(`
    SELECT evidence_id
    FROM help_claim_evidence
    WHERE claim_key = ?
    ORDER BY ordinal
  `)
  return rows.map(row => ({
    claimKey: row.claim_key,
    claimLifecycle: row.claim_lifecycle,
    articleLifecycle: row.article_lifecycle,
    rank: row.rank,
    evidenceIDs: evidence.all(row.claim_key).map(item => item.evidence_id),
  }))
}

function currentAgentGuideSummaries(db, results, limit = 4) {
  const rankByClaim = new Map(results.filter(result => {
    return result.claimLifecycle === 'current' && result.articleLifecycle === 'current'
  }).map((result, index) => [result.claimKey, index]))
  if (!rankByClaim.size) return []
  const claimRows = db.prepare(`
    SELECT claim_key FROM help_guide_claim WHERE guide_id = ? ORDER BY ordinal
  `)
  return db.prepare(`
    SELECT g.id, g.title, g.summary, g.surface, g.ordinal
    FROM help_guide g
    JOIN help_article a ON a.id = g.article_id
    WHERE g.lifecycle = 'current' AND a.lifecycle = 'current'
      AND g.surface = 'conversationWorkspace'
    ORDER BY g.id
  `).all().flatMap(guide => {
    const ranks = claimRows.all(guide.id)
      .map(row => rankByClaim.get(row.claim_key))
      .filter(rank => rank !== undefined)
    return ranks.length ? [{ ...guide, rank: Math.min(...ranks) }] : []
  }).sort((left, right) => {
    return left.rank - right.rank || left.ordinal - right.ordinal
      || left.id.localeCompare(right.id)
  }).slice(0, limit)
}

test('the expertise manifest maps every signed claim and names incomplete subsystems', () => {
  const corpus = loadAndValidateCorpus({ sourcePath: CORPUS_PATH, repoRoot: REPO })
  const manifest = readJSON(COVERAGE_PATH)
  exactKeys(
    manifest,
    [
      'schemaVersion', 'corpusID', 'corpusSchemaVersion', 'statusDefinitions', 'summary',
      'subsystems',
    ],
    'expertise manifest')
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.corpusID, corpus.corpusID)
  assert.equal(manifest.corpusSchemaVersion, corpus.schemaVersion)
  assert.deepEqual(Object.keys(manifest.statusDefinitions).sort(), [...COVERAGE_STATUSES].sort())
  exactKeys(
    manifest.summary,
    ['coveredSubsystems', 'partialSubsystems', 'gapSubsystems'],
    'expertise summary')

  const signedClaims = new Map(corpus.articles.flatMap(article => {
    return article.claims.map(claim => [claim.key, claim])
  }))
  const assignedClaims = new Map()
  const subsystemIDs = new Set()
  const actualSummary = { covered: 0, partial: 0, gap: 0 }
  for (const subsystem of manifest.subsystems) {
    exactKeys(
      subsystem,
      ['id', 'title', 'scope', 'status', 'claimKeys', 'knownGaps'],
      `subsystem ${subsystem.id ?? '<missing>'}`)
    assert.match(subsystem.id, HELP_ID)
    assert.ok(!subsystemIDs.has(subsystem.id), `duplicate subsystem ${subsystem.id}`)
    subsystemIDs.add(subsystem.id)
    assert.ok(subsystem.title.trim().length > 0)
    assert.ok(subsystem.scope.trim().length > 0)
    assert.ok(COVERAGE_STATUSES.has(subsystem.status), `unknown status for ${subsystem.id}`)
    assert.equal(new Set(subsystem.claimKeys).size, subsystem.claimKeys.length)
    assert.ok(subsystem.knownGaps.every(gap => typeof gap === 'string' && gap.trim().length > 0))

    if (subsystem.status === 'covered') {
      assert.ok(subsystem.claimKeys.length > 0, `${subsystem.id} cannot be covered without claims`)
      assert.deepEqual(subsystem.knownGaps, [], `${subsystem.id} must not hide a known gap`)
    } else if (subsystem.status === 'partial') {
      assert.ok(subsystem.claimKeys.length > 0, `${subsystem.id} partial coverage needs claims`)
      assert.ok(subsystem.knownGaps.length > 0, `${subsystem.id} must name its partial gaps`)
    } else {
      assert.deepEqual(subsystem.claimKeys, [], `${subsystem.id} gap cannot cite coverage`)
      assert.ok(subsystem.knownGaps.length > 0, `${subsystem.id} must explain its gap`)
    }
    actualSummary[subsystem.status] += 1

    for (const claimKey of subsystem.claimKeys) {
      assert.ok(signedClaims.has(claimKey), `${subsystem.id} references missing claim ${claimKey}`)
      assert.ok(!assignedClaims.has(claimKey),
        `${claimKey} is assigned to both ${assignedClaims.get(claimKey)} and ${subsystem.id}`)
      assignedClaims.set(claimKey, subsystem.id)
    }
  }

  assert.deepEqual(
    [...signedClaims.keys()].filter(key => !assignedClaims.has(key)),
    [],
    'new signed claims need an explicit expertise subsystem assessment')
  assert.deepEqual(
    [...assignedClaims.keys()].filter(key => !signedClaims.has(key)),
    [],
    'the expertise manifest contains stale claim keys')
  assert.deepEqual(manifest.summary, {
    coveredSubsystems: actualSummary.covered,
    partialSubsystems: actualSummary.partial,
    gapSubsystems: actualSummary.gap,
  })
  assert.ok(actualSummary.partial > 0, 'the current assessment must preserve known partial coverage')
  assert.ok(actualSummary.gap > 0, 'the current assessment must preserve known uncovered subsystems')
})

test('golden questions pin recall, lifecycle, citations, and safe abstention', () => {
  const corpus = loadAndValidateCorpus({ sourcePath: CORPUS_PATH, repoRoot: REPO })
  const fixture = readJSON(QUESTIONS_PATH)
  exactKeys(
    fixture,
    ['schemaVersion', 'corpusID', 'corpusSchemaVersion', 'searchContract', 'questions'],
    'golden fixture')
  assert.equal(fixture.schemaVersion, 1)
  assert.equal(fixture.corpusID, corpus.corpusID)
  assert.equal(fixture.corpusSchemaVersion, corpus.schemaVersion)
  assert.deepEqual(fixture.searchContract, { mode: 'question', limit: 6 })
  assert.ok(fixture.questions.length >= 10)

  const claimKeys = new Set(corpus.articles.flatMap(article => article.claims.map(claim => claim.key)))
  const questionIDs = new Set()
  const seenCategories = new Set()
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-expertise.'))
  try {
    const databasePath = path.join(directory, 'MechanicianHelp.sqlite')
    compileHelpCorpus({
      outputPath: databasePath,
      sourcePath: CORPUS_PATH,
      repoRoot: REPO,
      metadata: METADATA,
    })
    const db = new DatabaseSync(databasePath, { readOnly: true })
    try {
      for (const question of fixture.questions) {
        const expectedFields = [
          'id', 'category', 'question', 'includeHistory', 'expectedClaimKeys',
          'excludedClaimKeys', 'expectedEvidenceByClaim',
        ]
        if (Object.hasOwn(question, 'expectedGuideIDs')) expectedFields.push('expectedGuideIDs')
        exactKeys(
          question,
          expectedFields,
          `golden question ${question.id ?? '<missing>'}`)
        assert.match(question.id, HELP_ID)
        assert.ok(!questionIDs.has(question.id), `duplicate golden question ${question.id}`)
        questionIDs.add(question.id)
        assert.ok(QUESTION_CATEGORIES.has(question.category), `unknown category for ${question.id}`)
        seenCategories.add(question.category)
        assert.ok(question.question.trim().length > 0)
        assert.equal(typeof question.includeHistory, 'boolean')
        assert.equal(new Set(question.expectedClaimKeys).size, question.expectedClaimKeys.length)
        assert.equal(new Set(question.excludedClaimKeys).size, question.excludedClaimKeys.length)
        for (const key of [...question.expectedClaimKeys, ...question.excludedClaimKeys]) {
          assert.ok(claimKeys.has(key), `${question.id} references missing claim ${key}`)
        }
        assert.deepEqual(
          Object.keys(question.expectedEvidenceByClaim).sort(),
          [...question.expectedClaimKeys].sort(),
          `${question.id} needs explicit evidence expectations for every expected claim`)

        const results = search(
          db,
          question.question,
          question.includeHistory,
          fixture.searchContract.limit)
        const resultKeys = results.map(result => result.claimKey)
        if (!question.includeHistory) {
          assert.ok(results.every(result => {
            return result.claimLifecycle === 'current' && result.articleLifecycle === 'current'
          }), `${question.id} returned non-current material without history opt-in`)
        }
        for (const expected of question.expectedClaimKeys) {
          assert.ok(resultKeys.includes(expected),
            `${question.id} missed ${expected}; got ${resultKeys.join(', ') || '<no results>'}`)
          const result = results.find(candidate => candidate.claimKey === expected)
          assert.deepEqual(
            result.evidenceIDs,
            question.expectedEvidenceByClaim[expected],
            `${question.id} citation drift for ${expected}`)
        }
        for (const excluded of question.excludedClaimKeys) {
          assert.ok(!resultKeys.includes(excluded), `${question.id} disclosed excluded claim ${excluded}`)
        }
        if (Object.hasOwn(question, 'expectedGuideIDs')) {
          assert.equal(new Set(question.expectedGuideIDs).size, question.expectedGuideIDs.length)
          const guides = currentAgentGuideSummaries(db, results)
          const guideIDs = guides.map(guide => guide.id)
          for (const expected of question.expectedGuideIDs) {
            assert.ok(guideIDs.includes(expected),
              `${question.id} missed guide ${expected}; got ${guideIDs.join(', ') || '<no guides>'}`)
            const summary = guides.find(guide => guide.id === expected)
            assert.ok(summary.summary.trim().length > 0,
              `${question.id} returned an empty summary for ${expected}`)
          }
        }
        if (question.category === 'abstention') {
          assert.deepEqual(resultKeys, [], `${question.id} should abstain instead of returning lexical noise`)
        }
        if (question.category === 'lifecycle' && question.includeHistory
            && question.expectedClaimKeys.length > 0) {
          assert.ok(question.expectedClaimKeys.some(expected => {
            const result = results.find(candidate => candidate.claimKey === expected)
            return result?.claimLifecycle === 'historical'
              || result?.articleLifecycle === 'historical'
          }), `${question.id} did not exercise historical retrieval`)
        }
      }
    } finally {
      db.close()
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }

  assert.deepEqual([...seenCategories].sort(), [...QUESTION_CATEGORIES].sort())
  const lifecyclePair = fixture.questions.filter(question => {
    return question.question === 'XPC collision writers reverted'
  })
  assert.deepEqual(lifecyclePair.map(question => question.includeHistory).sort(), [false, true])
})

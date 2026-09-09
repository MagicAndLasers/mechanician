import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { DatabaseSync } from 'node:sqlite'
import { fileURLToPath } from 'node:url'

import {
  compileHelpCorpus,
  loadAndValidateCorpus,
  parseArguments,
  verifyHelpCorpus,
} from '../build-help-corpus.mjs'

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url))
const REPO = path.resolve(TEST_DIR, '..', '..')
const SOURCE = path.join(REPO, 'help', 'corpus.json')
const metadata = {
  applicationVersion: '9.9.9',
  applicationBuild: '999',
  bundleIdentifier: 'ai.mechanician.tests',
  tenantID: 'default',
  sourceCommit: 'a'.repeat(40),
  sourceDiffSHA256: 'b'.repeat(64),
}

function withMutatedCorpus(mutate, run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-invalid.'))
  try {
    const corpus = JSON.parse(fs.readFileSync(SOURCE, 'utf8'))
    mutate(corpus)
    const sourcePath = path.join(directory, 'corpus.json')
    fs.writeFileSync(sourcePath, JSON.stringify(corpus))
    return run(sourcePath)
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
}

test('the public corpus has stable authored claims and explicit evidence mappings', () => {
  const corpus = loadAndValidateCorpus({ sourcePath: SOURCE, repoRoot: REPO })
  assert.equal(corpus.schemaVersion, 4)
  assert.equal(corpus.articles.length, 15)
  assert.equal(corpus.articles.flatMap(article => article.claims).length, 75)
  assert.equal(corpus.articles.flatMap(article => article.evidence).length, 28)
  assert.deepEqual(corpus.demonstrations.map(demo => demo.id).sort(), [
    'inspector.create-artifact-preview',
    'mac.discover-app-actions',
    'mac.inspect-saved-capabilities',
    'mac.inspect-shortcuts',
    'mac.run-user-chosen-capability',
  ])
  assert.deepEqual(corpus.guides.map(guide => guide.id), [
    'composer.controls-tour',
    'inspector.changes-tour',
    'inspector.agents-tour',
    'inspector.artifacts-tour',
    'inspector.skills-tour',
    'inspector.files-tour',
    'mechanician-help.inspector-tour',
  ])
  // Only the Help-local tour stays manual. Everything else is a surface the agent may present, so
  // asking to be shown the Changes panel navigates the app instead of describing it.
  assert.deepEqual(
    corpus.guides.filter(guide => guide.surface === 'conversationWorkspace')
      .map(guide => guide.id).sort(),
    [
      'composer.controls-tour',
      'inspector.agents-tour',
      'inspector.artifacts-tour',
      'inspector.changes-tour',
      'inspector.files-tour',
      'inspector.skills-tour',
    ])
  const changes = corpus.guides.find(candidate => candidate.id === 'inspector.changes-tour')
  assert.equal(changes.articleID, 'inspector')
  assert.deepEqual(changes.claimKeys, ['inspector.changes'])
  assert.deepEqual(changes.steps.map(step => step.target), [
    'conversationChangesTab',
    'conversationComposer',
  ])
  assert.deepEqual(changes.steps.map(step => step.revealAction), [
    'showChangesInspector',
    'showConversationControls',
  ])
  const controls = corpus.guides.find(candidate => candidate.id === 'composer.controls-tour')
  assert.deepEqual(controls.steps.map(step => step.target), [
    'conversationModelControl',
    'conversationEffortControl',
    'conversationPermissionControl',
    'conversationComposer',
  ])
  const guide = corpus.guides.find(candidate => candidate.id === 'mechanician-help.inspector-tour')
  assert.equal(guide.articleID, 'mechanician-help')
  assert.equal(guide.surface, 'helpWorkspaceInspector')
  assert.deepEqual(guide.claimKeys, [
    'mechanician-help.guided-tours',
    'mechanician-help.workspace-inspector',
    'mechanician-help.search',
  ])
  assert.deepEqual(guide.steps.map(step => step.target), [
    'helpInspectorTab',
    'helpTopics',
    'helpSearchField',
    'helpArticleContent',
    'helpArticleEvidence',
  ])
  assert.ok(guide.steps.every(step => step.completion === 'userAdvance'))
  for (const demo of corpus.demonstrations) {
    assert.ok(demo.id.startsWith(`${demo.articleID}.`))
    assert.ok(demo.claimKeys.length > 0)
    assert.ok(demo.requirements.tools.length > 0)
    assert.ok(demo.steps.length > 0)
    assert.ok(demo.verification.length > 0)
    assert.ok(demo.fallback.length > 0)
    assert.equal(typeof demo.recipeJSON, 'string')
  }
  for (const article of corpus.articles) {
    assert.ok(!Object.hasOwn(article, 'defaultClaimLifecycle'))
    const evidenceIDs = new Set(article.evidence.map(evidence => evidence.id))
    for (const claim of article.claims) {
      assert.ok(claim.key.startsWith(`${article.id}.`))
      assert.ok(claim.evidenceIDs.length > 0)
      assert.ok(claim.evidenceIDs.every(id => evidenceIDs.has(id)))
    }
  }
  const scheduled = corpus.articles.find(article => article.id === 'scheduled-tasks')
  assert.ok(scheduled.markdown.includes('read-only workspace access by default'))
  assert.ok(!scheduled.markdown.includes('run unattended in trust-all mode'))
  const mac = corpus.articles.find(article => article.id === 'mac')
  const macOverview = mac.claims.find(claim => claim.key === 'mac.overview')
  assert.ok(macOverview.body.includes('exact bridge and provider route advertise'))
  assert.ok(macOverview.body.includes('consult that route\'s live inventory'))
  const inventory = mac.claims.find(claim => claim.key === 'mac.what-it-can-do')
  assert.ok(inventory.body.includes('exact selected conversation'))
  assert.ok(inventory.body.includes('accepted turn'))
  assert.ok(inventory.body.includes('captured permission mode'))
  assert.ok(inventory.body.includes('marked **NEXT**'))
  assert.ok(inventory.body.includes('After the turn completes'))
  assert.ok(inventory.body.includes('current picker still matches'))
  assert.ok(!inventory.body.includes('ownership is still being tightened'))
  const accounts = corpus.articles.find(article => article.id === 'accounts')
  const managedProviders = accounts.claims.find(
    claim => claim.key === 'accounts.managed-providers')
  assert.ok(managedProviders.body.includes('AWS Bedrock'))
  assert.ok(managedProviders.body.includes('ordinary AWS credential chain'))
  assert.ok(managedProviders.body.includes('does not store AWS access keys'))
  const approvals = corpus.articles.find(article => article.id === 'approvals')
  assert.ok(approvals.aliases.includes('write containment'))
  const writeContainment = approvals.claims.find(
    claim => claim.key === 'approvals.write-containment')
  assert.ok(writeContainment.body.includes('including Bypass'))
  assert.ok(writeContainment.body.includes('resolved target'))
  assert.ok(writeContainment.body.includes("target's containing folder"))
  const help = corpus.articles.find(article => article.id === 'mechanician-help')
  assert.ok(help.aliases.includes('RecommendMechanicianWorkflow'))
  assert.ok(help.aliases.includes('Walk me through'))
  assert.ok(help.claims.find(claim => claim.key === 'mechanician-help.guided-tours')
    .body.includes('never sends a message'))
  assert.ok(help.claims.find(claim => claim.key === 'mechanician-help.show-me')
    .body.includes('Readiness is advice, not authorization'))
  assert.ok(corpus.articles.some(article => article.id === 'mechanician-help'))
  assert.ok(corpus.articles.some(article => article.id === 'extending-mechanician'))
})

test('identical inputs produce byte-identical SQLite resources', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-test.'))
  try {
    const first = path.join(directory, 'first.sqlite')
    const second = path.join(directory, 'second.sqlite')
    compileHelpCorpus({ outputPath: first, sourcePath: SOURCE, repoRoot: REPO, metadata })
    compileHelpCorpus({ outputPath: second, sourcePath: SOURCE, repoRoot: REPO, metadata })
    assert.deepEqual(fs.readFileSync(first), fs.readFileSync(second))
    const verified = verifyHelpCorpus(first, {
      ...metadata,
      corpusID: 'mechanician.public',
      articleCount: 15,
      claimCount: 75,
      demoCount: 5,
      guideCount: 7,
    })
    assert.equal(verified.meta.corpus_schema, 4)
    assert.equal(verified.demoCount, 5)
    assert.equal(verified.guideCount, 7)
    const db = new DatabaseSync(first, { readOnly: true })
    try {
      const links = db.prepare(`
        SELECT evidence_id
        FROM help_claim_evidence
        WHERE claim_key = ?
        ORDER BY ordinal
      `).all('extending-mechanician.verification').map(row => row.evidence_id)
      assert.deepEqual(links, ['contributor-verification'])
      const demo = db.prepare(`
        SELECT id, article_id, recipe_json, recipe_sha256
        FROM help_demo WHERE id = ?
      `).get('mac.run-user-chosen-capability')
      assert.equal(demo.article_id, 'mac')
      assert.equal(JSON.parse(demo.recipe_json).risk, 'dynamic')
      assert.match(demo.recipe_sha256, /^[a-f0-9]{64}$/)
      assert.deepEqual(db.prepare(`
        SELECT claim_key FROM help_demo_claim WHERE demo_id = ? ORDER BY ordinal
      `).all(demo.id).map(row => row.claim_key), ['mac.overview', 'mac.what-it-can-do'])
      const guide = db.prepare(`
        SELECT id, article_id, title, summary, surface, lifecycle, ordinal
        FROM help_guide WHERE id = ?
      `).get('mechanician-help.inspector-tour')
      assert.equal(guide.article_id, 'mechanician-help')
      assert.equal(guide.surface, 'helpWorkspaceInspector')
      assert.equal(guide.lifecycle, 'current')
      assert.deepEqual(db.prepare(`
        SELECT claim_key FROM help_guide_claim WHERE guide_id = ? ORDER BY ordinal
      `).all(guide.id).map(row => row.claim_key), [
        'mechanician-help.guided-tours',
        'mechanician-help.workspace-inspector',
        'mechanician-help.search',
      ])
      assert.deepEqual(db.prepare(`
        SELECT target, reveal_action, completion
        FROM help_guide_step WHERE guide_id = ? ORDER BY ordinal
      `).all(guide.id).map(row => [row.target, row.reveal_action, row.completion]), [
        ['helpInspectorTab', 'showHelpInspector', 'userAdvance'],
        ['helpTopics', 'showHelpTopics', 'userAdvance'],
        ['helpSearchField', 'showHelpTopics', 'userAdvance'],
        ['helpArticleContent', 'showGuideArticle', 'userAdvance'],
        ['helpArticleEvidence', 'showGuideEvidence', 'userAdvance'],
      ])
      const changesGuide = db.prepare(`
        SELECT id, article_id, summary, surface, lifecycle
        FROM help_guide WHERE id = ?
      `).get('inspector.changes-tour')
      assert.equal(changesGuide.article_id, 'inspector')
      assert.equal(changesGuide.surface, 'conversationWorkspace')
      assert.equal(changesGuide.lifecycle, 'current')
      assert.match(changesGuide.summary, /this conversation's own window/)
    } finally {
      db.close()
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
})

test('a vanished evidence anchor fails instead of retiring a claim silently', () => {
  withMutatedCorpus(
    corpus => { corpus.articles[0].evidence[0].anchor = 'This anchor does not exist anywhere.' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /must occur exactly once/)
    })
})

test('evidence source drift fails until its reviewed digest is updated', () => {
  withMutatedCorpus(
    corpus => { corpus.articles[0].evidence[0].sourceSHA256 = '0'.repeat(64) },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /review the evidence before updating its digest/)
    })
})

test('claim evidence mappings cannot be missing or empty', () => {
  withMutatedCorpus(
    corpus => { corpus.articles[0].claims[0].evidenceIDs = ['missing-evidence'] },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /references missing article evidence/)
    })
  withMutatedCorpus(
    corpus => { corpus.articles[0].claims[0].evidenceIDs = [] },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /must contain at least one evidence id/)
    })
})

test('claim keys and lifecycle shapes are rejected before SQLite generation', () => {
  withMutatedCorpus(
    corpus => { corpus.articles[0].claims[0].key = 'Invalid_claim_key' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /\.key must match/)
    })
  withMutatedCorpus(
    corpus => { corpus.articles[0].claims[0].lifecycle = 'superseded' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /not authorable without lifecycle relations/)
    })
  withMutatedCorpus(
    corpus => { corpus.articles[0].lifecycle = 'retired' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /not authorable without lifecycle relations/)
    })
})

test('demonstration contracts reject unknown fields, tools, and unsafe act shapes', () => {
  withMutatedCorpus(
    corpus => { corpus.demonstrations[0].requirements.tools = ['InventedAutomation'] },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /is not an approved demonstration tool/)
    })
  withMutatedCorpus(
    corpus => { corpus.demonstrations[0].unexpected = true },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /unknown field "unexpected"/)
    })
  withMutatedCorpus(
    corpus => { corpus.demonstrations[3].userConfirmation = 'none' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /externalDynamic demonstration tool contract/)
    })
  withMutatedCorpus(
    corpus => { corpus.demonstrations[4].verification[0].stepID = 'explain' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /stepID must reference a tool step|no post-action verification/)
    })
})

test('demonstration tool classes cannot disguise actions as observation or change their risk', () => {
  withMutatedCorpus(
    corpus => {
      const demo = corpus.demonstrations.find(candidate => {
        return candidate.id === 'mac.run-user-chosen-capability'
      })
      demo.steps.find(step => step.tool === 'RunCapability').kind = 'observe'
      demo.requirements.mode = 'readOnlyOkay'
      demo.risk = 'readOnly'
      demo.reversibility.kind = 'notNeeded'
      demo.userConfirmation = 'none'
    },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /RunCapability requires an act step/)
    })
  withMutatedCorpus(
    corpus => {
      const demo = corpus.demonstrations.find(candidate => {
        return candidate.id === 'mac.inspect-saved-capabilities'
      })
      demo.risk = 'sensitiveRead'
      demo.reversibility.kind = 'notGuaranteed'
      demo.userConfirmation = 'beforeDemo'
    },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /does not match its inventory demonstration tool contract/)
    })
  withMutatedCorpus(
    corpus => {
      const demo = corpus.demonstrations.find(candidate => {
        return candidate.id === 'inspector.create-artifact-preview'
      })
      demo.risk = 'dynamic'
      demo.reversibility.kind = 'dynamic'
      demo.userConfirmation = 'beforeAct'
    },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /does not match its inAppAdditive demonstration tool contract/)
    })
})

test('demonstrations require current claim grounding and an acyclic fallback graph', () => {
  withMutatedCorpus(
    corpus => { corpus.demonstrations[0].claimKeys = ['history.overview'] },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /cannot rely on non-current claim/)
    })
  withMutatedCorpus(
    corpus => {
      corpus.demonstrations[1].fallback = [{
        when: 'emptyResult',
        action: 'useDemo',
        demoID: 'mac.discover-app-actions',
        instruction: 'Create a cycle for the validation test.',
      }]
    },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /fallback cycle/)
    })
})

/// The Help-local tour and a tour that leaves Help, by id. Addressing them by position broke every
/// time a new guide sorted ahead of them, and a contract test must not depend on authoring order.
/// Two surfaces are needed here, not one: the cases below prove the vocabulary is closed PER
/// SURFACE, which a single-surface fixture cannot show.
function helpTourGuide(corpus) {
  return corpus.guides.find(guide => guide.id === 'mechanician-help.inspector-tour')
}

function changesTourGuide(corpus) {
  return corpus.guides.find(guide => guide.id === 'inspector.changes-tour')
}

test('guides require current claim grounding and closed native step contracts', () => {
  withMutatedCorpus(
    corpus => { helpTourGuide(corpus).surface = 'arbitraryWorkspace' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /surface is not supported/)
    })
  withMutatedCorpus(
    corpus => { helpTourGuide(corpus).claimKeys = ['history.overview'] },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /current guide .* cannot rely on non-current claim/)
    })
  withMutatedCorpus(
    corpus => { helpTourGuide(corpus).steps[0].target = 'arbitrary.css.selector' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /target is not supported/)
    })
  withMutatedCorpus(
    corpus => { helpTourGuide(corpus).steps[0].revealAction = 'showGuideArticle' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /revealAction cannot reveal target helpInspectorTab/)
    })
  withMutatedCorpus(
    corpus => {
      helpTourGuide(corpus).steps[0].target = 'conversationFilesTab'
      helpTourGuide(corpus).steps[0].revealAction = 'showFilesInspector'
    },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /target cannot appear on surface helpWorkspaceInspector/)
    })
  withMutatedCorpus(
    corpus => {
      const guide = changesTourGuide(corpus)
      guide.steps[0].revealAction = 'showHelpInspector'
    },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /revealAction cannot reveal target conversationChangesTab|cannot run on surface/)
    })
  withMutatedCorpus(
    corpus => { helpTourGuide(corpus).steps[1].completion = 'textEntered' },
    invalid => {
      assert.throws(
        () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
        /textEntered requires helpSearchField/)
    })
})

test('guides reject unknown payloads and encoded URLs scripts selectors or coordinates', () => {
  for (const [field, value, expected] of [
    ['instruction', 'Open https://example.com instead.', /must not encode a URL/],
    ['instruction', 'Open mechanician:open-help.', /must not encode a URL or URI/],
    ['instruction', 'Run an osascript command.', /must not encode a script/],
    ['instruction', 'Run python -c print(1).', /must not encode a script/],
    ['instruction', 'Find the accessibility selector for this control.', /must not encode a selector/],
    ['instruction', 'Find button:nth-child(2).', /must not encode a selector/],
    ['instruction', 'Click at (120, 240).', /must not encode a coordinate/],
    ['instruction', 'Click 120, 240.', /must not encode a coordinate/],
    ['instruction', 'Open workspaceID 95A2B134-3C53-4B16-9E55-52B168588867.', /must not encode a raw identifier|raw workspace/],
    ['instruction', 'Delete the workspace before continuing.', /must not encode a mutation/],
  ]) {
    withMutatedCorpus(
      corpus => { helpTourGuide(corpus).steps[0][field] = value },
      invalid => {
        assert.throws(
          () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
          expected)
      })
  }
  for (const payload of [
    'url', 'script', 'selector', 'coordinates', 'workspaceID', 'windowID',
    'conversationID', 'mutation', 'payload',
  ]) {
    withMutatedCorpus(
      corpus => { helpTourGuide(corpus).steps[0][payload] = 'untrusted payload' },
      invalid => {
        assert.throws(
          () => loadAndValidateCorpus({ sourcePath: invalid, repoRoot: REPO }),
          /unknown field/)
      })
  }

  for (const copy of [
    'Note: the tour waits for the person to continue.',
    'Python integrations can be discussed as ordinary product knowledge.',
    'Use the second button in the Help inspector.',
    'Read steps 2, 3, and 4 in order.',
    'Compare x and y before continuing.',
  ]) {
    withMutatedCorpus(
      corpus => { helpTourGuide(corpus).steps[0].instruction = copy },
      valid => assert.doesNotThrow(
        () => loadAndValidateCorpus({ sourcePath: valid, repoRoot: REPO })))
  }
})

test('CLI options are known, unique, and unambiguous', () => {
  assert.throws(() => parseArguments(['--mystery', 'value']), /unknown option --mystery/)
  assert.throws(
    () => parseArguments(['--tenant-id', 'one', '--tenant-id', 'two']),
    /duplicate option --tenant-id/)
  assert.throws(
    () => parseArguments(['--check', '--output', 'help.sqlite']),
    /--check cannot be combined with --output/)
  assert.throws(
    () => parseArguments(['--source-commit', 'a'.repeat(40)]),
    /--source-commit and --source-diff-sha256 must be supplied together/)
})

test('tenant ids accept the underscore allowed by release packaging', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-tenant.'))
  try {
    const output = path.join(directory, 'tenant.sqlite')
    const tenantMetadata = { ...metadata, tenantID: 'acme_internal' }
    compileHelpCorpus({ outputPath: output, sourcePath: SOURCE, repoRoot: REPO, metadata: tenantMetadata })
    assert.equal(verifyHelpCorpus(output, tenantMetadata).meta.tenant_id, 'acme_internal')
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
})

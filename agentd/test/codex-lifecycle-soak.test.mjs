import assert from 'node:assert/strict'
import { test } from 'node:test'

import { runCodexLifecycleSoak } from '../scripts/soak-codex-lifecycle.mjs'

test('seeded Codex lifecycle matrix reaches one terminal state per accepted turn', () => {
  const result = runCodexLifecycleSoak({ iterations: 13_000, seed: 0x1446 })

  assert.equal(result.format, 'ai.mechanician.codex-lifecycle-soak.v1')
  assert.equal(result.iterations, 13_000)
  assert.ok(Object.values(result.scenarios).every((count) => count === 1_000))
  assert.equal(result.dimensions.efforts.ultra, 6_500)
  assert.equal(result.dimensions.efforts.high, 6_500)
  assert.equal(result.assertions.noIndefiniteAcceptedTurns, 13_000)
  assert.equal(result.assertions.exactlyOneTerminalTransition, 13_000)
  assert.equal(result.assertions.staleGenerationRejections, 13_000)
  assert.equal(result.assertions.quietTurnsKilledForSilence, 0)
})

// One deterministic capture plan shared by the interaction tests and successor evidence record.
// Return a fresh object because capture validates and freezes its own snapshot, while callers may
// safely add test-only options without mutating another run.
export const interactionObservedAtForSequence = (sequence) =>
  new Date(Date.UTC(2026, 7, 3, 16, 0, sequence)).toISOString()

export function interactionCaptureOptions() {
  return {
    prompt: 'interactions',
    promptObservedAt: '2026-08-03T15:59:59.000Z',
    observedAtForSequence: interactionObservedAtForSequence,
    requireQuiescence: true,
    permissionResponses: [{
      permissionId: 'permission-write-escape', responseId: 'write-response-1',
      allow: true, always: false,
    }, {
      permissionId: 'permission-write-escape', responseId: 'write-response-1',
      allow: true, always: false,
    }, {
      permissionId: 'permission-capability', responseId: 'capability-response-1',
      allow: false, always: false, message: 'Keep this capability disabled.',
    }],
    questionResponses: [{
      reqId: 'question-output-style', responseId: 'question-response-1',
      answers: { 'Which output style should the fixture retain?': 'Detailed' },
      response: 'Detailed',
    }],
    interruptRequests: [{
      id: 'interrupt-root-1',
      after: { type: 'workflow_update', taskId: 'child-stopped', status: 'stopped' },
    }],
  }
}

/**
 * Decide when a bidirectional Claude input can close after a provider result.
 *
 * Claude can finish the root response while Workflow/Task children are still running. Closing the
 * input at that result tears down the SDK permission context those children still need. Newer CLIs
 * publish an authoritative background-task level, so keep the input alive until user-visible work
 * has settled and the root has completed a response cycle after the deferred result.
 */
export function createClaudeBackgroundLifetimeGate() {
  let backgroundLevelObserved = false
  let liveUserTaskCount = 0
  let resultDeferred = false
  let rootResponseActivitySinceResult = false

  return {
    observe(message, { rootResponseActivity = false } = {}) {
      if (message?.type === 'system'
          && message.subtype === 'background_tasks_changed'
          && Array.isArray(message.tasks)) {
        backgroundLevelObserved = true
        liveUserTaskCount = message.tasks
          .filter((task) => task?.ambient !== true)
          .length
      }

      if (resultDeferred && rootResponseActivity) {
        rootResponseActivitySinceResult = true
      }

      if (message?.type !== 'result') return false

      // A CLI that predates the level signal keeps the established one-result lifetime.
      if (!backgroundLevelObserved) return true

      // An observed empty (or ambient-only) set needs no extended lifetime unless an earlier
      // result was deferred while user-visible work was live.
      if (!resultDeferred && liveUserTaskCount === 0) return true

      if (liveUserTaskCount > 0) {
        resultDeferred = true
        rootResponseActivitySinceResult = false
        return false
      }

      // Task completion can itself produce an immediate zero-API result before the model handles
      // the notification. Wait for concrete root activity and its following result, so that real
      // post-workflow answer/tool cycle retains the same permission context too.
      if (!rootResponseActivitySinceResult) return false
      return true
    },
  }
}

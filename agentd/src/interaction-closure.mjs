/**
 * Close provider interactions without fabricating a user response.
 *
 * Ordering is intentional and security-relevant: ownership leaves the pending map first, the
 * provider-neutral closure is emitted second, and only then is the provider promise settled. A
 * response racing after closure therefore receives the daemon's existing negative acknowledgement
 * and can never resume the provider after the app has observed cancellation.
 */
/// A PreToolUse hook decision that refuses the call, in the SDK's hook-output shape.
///
/// Distinct from the `canUseTool` `{ behavior: 'deny' }` shape. A pending approval raised from a
/// PreToolUse hook must be settled with THIS, or the SDK reads an unrecognized object as "no
/// opinion" and the permission mode allows the call. Silent-allow on a closure path is the exact
/// failure the containment gate exists to remove, so this lives beside the closure that settles it.
export function preToolUseDenial(reason) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }
}

/// Settle one pending approval in whichever shape its caller is waiting for.
///
/// Three callers wait on `pendingPermissions` with three different contracts: Codex wants a
/// `decision`, `canUseTool` wants a `behavior`, and a PreToolUse hook wants `hookSpecificOutput`.
/// Deciding that once keeps the interrupt and turn-end paths from settling a hook-raised prompt in
/// a shape the SDK ignores.
export function pendingPermissionDenial(pending, message) {
  if (pending.codex) return { decision: 'decline' }
  if (pending.hook) return preToolUseDenial(message || 'Denied.')
  return { behavior: 'deny', message }
}

export function closePermissionRequestsForTurn(
  pendingPermissions,
  turnId,
  { emit, outcome = 'cancelled', reason, providerMessage },
) {
  const closed = []
  for (const [permissionId, pending] of pendingPermissions) {
    if (pending.turnId !== turnId) continue
    pendingPermissions.delete(permissionId)
    const event = {
      type: 'interaction_closed', id: turnId, interactionKind: 'permission',
      requestId: permissionId, outcome, reason,
    }
    emit(event)
    closed.push(event)
    pending.resolve(pendingPermissionDenial(pending, providerMessage))
  }
  return closed
}

export function closeQuestionRequestsForTurn(
  pendingQuestions,
  turnId,
  { emit, outcome = 'cancelled', reason, providerMessage },
) {
  const closed = []
  for (const [requestId, pending] of pendingQuestions) {
    if (pending.turnId !== turnId) continue
    pendingQuestions.delete(requestId)
    const event = {
      type: 'interaction_closed', id: turnId, interactionKind: 'question',
      requestId, outcome, reason,
    }
    emit(event)
    closed.push(event)
    pending.reject(new Error(providerMessage))
  }
  return closed
}

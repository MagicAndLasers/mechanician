export const PROVIDER_ACCESS_REASON_MAX_BYTES = 1024
export const PROVIDER_ACCESS_TASK_MAX_BYTES = 32 * 1024

export function createProviderAccessBroker({
  emit,
  makeRequestID,
  timeoutMilliseconds = 20000,
} = {}) {
  if (typeof emit !== 'function' || typeof makeRequestID !== 'function') {
    throw new Error('Provider access broker requires emit and makeRequestID functions.')
  }
  const pending = new Map()

  return {
    request(turnId, input) {
      const event = providerAccessEvent(turnId, input)
      const reqId = `provider-access-${makeRequestID()}`
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          if (!pending.has(reqId)) return
          pending.delete(reqId)
          reject(new Error('Mechanician did not acknowledge the provider access request.'))
        }, timeoutMilliseconds)
        pending.set(reqId, { turnId, resolve, reject, timeout })
        emit({ ...event, reqId })
      })
    },

    resolve(request) {
      const reqId = typeof request?.reqId === 'string' ? request.reqId : ''
      const operation = pending.get(reqId)
      if (!operation || request?.id !== operation.turnId) return false
      pending.delete(reqId)
      clearTimeout(operation.timeout)
      if (request.accepted === true) {
        operation.resolve()
      } else {
        operation.reject(new Error(
          typeof request.message === 'string' && request.message.trim()
            ? request.message.trim()
            : 'Mechanician could not preserve this provider access request.'))
      }
      return true
    },
  }
}

export const providerAccessToolSpec = Object.freeze({
  type: 'function',
  name: 'RequestProviderAccess',
  description: 'Ask Mechanician to let the user connect an Anthropic or OpenAI account so a preserved task can continue. Request only the provider family; the user chooses subscription or API-key access. This records the request immediately, so end the turn after it succeeds.',
  parameters: {
    type: 'object',
    properties: {
      provider: {
        type: 'string',
        enum: ['anthropic', 'openai'],
        description: 'Provider family needed for the preserved task.',
      },
      reason: {
        type: 'string',
        description: 'Short user-facing explanation of why this provider is needed.',
      },
      task: {
        type: 'string',
        description: 'Standalone instruction Mechanician can resume after the user connects an account.',
      },
    },
    required: ['provider', 'reason', 'task'],
    additionalProperties: false,
  },
})

function boundedRequiredString(value, label, maxBytes) {
  if (typeof value !== 'string') throw new Error(`${label} must be a string.`)
  const normalized = value.trim()
  if (!normalized) throw new Error(`${label} must not be empty.`)
  if (Buffer.byteLength(normalized, 'utf8') > maxBytes) {
    throw new Error(`${label} is too long.`)
  }
  return normalized
}

export function normalizeProviderAccessRequest(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new Error('Provider access request must be an object.')
  }
  const provider = input.provider
  if (provider !== 'anthropic' && provider !== 'openai') {
    throw new Error('provider must be anthropic or openai.')
  }
  return {
    provider,
    reason: boundedRequiredString(
      input.reason, 'reason', PROVIDER_ACCESS_REASON_MAX_BYTES),
    task: boundedRequiredString(
      input.task, 'task', PROVIDER_ACCESS_TASK_MAX_BYTES),
  }
}

export function providerAccessEvent(turnId, input) {
  if (typeof turnId !== 'string' || !turnId) {
    throw new Error('Provider access request requires an active turn.')
  }
  const request = normalizeProviderAccessRequest(input)
  return {
    type: 'provider_access_request',
    id: turnId,
    maker: request.provider,
    reason: request.reason,
    task: request.task,
  }
}

export function providerAccessToolResult(input) {
  const request = normalizeProviderAccessRequest(input)
  const label = request.provider === 'anthropic' ? 'Anthropic' : 'OpenAI'
  return `${label} access request recorded in Mechanician. End this turn now; the app will preserve and resume the task after the user chooses and connects an account.`
}

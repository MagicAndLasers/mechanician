import test from 'node:test'
import assert from 'node:assert/strict'

import {
  browseResponseFailure,
  browseErrorEvent,
  browseHTTPFailure,
  classifyBrowseException,
  readBoundedBrowseBody,
} from '../src/browse-errors.mjs'

test('browse errors distinguish DNS, connection, and timeout failures', () => {
  const dns = new TypeError('fetch failed')
  dns.cause = Object.assign(new Error('getaddrinfo ENOTFOUND registry.internal'), { code: 'ENOTFOUND' })
  const reset = Object.assign(new Error('socket closed'), { code: 'ECONNRESET' })
  const timeout = Object.assign(new Error('operation timed out'), { name: 'TimeoutError' })

  assert.deepEqual(classifyBrowseException(dns), {
    kind: 'network', message: 'fetch failed', code: 'ENOTFOUND',
  })
  assert.deepEqual(classifyBrowseException(reset), {
    kind: 'network', message: 'socket closed', code: 'ECONNRESET',
  })
  assert.deepEqual(classifyBrowseException(timeout), {
    kind: 'timeout', message: 'operation timed out',
  })
})

test('browse HTTP classification does not mislabel access policy as authentication', () => {
  assert.deepEqual(browseHTTPFailure(401), {
    kind: 'authentication',
    message: 'Catalog authentication is required (HTTP 401).',
    status: 401,
  })
  assert.deepEqual(browseHTTPFailure(403), {
    kind: 'http',
    message: 'Catalog access was denied (HTTP 403).',
    status: 403,
  })
  assert.deepEqual(browseHTTPFailure(403, { usesGoogleIdentity: true }), {
    kind: 'authentication',
    message: 'Google denied access to this managed catalog. Reconnect Google and try again.',
    status: 403,
  })
  assert.equal(browseHTTPFailure(503).kind, 'http')
})

test('browse responses accept valid JSON even when a proxy mislabels its content type', () => {
  assert.equal(browseResponseFailure(
    '{"plugins":[]}',
    { contentType: 'text/html; charset=utf-8', usesGoogleIdentity: true },
  ), null)
})

test('browse responses turn authenticated HTML into a reconnectable error without exposing markup', () => {
  const failure = browseResponseFailure(
    '<html><head><title>Sign in</title></head><body>secret gateway detail</body></html>',
    { contentType: 'text/html', redirected: true, usesGoogleIdentity: true },
  )
  assert.deepEqual(failure, {
    kind: 'authentication',
    message: 'The managed catalog returned a sign-in page instead of JSON. Reconnect Google and try again.',
    code: 'CATALOG_AUTH_HTML_RESPONSE',
  })
  assert.doesNotMatch(failure.message, /secret gateway detail/)
})

test('browse responses reject public HTML and malformed JSON as typed safe failures', () => {
  assert.deepEqual(browseResponseFailure('<!doctype html><title>Proxy error</title>'), {
    kind: 'invalid_response',
    message: 'The catalog returned HTML instead of JSON.',
    code: 'CATALOG_HTML_RESPONSE',
  })
  assert.deepEqual(browseResponseFailure('{"plugins":'), {
    kind: 'invalid_response',
    message: 'The catalog returned malformed JSON.',
    code: 'CATALOG_INVALID_JSON',
  })
})

test('browse response reads are bounded by both declared and streamed size', async () => {
  await assert.rejects(
    readBoundedBrowseBody(new Response('small', {
      headers: { 'content-length': '100' },
    }), { maximumBytes: 10 }),
    (error) => error?.code === 'BROWSE_RESPONSE_TOO_LARGE',
  )
  await assert.rejects(
    readBoundedBrowseBody(new Response('01234567890'), { maximumBytes: 10 }),
    (error) => error?.code === 'BROWSE_RESPONSE_TOO_LARGE',
  )
  assert.equal(
    await readBoundedBrowseBody(new Response('{"ok":true}'), { maximumBytes: 32 }),
    '{"ok":true}',
  )
  assert.deepEqual(
    classifyBrowseException(Object.assign(new Error('internal detail'), {
      code: 'BROWSE_RESPONSE_TOO_LARGE',
    })),
    {
      kind: 'invalid_response',
      message: 'The catalog response is too large for Mechanician to load safely.',
      code: 'BROWSE_RESPONSE_TOO_LARGE',
    },
  )
})

test('browse wire event remains backward compatible and bounded', () => {
  const event = browseErrorEvent('browse-1', {
    kind: 'network',
    message: 'fetch failed',
    code: 'ENOTFOUND',
  })
  assert.deepEqual(event, {
    type: 'browse_result',
    id: 'browse-1',
    error: 'fetch failed',
    errorType: 'network',
    errorCode: 'ENOTFOUND',
  })

  const unknown = browseErrorEvent('browse-2', { kind: 'invented', message: 'x'.repeat(1000) })
  assert.equal(unknown.errorType, 'unknown')
  assert.equal(unknown.error.length, 512)
})

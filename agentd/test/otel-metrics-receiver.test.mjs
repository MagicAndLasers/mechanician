import assert from 'node:assert/strict'
import http from 'node:http'
import test from 'node:test'

import {
  claudeOtelMetricsEnvironment,
  codexOtelMetricsArguments,
  codexOtelMetricsEnvironment,
  normalizeOtlpJsonMetrics,
  startOtelMetricsReceiver,
} from '../src/otel-metrics-receiver.mjs'

function request({ endpoint, token, body, contentType = 'application/json' }) {
  const url = new URL(endpoint)
  return new Promise((resolve, reject) => {
    const outgoing = http.request({
      method: 'POST',
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      headers: {
        'content-type': contentType,
        'x-mechanician-otel-token': token,
      },
    }, (response) => {
      response.resume()
      response.on('end', () => resolve(response.statusCode))
    })
    outgoing.on('error', reject)
    outgoing.end(body)
  })
}

test('normalizes allowlisted OTLP metrics and strips content-bearing attributes', () => {
  const samples = normalizeOtlpJsonMetrics({
    resourceMetrics: [{ scopeMetrics: [{ metrics: [{
      name: 'codex.tool.call.duration_ms',
      unit: 'ms',
      histogram: { dataPoints: [{
        timeUnixNano: '1700000000000000000',
        count: '2',
        sum: 14,
        min: 4,
        max: 10,
        explicitBounds: [5, 10],
        bucketCounts: ['1', '1', '0'],
        attributes: [
          { key: 'tool', value: { stringValue: 'mcp__private-server__secret-action' } },
          { key: 'success', value: { boolValue: true } },
          { key: 'reason', value: { stringValue: 'contains private prompt words' } },
          { key: 'hook_name', value: { stringValue: 'PRIVATE_HOOK_SECRET' } },
          { key: 'command', value: { stringValue: 'cat ~/.ssh/id_ed25519' } },
          { key: 'error', value: { stringValue: '/private/path failed' } },
        ],
      }] },
    }, {
      name: 'codex.user_prompt',
      sum: { dataPoints: [{ asInt: '999' }] },
    }] }] }],
  })

  assert.deepEqual(samples, [{
    name: 'codex.tool.duration',
    kind: 'histogram',
    at: '2023-11-14T22:13:20.000Z',
    attributes: { tool: 'mcp', success: true, reason: 'other', hook_name: 'other' },
    unit: 'ms',
    count: 2,
    sum: 14,
    minimum: 4,
    maximum: 10,
    explicitBounds: [5, 10],
    bucketCounts: [1, 1, 0],
  }])
  assert.doesNotMatch(JSON.stringify(samples), /private|secret|prompt/i)
})

test('metric-name suffixes and categorical labels are closed before publication', () => {
  const samples = normalizeOtlpJsonMetrics({
    resourceMetrics: [{ scopeMetrics: [{ metrics: [{
      name: 'codex.turn.PRIVATE_METRIC_SECRET.duration_ms',
      histogram: { dataPoints: [{
        count: 1,
        sum: 10,
        attributes: [
          { key: 'status', value: { stringValue: 'PRIVATE_STATUS_SECRET' } },
          { key: 'source', value: { stringValue: 'PRIVATE_SOURCE_SECRET' } },
          { key: 'model', value: { stringValue: 'PRIVATE_MODEL_SECRET' } },
        ],
      }] },
    }] }] }],
  })

  assert.equal(samples.length, 1)
  assert.equal(samples[0].name, 'codex.turn.duration')
  assert.deepEqual(samples[0].attributes, {
    status: 'other', source: 'other', model: 'other',
  })
  assert.doesNotMatch(JSON.stringify(samples), /private|secret/i)
})

test('accepts documented Claude metrics without admitting unknown Claude namespaces', () => {
  const metrics = (name) => ({
    name,
    sum: { dataPoints: [{ asInt: '7', attributes: [
      { key: 'model', value: { stringValue: 'claude-sonnet-4-6' } },
      { key: 'decision', value: { stringValue: 'accept' } },
      { key: 'session.id', value: { stringValue: 'private-session' } },
    ] }] },
  })
  const samples = normalizeOtlpJsonMetrics({
    resourceMetrics: [{ scopeMetrics: [{ metrics: [
      metrics('claude_code.token.usage'),
      metrics('claude_code.future.content_metric'),
    ] }] }],
  })

  assert.deepEqual(samples, [{
    name: 'claude_code.token.usage',
    kind: 'counter',
    at: samples[0].at,
    attributes: { model: 'claude', decision: 'accept' },
    value: 7,
  }])
})

test('receiver binds loopback, requires its token, and publishes normalized samples', async (t) => {
  const received = []
  const receiver = await startOtelMetricsReceiver({ onMetrics: (samples) => received.push(...samples) })
  t.after(() => receiver.close())
  assert.match(receiver.endpoint, /^http:\/\/127\.0\.0\.1:\d+\/v1\/metrics$/)

  const payload = JSON.stringify({
    resourceMetrics: [{ scopeMetrics: [{ metrics: [{
      name: 'codex.turn.ttft.duration_ms',
      histogram: { dataPoints: [{ count: 1, sum: 321, min: 321, max: 321 }] },
    }] }] }],
  })
  assert.equal(await request({ endpoint: receiver.endpoint, token: 'wrong', body: payload }), 403)
  assert.equal(await request({
    endpoint: receiver.endpoint,
    token: receiver.headerValue,
    body: payload,
  }), 200)
  assert.equal(received.length, 1)
  assert.equal(received[0].name, 'codex.turn.ttft')
  assert.equal(received[0].sum, 321)
})

test('receiver rejects oversized payloads without dropping the HTTP response', async (t) => {
  const receiver = await startOtelMetricsReceiver({ maximumBodyBytes: 32 })
  t.after(() => receiver.close())
  assert.equal(await request({
    endpoint: receiver.endpoint,
    token: receiver.headerValue,
    body: JSON.stringify({ resourceMetrics: [], padding: 'x'.repeat(64) }),
  }), 413)
})

test('Codex arguments configure only JSON metrics on the private receiver', () => {
  const args = codexOtelMetricsArguments({
    endpoint: 'http://127.0.0.1:43210/v1/metrics',
    headerName: 'x-mechanician-otel-token',
    headerValue: 'secret',
  })
  assert.deepEqual(args.slice(0, 4), [
    '-c',
    'analytics.enabled=true',
    '-c',
    'otel.metrics_exporter={ otlp-http = { endpoint = "http://127.0.0.1:43210/v1/metrics", protocol = "json", headers = { "x-mechanician-otel-token" = "secret" } } }',
  ])
  assert.ok(args.includes('otel.exporter="none"'))
  assert.ok(args.includes('otel.trace_exporter="none"'))
  assert.ok(args.includes('otel.log_user_prompt=false'))
  assert.deepEqual(codexOtelMetricsEnvironment({
    endpoint: 'http://127.0.0.1:43210/v1/metrics',
    headerName: 'x-mechanician-otel-token',
    headerValue: 'secret',
  }), { OTEL_METRIC_EXPORT_INTERVAL: '5000' })
})

test('Claude environment configures only JSON metrics on the private receiver', () => {
  const receiver = {
    endpoint: 'http://127.0.0.1:43210/v1/metrics',
    headerName: 'x-mechanician-otel-token',
    headerValue: 'secret',
  }
  assert.deepEqual(claudeOtelMetricsEnvironment(receiver), {
    CLAUDE_CODE_ENABLE_TELEMETRY: '1',
    OTEL_METRICS_EXPORTER: 'otlp',
    OTEL_LOGS_EXPORTER: 'none',
    OTEL_TRACES_EXPORTER: 'none',
    OTEL_LOG_USER_PROMPTS: 'false',
    OTEL_LOG_TOOL_DETAILS: 'false',
    OTEL_LOG_TOOL_CONTENT: 'false',
    OTEL_LOG_ASSISTANT_RESPONSES: 'false',
    OTEL_LOG_RAW_API_BODIES: 'false',
    OTEL_METRIC_EXPORT_INTERVAL: '5000',
    OTEL_EXPORTER_OTLP_METRICS_PROTOCOL: 'http/json',
    OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: 'http://127.0.0.1:43210/v1/metrics',
    OTEL_EXPORTER_OTLP_METRICS_HEADERS: 'x-mechanician-otel-token=secret',
    OTEL_METRICS_INCLUDE_SESSION_ID: 'false',
    OTEL_METRICS_INCLUDE_ACCOUNT_UUID: 'false',
    OTEL_METRICS_INCLUDE_ENTRYPOINT: 'false',
    OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES: 'false',
    OTEL_METRICS_INCLUDE_VERSION: 'true',
  })
})

// Private, loopback-only OTLP/HTTP JSON receiver for provider aggregate metrics.
//
// Live turn truth continues to come from the provider protocols: OTLP exporters batch, and metric
// points do not carry a stable Mechanician turn id. This receiver therefore accepts only metrics,
// strips every attribute outside a closed vocabulary, and publishes bounded aggregate samples.
// Prompt, response, reasoning, tool payload, path, URL, error text, and account identifiers never
// leave this module.

import crypto from 'node:crypto'
import http from 'node:http'

export const OTEL_METRICS_MAX_BODY_BYTES = 1_048_576
export const OTEL_METRICS_MAX_SAMPLES = 512

const CLAUDE_METRIC_NAMES = new Set([
  'claude_code.session.count',
  'claude_code.lines_of_code.count',
  'claude_code.pull_request.count',
  'claude_code.commit.count',
  'claude_code.cost.usage',
  'claude_code.token.usage',
  'claude_code.code_edit_tool.decision',
  'claude_code.active_time.total',
])

const CODEX_METRIC_PREFIXES = Object.freeze([
  'codex.api_request',
  'codex.sse_event',
  'codex.websocket.',
  'codex.responses_api_',
  'codex.transport.',
  'codex.remote_models.',
  'codex.startup_prewarm.',
  'codex.cloud_requirements.',
  'codex.turn.',
  'codex.conversation.turn.',
  'codex.tool.',
  'codex.approval.',
  'codex.mcp.',
  'codex.hooks.',
  'codex.skill.',
  'codex.skills.',
  'codex.plugin.',
  'codex.plugins.',
  'codex.memory.',
  'codex.memories.',
  'codex.task.compact',
  'codex.compaction.',
  'codex.multi_agent.',
  'codex.state_db.',
  'codex.db.',
  'codex.sqlite.',
  'codex.shell_snapshot.',
  'codex.apps.',
  'codex.thread.skills.',
  'codex.thread.started',
  'codex.retry',
  'codex.process.start',
  'codex.guardian.',
  'codex.exec_server.',
  'codex.request.',
  'codex.usage.',
  'codex.rollout_',
  'codex.rollout.',
])

const METRIC_SEMANTIC_CLASSIFIERS = Object.freeze([
  ['ttft', /(?:^|[._-])ttft(?:[._-]|$)/],
  ['ttfm', /(?:^|[._-])ttfm(?:[._-]|$)/],
  ['tbt', /(?:^|[._-])tbt(?:[._-]|$)/],
  ['e2e', /(?:^|[._-])e2e(?:[._-]|$)/],
  ['duration', /duration|latency|elapsed|(?:^|[._-])time(?:[._-]|$)|_ms(?:[._-]|$)/],
  ['tokens', /token/],
  ['cost', /cost|usd|dollar/],
  ['bytes', /bytes?|size/],
  ['ratio', /ratio|percent|bps/],
  ['count', /count|total|depth|inflight/],
  ['error', /error|fail|timeout|abort/],
  ['decision', /decision|approval|allow|deny|declin/],
  ['status', /status|state|outcome/],
  ['event', /event|request|call|run|start|spawn|connect|refresh|load|save|write|read/],
])

const ATTRIBUTE_KEYS = new Set([
  'attempt',
  'auth_mode',
  'cache',
  'config_use_memories',
  'decision',
  'feature_enabled',
  'from_wire_api',
  'has_citations',
  'hook_name',
  'http.response.status_code',
  'kind',
  'model',
  'model_reasoning_effort',
  'originator',
  'outcome',
  'read_allowed',
  'reason',
  'role',
  'session_source',
  'source',
  'status',
  'success',
  'terminal.type',
  'tmp_mem_enabled',
  'token_type',
  'tool',
  'tool_name',
  'trigger',
  'type',
])

const BOOLEAN_ATTRIBUTE_KEYS = new Set([
  'cache', 'config_use_memories', 'feature_enabled', 'from_wire_api', 'has_citations',
  'read_allowed', 'success', 'tmp_mem_enabled',
])
const NUMBER_ATTRIBUTE_KEYS = new Set(['attempt', 'http.response.status_code'])

const ATTRIBUTE_CATEGORY_VALUES = new Set([
  'accept', 'accepted', 'allowed', 'api', 'api_key', 'approved', 'assistant', 'auto',
  'automatic', 'blocked',
  'buffered', 'cache_creation', 'cache_read', 'cached', 'cancelled', 'chatgpt', 'child',
  'cli', 'cold', 'complete', 'completed', 'counter', 'declined', 'denied', 'disabled',
  'dynamic', 'enabled', 'error', 'event', 'exhausted', 'failed', 'failure', 'files',
  'gauge', 'high', 'histogram', 'hit', 'input', 'interrupted', 'local', 'low', 'manual',
  'max', 'mcp', 'media', 'medium', 'miss', 'none', 'oauth', 'other', 'output',
  'orchestration', 'partial', 'pending', 'provider', 'read', 'reasoning', 'recovered',
  'refused', 'reject', 'rejected', 'remote', 'request', 'response', 'retry', 'root',
  'scheduled', 'shell',
  'snapshot', 'startup', 'success', 'system', 'timed_out', 'tool', 'turn', 'ultra',
  'uncached', 'unknown', 'user', 'vertex', 'warm', 'web', 'write', 'xhigh',
])

function boundedString(value, maximum = 96) {
  if (typeof value !== 'string') return null
  const text = value.replace(/[\r\n\t]+/g, ' ').trim()
  return text ? text.slice(0, maximum) : null
}

function boundedToken(value, maximum = 96) {
  const text = boundedString(value, maximum)
  return text && /^[A-Za-z0-9_.:/-]+$/.test(text) ? text : null
}

function normalizedCategory(value) {
  const raw = boundedString(value, 96)
  if (!raw) return null
  const category = raw
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
  return ATTRIBUTE_CATEGORY_VALUES.has(category) ? category : 'other'
}

function coarseModel(value) {
  const model = boundedToken(value, 128)?.toLowerCase()
  if (!model) return null
  if (model.startsWith('claude')) return 'claude'
  if (model.startsWith('gpt')) return 'gpt'
  if (/^o\d/.test(model)) return 'o_series'
  if (model.includes('codex')) return 'codex'
  return 'other'
}

function metricPrefixMatches(name, prefix) {
  if (name === prefix) return true
  if (prefix.endsWith('.') || prefix.endsWith('_')) return name.startsWith(prefix)
  return name.startsWith(`${prefix}.`) || name.startsWith(`${prefix}_`)
}

function normalizedMetricName(value) {
  const raw = boundedToken(value, 128)
  if (!raw) return null
  if (CLAUDE_METRIC_NAMES.has(raw)) return raw
  const prefix = CODEX_METRIC_PREFIXES
    .filter((candidate) => metricPrefixMatches(raw, candidate))
    .sort((left, right) => right.length - left.length)[0]
  if (!prefix) return null
  const family = prefix.replace(/[._]+$/g, '').split(/[._:/-]+/).filter(Boolean).join('.')
  const lower = raw.toLowerCase()
  const semantic = METRIC_SEMANTIC_CLASSIFIERS.find(([, pattern]) => pattern.test(lower))?.[0]
    || 'other'
  return `${family}.${semantic}`
}

function normalizedMetricUnit(value) {
  const raw = boundedString(value, 32)?.toLowerCase()
  if (!raw) return null
  if (raw === 'ms' || raw.includes('millisecond')) return 'ms'
  if (raw === 's' || raw.includes('second')) return 's'
  if (raw === 'by' || raw.includes('byte')) return 'By'
  if (raw === 'usd' || raw.includes('dollar')) return 'usd'
  if (raw === '%' || raw.includes('percent')) return '%'
  if (raw.includes('token')) return 'tokens'
  if (raw.includes('line')) return 'lines'
  if (raw === '1' || /^\{[^{}]+\}$/.test(raw) || raw.includes('count')) return '1'
  return null
}

function finiteNumber(value) {
  if (typeof value === 'bigint') return Number(value)
  if (typeof value === 'string' && value.trim()) value = Number(value)
  return Number.isFinite(value) ? Number(value) : null
}

function boundedMetricNumber(value) {
  const number = finiteNumber(value)
  return number !== null && Math.abs(number) <= 1e18 ? number : null
}

function boundedMetricCount(value) {
  const number = finiteNumber(value)
  return Number.isSafeInteger(number) && number >= 0 && number <= 1_000_000_000_000
    ? number
    : null
}

function otlpValue(value) {
  if (!value || typeof value !== 'object') return null
  if (Object.hasOwn(value, 'stringValue')) return boundedString(value.stringValue)
  if (Object.hasOwn(value, 'boolValue')) return value.boolValue === true
  for (const key of ['intValue', 'doubleValue']) {
    if (Object.hasOwn(value, key)) return finiteNumber(value[key])
  }
  return null
}

function coarseTool(value) {
  const tool = boundedString(value, 160)?.toLowerCase()
  if (!tool) return null
  if (tool.includes('mcp') || tool.includes('connector')) return 'mcp'
  if (tool.includes('shell') || tool.includes('exec') || tool.includes('command') || tool === 'bash') {
    return 'shell'
  }
  if (tool.includes('file') || tool.includes('patch') || tool.includes('read') || tool.includes('write')) {
    return 'files'
  }
  if (tool.includes('web') || tool.includes('search') || tool.includes('browser')) return 'web'
  if (tool.includes('agent') || tool.includes('collab') || tool.includes('delegate')) return 'orchestration'
  if (tool.includes('image') || tool.includes('computer')) return 'media'
  return 'other'
}

function sanitizedAttributes(raw) {
  const attributes = {}
  for (const item of Array.isArray(raw) ? raw : []) {
    const key = boundedString(item?.key, 64)
    if (!key || !ATTRIBUTE_KEYS.has(key)) continue
    let value = otlpValue(item.value)
    if (value === null) continue
    if (BOOLEAN_ATTRIBUTE_KEYS.has(key)) {
      if (typeof value !== 'boolean') continue
    } else if (NUMBER_ATTRIBUTE_KEYS.has(key)) {
      if (typeof value !== 'number') continue
      if (key === 'attempt') {
        if (!Number.isSafeInteger(value) || value < 0 || value > 1_000_000) continue
      } else if (!Number.isSafeInteger(value) || value < 100 || value > 999) continue
    } else if (typeof value !== 'string') {
      continue
    } else if (key === 'tool' || key === 'tool_name') value = coarseTool(value)
    else if (key === 'model') {
      value = coarseModel(value)
    } else {
      value = normalizedCategory(value)
    }
    if (value === null) continue
    attributes[key] = typeof value === 'string' ? value.slice(0, 96) : value
  }
  return attributes
}

function boundedNumbers(value, maximum = 64) {
  if (!Array.isArray(value)) return undefined
  return value.slice(0, maximum).map(boundedMetricNumber).filter((item) => item !== null)
}

function normalizedPoint(name, unit, kind, point, receivedAt) {
  if (!point || typeof point !== 'object') return null
  const atNanos = finiteNumber(point.timeUnixNano)
  const reportedDate = atNanos && atNanos > 0
    ? new Date(Math.floor(atNanos / 1_000_000))
    : null
  const at = reportedDate && Number.isFinite(reportedDate.getTime())
    ? reportedDate.toISOString()
    : receivedAt
  const sample = {
    name,
    kind,
    at,
    attributes: sanitizedAttributes(point.attributes),
  }
  const boundedUnit = normalizedMetricUnit(unit)
  if (boundedUnit) sample.unit = boundedUnit

  if (kind === 'histogram') {
    const count = boundedMetricCount(point.count)
    const sum = boundedMetricNumber(point.sum)
    const minimum = boundedMetricNumber(point.min)
    const maximum = boundedMetricNumber(point.max)
    if (count !== null) sample.count = count
    if (sum !== null) sample.sum = sum
    if (minimum !== null) sample.minimum = minimum
    if (maximum !== null) sample.maximum = maximum
    const bounds = boundedNumbers(point.explicitBounds)
    const buckets = boundedNumbers(point.bucketCounts, 65)
    if (bounds?.length) sample.explicitBounds = bounds
    if (buckets?.length) {
      sample.bucketCounts = buckets
        .map(boundedMetricCount)
        .filter((item) => item !== null)
    }
    if (count === null && sum === null && minimum === null && maximum === null && !buckets?.length) {
      return null
    }
    return sample
  }

  const value = boundedMetricNumber(point.asDouble ?? point.asInt)
  if (value === null) return null
  sample.value = value
  return sample
}

/** Normalize the content-free subset of an OTLP ExportMetricsServiceRequest JSON payload. */
export function normalizeOtlpJsonMetrics(payload, {
  receivedAt = new Date().toISOString(),
  maximumSamples = OTEL_METRICS_MAX_SAMPLES,
} = {}) {
  if (!payload || typeof payload !== 'object') return []
  const samples = []
  for (const resource of Array.isArray(payload.resourceMetrics) ? payload.resourceMetrics : []) {
    for (const scope of Array.isArray(resource?.scopeMetrics) ? resource.scopeMetrics : []) {
      for (const metric of Array.isArray(scope?.metrics) ? scope.metrics : []) {
        if (samples.length >= maximumSamples) return samples
        const name = normalizedMetricName(metric?.name)
        if (!name) continue
        let kind = null
        let dataPoints = null
        if (metric.histogram?.dataPoints) {
          kind = 'histogram'
          dataPoints = metric.histogram.dataPoints
        } else if (metric.sum?.dataPoints) {
          kind = 'counter'
          dataPoints = metric.sum.dataPoints
        } else if (metric.gauge?.dataPoints) {
          kind = 'gauge'
          dataPoints = metric.gauge.dataPoints
        }
        if (!kind || !Array.isArray(dataPoints)) continue
        for (const point of dataPoints) {
          if (samples.length >= maximumSamples) return samples
          const normalized = normalizedPoint(name, metric.unit, kind, point, receivedAt)
          if (normalized) samples.push(normalized)
        }
      }
    }
  }
  return samples
}

function readRequestBody(request, maximumBytes) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let bytes = 0
    let settled = false
    request.on('data', (chunk) => {
      if (settled) return
      bytes += chunk.length
      if (bytes > maximumBytes) {
        settled = true
        reject(Object.assign(new Error('OTLP metrics request exceeded the body limit.'), { code: 413 }))
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => {
      if (!settled) resolve(Buffer.concat(chunks).toString('utf8'))
    })
    request.on('error', (error) => {
      if (!settled) reject(error)
    })
  })
}

/**
 * Start one authenticated receiver on an ephemeral loopback port.
 *
 * The returned endpoint and header are intended for process-scoped Codex `-c` overrides; they are
 * never written to the shared config.toml. `close()` resolves after the listener releases its port.
 */
export async function startOtelMetricsReceiver({
  onMetrics = () => {},
  log = () => {},
  maximumBodyBytes = OTEL_METRICS_MAX_BODY_BYTES,
} = {}) {
  const token = crypto.randomBytes(24).toString('base64url')
  const headerName = 'x-mechanician-otel-token'
  const server = http.createServer(async (request, response) => {
    if (request.method !== 'POST' || request.url !== '/v1/metrics') {
      response.writeHead(404).end()
      return
    }
    if (request.headers[headerName] !== token) {
      response.writeHead(403).end()
      return
    }
    const contentType = String(request.headers['content-type'] || '').toLowerCase()
    if (!contentType.includes('json')) {
      response.writeHead(415).end()
      return
    }
    try {
      const body = await readRequestBody(request, maximumBodyBytes)
      const samples = normalizeOtlpJsonMetrics(JSON.parse(body))
      if (samples.length) await onMetrics(samples)
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end('{}')
    } catch (error) {
      const status = error?.code === 413 ? 413 : 400
      log(`Ignoring invalid OTLP metrics request: ${error?.message || error}`)
      if (!response.headersSent) response.writeHead(status)
      response.end()
    }
  })

  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject)
      resolve()
    })
  })
  const address = server.address()
  if (!address || typeof address === 'string') {
    await new Promise((resolve) => server.close(resolve))
    throw new Error('OTLP metrics receiver did not acquire a loopback port.')
  }
  server.unref()
  return {
    endpoint: `http://127.0.0.1:${address.port}/v1/metrics`,
    headerName,
    headerValue: token,
    close: () => new Promise((resolve) => server.close(resolve)),
  }
}

function tomlString(value) {
  return JSON.stringify(String(value))
}

/** Process-scoped Codex overrides for JSON metrics only; logs and traces remain disabled. */
export function codexOtelMetricsArguments(receiver) {
  if (!receiver?.endpoint || !receiver?.headerName || !receiver?.headerValue) return []
  const header = `${tomlString(receiver.headerName)} = ${tomlString(receiver.headerValue)}`
  const exporter = `{ otlp-http = { endpoint = ${tomlString(receiver.endpoint)}, protocol = "json", headers = { ${header} } } }`
  return [
    // App Server defaults analytics off. Enabling it here activates the metric instruments, while
    // the process-scoped exporter below keeps every accepted point on this loopback receiver.
    '-c', 'analytics.enabled=true',
    '-c', `otel.metrics_exporter=${exporter}`,
    '-c', 'otel.exporter="none"',
    '-c', 'otel.trace_exporter="none"',
    '-c', 'otel.log_user_prompt=false',
    '-c', 'otel.environment="mechanician-local"',
  ]
}

export function codexOtelMetricsEnvironment(receiver) {
  if (!receiver?.endpoint || !receiver?.headerName || !receiver?.headerValue) return {}
  return { OTEL_METRIC_EXPORT_INTERVAL: '5000' }
}

/** Process-scoped Claude Code environment for JSON metrics only. */
export function claudeOtelMetricsEnvironment(receiver) {
  if (!receiver?.endpoint || !receiver?.headerName || !receiver?.headerValue) return {}
  return {
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
    OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: receiver.endpoint,
    OTEL_EXPORTER_OTLP_METRICS_HEADERS:
      `${receiver.headerName}=${receiver.headerValue}`,
    OTEL_METRICS_INCLUDE_SESSION_ID: 'false',
    OTEL_METRICS_INCLUDE_ACCOUNT_UUID: 'false',
    OTEL_METRICS_INCLUDE_ENTRYPOINT: 'false',
    OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES: 'false',
    OTEL_METRICS_INCLUDE_VERSION: 'true',
  }
}

// Thin JSON-RPC transport for the locally installed Codex App Server.
//
// Keeping this separate from agentd's NDJSON bridge makes Codex a provider rather
// than a special case in the Swift UI. The server owns ChatGPT OAuth and token
// refresh; Mechanician only opens its authorization URL and stores no credentials.

import readline from 'node:readline'
import { spawn } from 'node:child_process'

// Codex owns the OAuth callback. Asking it to use the local success page keeps the browser flow
// provider-controlled while allowing Mechanician to reactivate itself after the authoritative
// `account/login/completed` notification.
export const CODEX_LOGIN_START_PARAMS = Object.freeze({
  type: 'chatgpt',
  appBrand: 'codex',
  useHostedLoginSuccessPage: false,
})

/// Non-enumerable result metadata used only at the local JSON-RPC transport boundary. A handler may
/// attach a function under this symbol when UI disclosure must wait until the matching server
/// response has actually been written. Symbols never enter `JSON.stringify`, so the App Server
/// receives its ordinary protocol result and no Mechanician-only field.
export const CODEX_RESPONSE_WRITTEN = Symbol('mechanician.codex.responseWritten')

function appServerError(message, details = {}) {
  const error = new Error(message)
  for (const [key, value] of Object.entries(details)) {
    if (value !== undefined) error[key] = value
  }
  return error
}

export class CodexAppServer {
  constructor({
    executable, env, args = [], onNotification, onRequest, onExit, onActivityChange,
    log, spawnProcess = spawn,
  }) {
    this.executable = executable
    this.env = env
    /// Repeatable `-c key=value` TOML overrides, applied before the subcommand. Used for settings
    /// that must hold for the whole process and cannot be expressed safely in config.toml — a bare
    /// top-level key written into our managed region would bind to whichever table precedes it.
    this.args = args
    this.onNotification = onNotification || (() => {})
    this.onRequest = onRequest || (async () => ({}))
    this.onExit = onExit || (() => {})
    this.onActivityChange = onActivityChange || (() => {})
    this.log = log || (() => {})
    this.spawnProcess = spawnProcess
    this.child = null
    this.nextId = 1
    this.pending = new Map()
    this.inboundRequests = 0
    this.activityBusy = false
    this.closed = false
    this.closing = false
    this.lines = null
  }

  async start() {
    if (this.child) return
    this.closed = false
    this.closing = false
    const child = this.spawnProcess(this.executable, [...this.args, 'app-server', '--stdio'], {
      env: this.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    this.child = child

    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (text) => {
      const trimmed = String(text).trim()
      if (trimmed) this.log(`[codex] ${trimmed}`)
    })
    child.stdin.on?.('error', (err) => this.#writeFailed(err))

    const lines = readline.createInterface({ input: child.stdout })
    this.lines = lines
    lines.on('line', (line) => this.#receive(line))
    child.on('error', (err) => this.#close(appServerError(
      err?.message || 'Codex App Server process failed.',
      { providerType: 'app_server_exit', code: err?.code },
    )))
    child.on('exit', (code, signal) => {
      this.#close(appServerError(
        `Codex App Server exited (${signal || code || 'unknown'}).`,
        { providerType: 'app_server_exit', code: 'app_server_exit', exitCode: code, signal },
      ))
    })

    await this.request('initialize', {
      clientInfo: { name: 'mechanician', title: 'Mechanician', version: '0.1.0' },
      capabilities: {
        experimentalApi: true,
        // Let downstream MCP servers use OpenAI's extended form elicitation, not just the plain
        // MCP one. Codex gates the richer mode on this flag, and `sites` is written against it.
        mcpServerOpenaiFormElicitation: true,
      },
    })
    this.notify('initialized', {})
  }

  request(method, params = null, timeoutMs = 30_000) {
    if (!this.child || this.closed) {
      return Promise.reject(appServerError('Codex App Server is not running.', {
        providerType: 'app_server_unavailable', code: 'app_server_unavailable', method,
      }))
    }
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) {
          this.#activityChanged()
          reject(appServerError(`Codex App Server timed out waiting for ${method}.`, {
            providerType: 'app_server_timeout', code: 'app_server_timeout', method, timeoutMs,
          }))
        }
      }, timeoutMs)
      this.pending.set(id, { resolve, reject, timer, method })
      this.#activityChanged()
      this.#write({ id, method, params })
    })
  }

  notify(method, params = {}) {
    if (!this.child || this.closed) return
    this.#write({ method, params })
  }

  get hasInFlightWork() {
    return this.pending.size > 0 || this.inboundRequests > 0
  }

  #activityChanged() {
    const busy = this.hasInFlightWork
    if (busy === this.activityBusy) return
    this.activityBusy = busy
    try { this.onActivityChange(busy) } catch {}
  }

  close({
    error = new Error('Codex App Server was stopped.'),
    signal = 'SIGTERM',
    forceAfterMs = 1_000,
  } = {}) {
    this.closed = true
    this.#close(error, { signal, forceAfterMs })
  }

  #write(message, onWritten = null) {
    const child = this.child
    if (!child || this.closed) return
    try {
      child.stdin.write(JSON.stringify(message) + '\n', (err) => {
        if (err) {
          this.#writeFailed(err)
          return
        }
        if (typeof onWritten === 'function') {
          try { onWritten() }
          catch (callbackError) {
            this.log(`Codex App Server response-written callback failed: ${callbackError?.message || callbackError}`)
          }
        }
      })
    } catch (err) {
      this.#writeFailed(err)
    }
  }

  #writeFailed(error) {
    const wrapped = appServerError(
      error?.message || 'Codex App Server input closed.',
      { providerType: 'app_server_exit', code: error?.code || 'stdin_error' },
    )
    this.log(`Codex App Server write failed: ${wrapped.message}`)
    this.#close(wrapped)
  }

  async #receive(line) {
    let message
    try { message = JSON.parse(line) }
    catch {
      this.log(`Ignoring malformed Codex App Server message: ${line.slice(0, 160)}`)
      return
    }

    if (Object.prototype.hasOwnProperty.call(message, 'id') &&
        (Object.prototype.hasOwnProperty.call(message, 'result') || Object.prototype.hasOwnProperty.call(message, 'error'))) {
      const pending = this.pending.get(message.id)
      if (!pending) return
      this.pending.delete(message.id)
      this.#activityChanged()
      clearTimeout(pending.timer)
      if (message.error) {
        pending.reject(appServerError(
          message.error.message || `Codex App Server ${pending.method} failed.`,
          {
            providerType: 'json_rpc_error',
            code: message.error.code,
            data: message.error.data,
            method: pending.method,
          },
        ))
      }
      else pending.resolve(message.result)
      return
    }

    // Server-initiated requests carry an id and method; approval requests land here.
    if (Object.prototype.hasOwnProperty.call(message, 'id') && message.method) {
      this.inboundRequests += 1
      this.#activityChanged()
      try {
        const result = await this.onRequest({ method: message.method, params: message.params || {}, id: message.id })
        const onWritten = result?.[CODEX_RESPONSE_WRITTEN]
        this.#write({ id: message.id, result: result ?? {} }, onWritten)
      } catch (err) {
        this.#write({ id: message.id, error: { code: -32603, message: err?.message || String(err) } })
      } finally {
        this.inboundRequests = Math.max(0, this.inboundRequests - 1)
        this.#activityChanged()
      }
      return
    }

    if (message.method) this.onNotification({ method: message.method, params: message.params || {} })
  }

  #close(error, { signal = 'SIGTERM', forceAfterMs = 1_000 } = {}) {
    if (this.closing || (!this.child && this.pending.size === 0)) return
    this.closing = true
    const child = this.child
    const lines = this.lines
    this.child = null
    this.lines = null
    try {
      try { lines?.removeAllListeners(); lines?.close() } catch {}
      try { child?.stdout?.destroy?.() } catch {}
      try { child?.stderr?.destroy?.() } catch {}
      try { child?.stdin?.destroy?.() } catch {}
      try {
        if (child && child.exitCode == null && child.signalCode == null) {
          child.kill?.(signal)
          // A wedged App Server may acknowledge neither JSON-RPC cancellation nor SIGTERM.
          // Retain the child just long enough to guarantee it cannot outlive its daemon/lane.
          if (signal !== 'SIGKILL' && Number.isFinite(forceAfterMs) && forceAfterMs >= 0) {
            const forceTimer = setTimeout(() => {
              try {
                if (child.exitCode == null && child.signalCode == null) child.kill?.('SIGKILL')
              } catch {}
            }, forceAfterMs)
            forceTimer.unref?.()
          }
        }
      } catch {}
      for (const { reject, timer, method } of this.pending.values()) {
        clearTimeout(timer)
        reject(appServerError(error?.message || 'Codex App Server stopped.', { ...error, method }))
      }
      this.pending.clear()
      this.#activityChanged()
      this.onExit(error)
    } finally {
      this.closing = false
    }
  }
}

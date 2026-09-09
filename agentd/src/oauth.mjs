// Generic loopback redirect capture for MCP OAuth.
//
// Provider OAuth is driven end-to-end by the Claude SDK/CLI: it owns PKCE, discovery, dynamic
// client registration, token exchange, and token persistence. Mechanician only catches the browser
// redirect on an ephemeral loopback port and returns that callback URL to the SDK. Claude account
// login does not use this module; Anthropic's bundled login broker owns that entire flow itself.

import { createServer } from 'node:http'

export function startRedirectCapture({ timeoutMs = 5 * 60 * 1000 } = {}) {
  return new Promise((ready, readyFail) => {
    let resolveCallback
    let rejectCallback
    const callback = new Promise((resolve, reject) => {
      resolveCallback = resolve
      rejectCallback = reject
    })
    // cancel()/timeout can reject while nobody is awaiting waitForCallback(). Mark the promise
    // handled here; a later real awaiter still receives the same rejection.
    callback.catch(() => {})
    let done = false
    let timer
    const shutdown = () => {
      clearTimeout(timer)
      try { server.close() } catch {}
    }

    const server = createServer((request, response) => {
      const url = new URL(request.url, 'http://127.0.0.1')
      if (!url.pathname.startsWith('/callback')) {
        response.writeHead(404)
        response.end()
        return
      }
      const full = `http://localhost:${server.address().port}${request.url}`
      const error = url.searchParams.get('error')
      response.writeHead(200, { 'Content-Type': 'text/html' })
      response.end(`<!doctype html><meta charset=utf8><body style="font:15px -apple-system;\
padding:3rem;text-align:center;color:#e5e9f0;background:#2e3440">\
<h2>${error ? 'Authorization failed' : '✓ Connected'}</h2>\
<p style="color:#81a1c1">${error ? String(error) : 'You can close this tab and return to Mechanician.'}</p></body>`)
      if (done) return
      done = true
      shutdown()
      if (error) rejectCallback(new Error(`authorization denied: ${error}`))
      else resolveCallback(full)
    })

    server.on('error', (error) => {
      if (!done) {
        done = true
        readyFail(error)
      }
    })
    timer = setTimeout(() => {
      if (!done) {
        done = true
        rejectCallback(new Error('authorization timed out'))
        try { server.close() } catch {}
      }
    }, timeoutMs)

    server.listen(0, '127.0.0.1', () => {
      ready({
        redirectUri: `http://localhost:${server.address().port}/callback`,
        waitForCallback: () => callback,
        cancel: () => {
          if (!done) {
            done = true
            rejectCallback(new Error('cancelled'))
            shutdown()
          }
        },
      })
    })
  })
}

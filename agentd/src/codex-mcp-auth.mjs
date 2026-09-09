// OAuth sign-in and sign-out for MCP servers on the Codex lane.
//
// Codex owns these credentials, not Mechanician. That was the deliberate choice (option B): the
// token never enters our process environment, so it cannot be read by the shell commands the model
// runs, and it cannot leak through a crash report. The cost is that Codex's store is the source of
// truth and our Keychain records do not govern it.
//
// The shapes below are Codex's, mapped onto the control contract the app already speaks:
//   mcpServer/oauth/login {name} -> {authorizationUrl}    ->  mcp_authorize_url
//   notification mcpServer/oauthLogin/completed
//     {name, success, error}                              ->  mcp_authorize_ok | mcp_authorize_error
//   `codex mcp logout <name>` (there is no logout RPC)    ->  mcp_clear_auth_ok
//
// KNOWN LIMIT, measured: `codex mcp logout` is LOCAL ONLY. It deletes Codex's copy of the
// credential; it does not call the server's revocation endpoint, and a token replayed afterwards is
// still accepted until it expires. "Clear Auth" therefore means "this Mac forgets it", not "the
// server stops honouring it", and the UI must not promise more than that.

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)

const LOGIN_TIMEOUT_SECONDS = 300
const LOGOUT_TIMEOUT_MS = 20_000

/// Where Codex keeps MCP OAuth credentials. Pinned rather than left to the `auto` default: auto is
/// free to fall back to a plaintext file inside CODEX_HOME, which would be a credential at rest and
/// strictly worse than the environment exposure this whole approach exists to avoid. Passed as a
/// process override rather than written into config.toml — a bare top-level key placed in our
/// managed region would bind to whichever table happens to precede it.
export const CODEX_CREDENTIALS_STORE_ARGS = ['-c', 'mcp_oauth_credentials_store="keyring"']

/// Requests awaiting `mcpServer/oauthLogin/completed`. Codex reports completion by SERVER NAME, so
/// the pending request id has to be parked under that name to route the terminal event back.
export function createCodexOAuthWaiters() {
  return new Map()
}

/**
 * Begin an OAuth sign-in. Emits the authorization URL as soon as Codex produces one; the terminal
 * event arrives later through `resolveCodexOAuthCompletion`.
 */
export async function beginCodexOAuthLogin({
  id, name, app, waiters, emit, scopes, attemptId, serverId, source,
  accountInstanceId, routeIdentity, operation, reconcile = false,
}) {
  const identity = {
    ...(reconcile && attemptId ? { attemptId } : {}),
    ...(attemptId ? { changeId: attemptId } : {}),
    ...(source ? { source } : {}),
    ...(serverId ? { serverId } : {}),
    ...(accountInstanceId ? { accountInstanceId } : {}),
    ...(routeIdentity ? { routeIdentity } : {}),
    ...(operation ? { operation } : {}),
  }
  if (!app) {
    emit({
      type: reconcile ? 'mcp_reconcile_error' : 'mcp_authorize_error', id, name, ...identity,
      message: 'Codex is not running, so this server cannot be authorized yet.',
    })
    return
  }
  // A second attempt supersedes the first rather than leaving two requests waiting on one name.
  const waiter = {
    app, id, attemptId, serverId, source, accountInstanceId, routeIdentity, operation, reconcile,
  }
  waiters.set(name, waiter)
  try {
    const response = await app.request('mcpServer/oauth/login', {
      name,
      ...(scopes?.length ? { scopes } : {}),
      timeoutSecs: LOGIN_TIMEOUT_SECONDS,
    })
    // Completion, cancellation, provider exit, or a newer attempt may settle this name while the
    // start RPC is still in flight. Only the exact attempt that still owns the slot may publish a
    // URL or another terminal event.
    if (waiters.get(name) !== waiter) return
    const url = response?.authorizationUrl
    if (!url) {
      waiters.delete(name)
      emit({
        type: reconcile ? 'mcp_reconcile_error' : 'mcp_authorize_error', id, name, ...identity,
        message: 'Codex did not return an authorization URL for this server.',
      })
      return
    }
    // Non-terminal: the app opens this and shows the row as waiting. Completion follows.
    emit({ type: 'mcp_authorize_url', id, name, url, ...identity })
  } catch (error) {
    if (waiters.get(name) !== waiter) return
    waiters.delete(name)
    emit({
      type: reconcile ? 'mcp_reconcile_error' : 'mcp_authorize_error', id, name, ...identity,
      message: error?.message || 'Codex could not start the authorization flow.',
    })
  }
}

/**
 * Claim `mcpServer/oauthLogin/completed` for whichever request is waiting on that server. A
 * successful provider notification is not yet an application success: agentd must first cross its
 * MCP generation/restart barrier, then emit the returned terminal event.
 * @returns {{handled: boolean, waiter?: object, event?: object, success?: boolean}}
 */
export function resolveCodexOAuthCompletion({ notification, waiters }) {
  const name = notification?.name
  if (!name) return { handled: false }
  const waiter = waiters.get(name)
  if (!waiter) return { handled: false }
  waiters.delete(name)
  const event = notification.success
    ? {
        type: waiter.reconcile ? 'mcp_reconcile_ok' : 'mcp_authorize_ok', id: waiter.id, name,
        ...(waiter.reconcile && waiter.attemptId ? { attemptId: waiter.attemptId } : {}),
        ...(waiter.attemptId ? { changeId: waiter.attemptId } : {}),
        ...(waiter.source ? { source: waiter.source } : {}),
        ...(waiter.serverId ? { serverId: waiter.serverId } : {}),
        ...(waiter.accountInstanceId ? { accountInstanceId: waiter.accountInstanceId } : {}),
        ...(waiter.routeIdentity ? { routeIdentity: waiter.routeIdentity } : {}),
        ...(waiter.operation ? { operation: waiter.operation } : {}),
      }
    : {
        type: waiter.reconcile ? 'mcp_reconcile_error' : 'mcp_authorize_error', id: waiter.id, name,
        ...(waiter.reconcile && waiter.attemptId ? { attemptId: waiter.attemptId } : {}),
        ...(waiter.attemptId ? { changeId: waiter.attemptId } : {}),
        ...(waiter.source ? { source: waiter.source } : {}),
        ...(waiter.serverId ? { serverId: waiter.serverId } : {}),
        ...(waiter.accountInstanceId ? { accountInstanceId: waiter.accountInstanceId } : {}),
        ...(waiter.routeIdentity ? { routeIdentity: waiter.routeIdentity } : {}),
        ...(waiter.operation ? { operation: waiter.operation } : {}),
        message: notification.error || 'Authorization did not complete.',
      }
  return { handled: true, waiter, event, success: Boolean(notification.success) }
}

/// An explicit cancel. Codex exposes no cancel RPC, so this only stops US from waiting; a browser
/// tab the user already opened is theirs to abandon.
export function cancelCodexOAuthLogin({ id, name, waiters, emit }) {
  const waiter = waiters.get(name)
  waiters.delete(name)
  emit({
    type: 'mcp_authorize_cancel_ok', id, name,
    ...(waiter?.attemptId ? { attemptId: waiter.attemptId } : {}),
    ...(waiter?.attemptId ? { changeId: waiter.attemptId } : {}),
    ...(waiter?.source ? { source: waiter.source } : {}),
    ...(waiter?.serverId ? { serverId: waiter.serverId } : {}),
    ...(waiter?.accountInstanceId ? { accountInstanceId: waiter.accountInstanceId } : {}),
    ...(waiter?.routeIdentity ? { routeIdentity: waiter.routeIdentity } : {}),
    ...(waiter?.operation ? { operation: waiter.operation } : {}),
  })
}

/**
 * Sign out. Local only — see the note at the top of this file.
 */
export async function clearCodexOAuth({
  id, name, executable, codexHome, emit, exec = run,
}) {
  if (!executable) {
    const event = {
      type: 'mcp_authorize_error', id, name,
      message: 'The Codex command line could not be located, so its credential was left in place.',
    }
    emit?.(event)
    return { ok: false, event }
  }
  try {
    // The same override the app-server runs with: if the two disagreed about where credentials
    // live, logout would look in the wrong store and report success without removing anything.
    await exec(executable, [...CODEX_CREDENTIALS_STORE_ARGS, 'mcp', 'logout', name], {
      env: { ...process.env, CODEX_HOME: codexHome },
      timeout: LOGOUT_TIMEOUT_MS,
    })
    const event = { type: 'mcp_clear_auth_ok', id, name }
    emit?.(event)
    return { ok: true, event }
  } catch (error) {
    // Already signed out is a success from the user's point of view: the credential is gone.
    const detail = `${error?.stderr || ''} ${error?.message || ''}`
    if (/not logged in|no credentials|not found/i.test(detail)) {
      const event = { type: 'mcp_clear_auth_ok', id, name }
      emit?.(event)
      return { ok: true, event }
    }
    const event = {
      type: 'mcp_authorize_error', id, name,
      message: 'Codex could not remove this server’s stored credential.',
    }
    emit?.(event)
    return { ok: false, event }
  }
}

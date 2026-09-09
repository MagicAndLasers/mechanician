// Replies to requests the Codex app-server initiates that Mechanician answers on its own, with no
// user involved.
//
// Factored out of agentd.mjs because the failure mode is severe and invisible: a server-initiated
// request that Mechanician answers with a JSON-RPC error does not fail the turn — it leaves the
// caller waiting for an answer it can act on, and the lane wedges. Everything that can be answered
// without a person belongs here, where it can be asserted.

/**
 * @returns {object|null} the reply, or null when the method needs real handling (or is unknown and
 *   should be refused).
 */
export function unattendedCodexReply(method) {
  switch (method) {
    // No arbitrary sandbox expansion is granted implicitly. Command and file-change approvals still
    // travel through Mechanician's consent UI.
    case 'item/permissions/requestApproval':
      return { permissions: {}, scope: 'turn' }
    // `mcpServer/elicitation/request` used to be answered here with a blanket decline. It is now
    // handled attended, in agentd's handleElicitation — a mounted MCP server can ask the user a
    // question and get a real answer (FR-116). It is deliberately absent from this file: everything
    // here is answered WITHOUT a person, and that is no longer true of elicitation.
    default:
      return null
  }
}

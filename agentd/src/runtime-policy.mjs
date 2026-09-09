// Provider-neutral authorization policy for Mechanician-owned tools.
//
// Provider adapters are responsible only for translating their native request into
// one of these tool names. Keeping the risk classification here prevents Claude,
// OpenAI Responses, and Codex dynamic tools from silently drifting apart.

const READ_ONLY_TOOLS = new Set([
  'Read', 'ListFiles', 'SearchFiles',
  'CreateOrUpdateArtifact', 'Question', 'WaitFor', 'RequestProviderAccess',
  // Listing the saved automations is strictly less revealing than `ListShortcuts` beside it: it
  // returns names, titles and descriptions the user themselves wrote, and runs nothing. Without it
  // here, the local lanes prompt for permission to read a list, which is consent theatre.
  // `RunCapability` is deliberately NOT here; it keeps its per-capability approval.
  'ListCapabilities',
  'ListShortcuts', 'DiscoverAppActions',
  // Both spellings. The Codex and OpenAI lanes execute the bare name; the Claude lane mounts the
  // same tool as an in-process MCP server, so `canUseTool` only ever sees the prefixed one and a
  // bare entry misses it entirely.
  'mcp__help__SearchMechanicianHelp',
  'mcp__help__RecommendMechanicianWorkflow',
  'SearchMechanicianHelp',
  'RecommendMechanicianWorkflow',
])

const EDIT_TOOLS = new Set(['Write', 'Edit'])
const SENSITIVE_READ_TOOLS = new Set(['ComputerScreenshot'])

// `ShowMechanician` is neither a generic read nor external automation. It selects one signed,
// app-owned local presentation whose route, targets, highlights, and restoration steps are fixed by
// the bundled authority. Keep this class explicit so a future "read-only" refactor cannot silently
// broaden it into arbitrary navigation or treat it as permission for another action.
const BOUNDED_LOCAL_PRESENTATION_TOOLS = new Set([
  'ShowMechanician',
  'mcp__help__ShowMechanician',
])

// `OperateMechanician` performs one operation from a closed, app-owned vocabulary instead of
// presenting it. It is deliberately NOT in the presentation set: it changes app state. It is also
// not an ordinary local action, because everything it can reach is inside Mechanician, visible the
// moment it happens, and recoverable: panels and settings reverse from the same control, while a
// new conversation is empty, unsent, and removable. The vocabulary excludes permission mode,
// provider accounts, sending, and deletion precisely so this class can exist.
// Prompting to open a panel the person just asked for would make the feature pointless, so the
// only bar is Plan: while the person is holding the app read-only, the agent does not operate it.
const BOUNDED_LOCAL_OPERATION_TOOLS = new Set([
  'OperateMechanician',
  'mcp__help__OperateMechanician',
])

const CLAUDE_PLAN_SAFE_EXACT_TOOLS = new Set([
  'Read', 'Glob', 'Grep', 'WebSearch', 'WebFetch', 'Skill', 'ToolSearch',
  'mcp__artifacts__CreateOrUpdateArtifact',
  'mcp__waitmode__WaitFor',
  'mcp__ask__Question',
  'mcp__provider_access__RequestProviderAccess',
  'mcp__shortcuts__ListShortcuts',
  'mcp__shortcuts__DiscoverAppActions',
  'mcp__capabilities__ListCapabilities',
  'mcp__help__SearchMechanicianHelp',
  'mcp__help__RecommendMechanicianWorkflow',
  'mcp__help__ShowMechanician',
  // `mcp__help__OperateMechanician` is deliberately absent. Plan mode is the person holding the app
  // read-only; `mcp__help__` is one of our own namespaces, so omitting it here denies rather than
  // prompts, which is the verdict we want for a tool that changes app state.
])

const CLAUDE_SAFE_EXACT_TOOLS = new Set([
  'mcp__artifacts__CreateOrUpdateArtifact',
  'mcp__waitmode__WaitFor',
  'mcp__ask__Question',
  'mcp__provider_access__RequestProviderAccess',
  'Skill',
  'ToolSearch',
  'mcp__shortcuts__ListShortcuts',
  'mcp__shortcuts__DiscoverAppActions',
  'mcp__capabilities__ListCapabilities',
  'mcp__capabilities__SaveCapability',
  'mcp__help__SearchMechanicianHelp',
  'mcp__help__RecommendMechanicianWorkflow',
  'mcp__help__ShowMechanician',
  // Outside Plan, operating the app the person asked to have operated does not prompt. Everything
  // the vocabulary reaches is inside Mechanician, visible as it happens, and recoverable.
  'mcp__help__OperateMechanician',
])

export function isClaudeBuiltInAutoAllow(toolName) {
  if (typeof toolName !== 'string') return false
  return CLAUDE_SAFE_EXACT_TOOLS.has(toolName)
}

export function isBuildTool(toolName) {
  return toolName === 'Build' || toolName === 'mcp__dev__Build'
}

// Provider/MCP credential stores are never legitimate model-readable workspace inputs. Shell is
// intentionally powerful enough that verb-level parsing cannot prove a command is "only listing"
// a file (Python, awk, xargs, and command substitution can all read it), so fail closed whenever a
// Bash request names one of the known stores or asks Keychain to reveal a generic password.
/// A command name only counts when it is in COMMAND POSITION: the start of the string, or just
/// after a separator that begins a new command (`;`, `&`, `|`, a newline, or an opening
/// substitution). Matching after ANY whitespace is what made this deny `docker ps`, `npm run ps`,
/// `grep -r ps ./src` and `swift build 2>&1 | grep ps`, each with a message about credential
/// stores, which is confidently wrong and fires on ordinary work. Path prefixes stay separate: a
/// FILENAME can legitimately appear as an argument anywhere, so those patterns are unchanged.
const COMMAND_POSITION = '(?:^|[;&|\\n(`])\\s*'

const SHELL_CREDENTIAL_STORE_PATTERNS = [
  /(?:^|[\s'"=])(?:~|\$HOME|\$\{HOME\}|\/Users\/[^/\s'";]+)\/\.claude\.json(?:$|[\s'";])/i,
  /application_default_credentials\.json/i,
  /(?:^|[\s'"=])(?:~|\$HOME|\$\{HOME\}|\/Users\/[^/\s'";]+)\/\.aws\/credentials(?:$|[\s'";])/i,
  /(?:^|[\s'"=])(?:~|\$HOME|\$\{HOME\}|\/Users\/[^/\s'";]+)\/\.(?:netrc|npmrc|pypirc)(?:$|[\s'";])/i,
  /(?:^|[\s'"=])(?:~|\$HOME|\$\{HOME\}|\/Users\/[^/\s'";]+)\/\.ssh\/id_[^\s'";]+/i,
  new RegExp(`${COMMAND_POSITION}(?:\\/usr\\/bin\\/)?security\\s+(?:find-generic-password|dump-keychain)\\b`, 'i'),
  // Provider CLIs can carry MCP bearer tokens in command-line JSON. The process table is therefore
  // a credential store too; exposing it to the model leaked live tokens during diagnosis.
  new RegExp(`${COMMAND_POSITION}(?:\\/bin\\/)?ps(?:\\s|$)`, 'i'),
  new RegExp(`${COMMAND_POSITION}(?:\\/usr\\/bin\\/)?pgrep\\s+[^;&|\\n]*-[^;&|\\n\\s]*(?:a|f)`, 'i'),
  /mcp-auth-header-helper\.mjs/i,
]

export function credentialStoreReadDenial(toolName, input) {
  const candidate = toolName === 'Bash' ? input?.command
    : toolName === 'Read' || toolName === 'Grep' ? (input?.file_path || input?.path)
      : null
  if (typeof candidate !== 'string') return null
  if (!SHELL_CREDENTIAL_STORE_PATTERNS.some((pattern) => pattern.test(candidate))) return null
  return 'Credential stores and process command lines cannot be read by agents. Use Mechanician Accounts or MCP Authorization instead.'
}

/// Namespaces Mechanician itself mounts. Every tool under one of these is a Mechanician built-in
/// whose side effects we know exactly, so anything here that is NOT on the safe list above executes
/// and must keep failing closed in Plan. `mcp__dev__Build` compiles, `mcp__automation__` drives the
/// Mac, `mcp__capabilities__RunCapability` runs a saved script.
///
/// Everything outside these namespaces is a connector the USER mounted.
const MECHANICIAN_MCP_NAMESPACES = [
  'mcp__artifacts__', 'mcp__ask__', 'mcp__automation__', 'mcp__capabilities__',
  'mcp__computer__', 'mcp__dev__', 'mcp__provider_access__', 'mcp__scheduler__',
  'mcp__shortcuts__', 'mcp__waitmode__', 'mcp__help__',
]

// Claude's SDK owns its built-in tools, so Plan needs an explicit fail-closed policy before a
// remembered grant is consulted. The two sensitive review actions remain promptable.
export function claudePlanAuthorization(toolName) {
  // A gate that throws on a malformed name is worse than one that refuses: the rejection would
  // surface as a failed turn rather than a denial. Fail closed instead.
  if (typeof toolName !== 'string' || !toolName) return 'deny'
  if (toolName === 'ComputerScreenshot' || toolName === 'mcp__computer__ComputerScreenshot') {
    return 'sensitive'
  }
  if (toolName === 'ExitPlanMode') return 'prompt'
  if (CLAUDE_PLAN_SAFE_EXACT_TOOLS.has(toolName)) return 'allow'
  // A user-mounted connector is not a tool whose behavior we can infer, but it is also not ours to
  // refuse on the person's behalf: the pinned SDK resolves an MCP tool with no allow rule to `ask`,
  // so denying it silently was Mechanician being stricter than the harness (FR-210). It made
  // "plan a migration by reading a Drive doc" fail with no way to approve it. Prompt instead, and
  // let the person decide. This deliberately does NOT relax our own namespaces above, and the
  // prefix test is what keeps a connector from impersonating one by name.
  if (typeof toolName === 'string'
      && toolName.startsWith('mcp__')
      && !MECHANICIAN_MCP_NAMESPACES.some((prefix) => toolName.startsWith(prefix))) {
    return 'prompt'
  }
  return 'deny'
}

// Return the enforcement decision for a Mechanician-executed OpenAI/Codex
// dynamic tool. Always-allow grants are intentionally considered after plan
// mode, so a grant from an earlier turn cannot turn Review/Plan into execution.
export function localToolAuthorization({ name, permissionMode, alwaysAllowed = false }) {
  if (BOUNDED_LOCAL_PRESENTATION_TOOLS.has(name)) return 'allow'
  if (BOUNDED_LOCAL_OPERATION_TOOLS.has(name)) {
    return permissionMode === 'plan' ? 'deny' : 'allow'
  }
  if (READ_ONLY_TOOLS.has(name)) return 'allow'
  if (permissionMode === 'bypassPermissions') return 'allow'
  // Sensitive reads are valid in Plan/Review, but privacy requires a grant; they
  // are not execution and therefore are not categorically rejected there.
  if (SENSITIVE_READ_TOOLS.has(name)) return alwaysAllowed ? 'allow' : 'prompt'
  if (permissionMode === 'plan') return 'deny'
  if (permissionMode === 'acceptEdits' && EDIT_TOOLS.has(name)) return 'allow'
  if (alwaysAllowed) return 'allow'
  return 'prompt'
}

export function isReadOnlyLocalTool(name) {
  return READ_ONLY_TOOLS.has(name)
}

export function isBoundedLocalPresentationTool(name) {
  return BOUNDED_LOCAL_PRESENTATION_TOOLS.has(name)
}

export function isBoundedLocalOperationTool(name) {
  return BOUNDED_LOCAL_OPERATION_TOOLS.has(name)
}

// ── Remembered approvals ────────────────────────────────────────────────────────
//
// "Always allow" used to be stored as the bare tool name, so approving `Bash` once in a workspace
// approved every shell command there forever, with no inspection of the arguments. That is looser
// than the provider suggested, not stricter (FR-211).
//
// The engine already classifies each call and hands `canUseTool` a set of `permission_suggestions`
// describing the narrowest rule that would cover it: an exact command, a `<prefix> *` rule, or for
// an MCP tool a bare tool name with no content. We key the remembered grant on the engine's own
// rendering of those rules instead of parsing commands ourselves. A later call that the engine
// classifies the same way produces the same key and is allowed; anything else prompts again.
//
// This deliberately reimplements NO matching. Duplicating a provider's classification is what
// produced the two worst defects the constraint audit found, and shell matching is the last place
// to start guessing.

/// The engine's canonical string for a permission rule: `Tool(content)`, or `Tool` when the rule
/// carries no content. Mirrors the renderer in the pinned CLI.
export function permissionRuleKey(rule) {
  if (!rule || typeof rule.toolName !== 'string' || !rule.toolName) return null
  const content = typeof rule.ruleContent === 'string' ? rule.ruleContent.trim() : ''
  return content ? `${rule.toolName}(${content})` : rule.toolName
}

/// Every allow-rule key the engine suggested for THIS call, in the order it offered them.
///
/// Only `addRules` with `behavior: 'allow'` is honored: a `removeRules` or an `ask` suggestion is
/// not a grant. The suggestion's `destination` is ignored on purpose — see `updatedPermissions`
/// below.
export function suggestedAllowKeys(suggestions) {
  if (!Array.isArray(suggestions)) return []
  const keys = []
  for (const suggestion of suggestions) {
    if (!suggestion || suggestion.type !== 'addRules' || suggestion.behavior !== 'allow') continue
    const rules = Array.isArray(suggestion.rules) ? suggestion.rules : []
    for (const rule of rules) {
      const key = permissionRuleKey(rule)
      if (key && !keys.includes(key)) keys.push(key)
    }
  }
  return keys
}

/// Resolve a remembered grant for a call, given the keys the engine suggested for it.
///
/// `hasKey` is the allowlist membership test. Returns the key that granted it, or null.
///
/// The bare tool name is still honored as a LEGACY key. Grants made before rules were narrowed are
/// stored that way, they are visible and revocable in Settings, and silently retiring them would
/// change a user's permissions without telling them. Nothing creates a bare key any more once the
/// engine offers a suggestion.
export function rememberedAllowKey(toolName, suggestedKeys, hasKey) {
  for (const key of suggestedKeys) {
    if (key !== toolName && hasKey(key)) return key
  }
  return hasKey(toolName) ? toolName : null
}

/// The keys to persist when the user answers "always allow".
///
/// The SDK documents that presenting an always-allow option means returning the FULL suggestion
/// set, so all of the engine's suggested rules are remembered rather than only the narrowest. For
/// Bash that is one rule; a skill offers both its exact name and its `name:*` form. Falling back to
/// the bare tool name preserves today's behavior for tools the engine makes no suggestion for.
export function allowKeysToRemember(toolName, suggestedKeys) {
  return suggestedKeys.length ? [...suggestedKeys] : [toolName]
}

// ── Unattended runs ─────────────────────────────────────────────────────────────
//
// A scheduled task has no user and no foreground session. Some tools are read-only and still
// impossible here: `Question` waits for an answer nobody will give, `WaitFor` parks a conversation
// nothing will resume, and the Shortcuts/AppleScript/Capability/Computer family drives the Mac the
// user is (by definition) not sitting at — including capturing their screen.
//
// These are WITHHELD FROM THE TOOL LIST rather than denied at call time. Offering a tool that can
// only ever fail invites the model to plan around it and then report a failure it could not have
// avoided; not offering it produces a task that simply does the achievable thing.
const UNATTENDED_WITHHELD_TOOLS = new Set([
  'Question', 'WaitFor', 'RequestProviderAccess',
  'RunAppleScript', 'RunShortcut', 'ListShortcuts', 'DiscoverAppActions',
  'RunCapability', 'ListCapabilities',
  'ComputerScreenshot', 'ComputerAction',
  // This read requires the foreground app bridge to open and verify the bundled corpus. An
  // unattended one-shot daemon has no such authority channel, so advertising it would only time out.
  'SearchMechanicianHelp', 'mcp__help__SearchMechanicianHelp',
  'RecommendMechanicianWorkflow', 'mcp__help__RecommendMechanicianWorkflow',
  'ShowMechanician', 'mcp__help__ShowMechanician',
  // Operating the interface needs an interface and a person in front of it. Both are absent here.
  'OperateMechanician', 'mcp__help__OperateMechanician',
])

export function isUnattendedWithheldTool(name) {
  return UNATTENDED_WITHHELD_TOOLS.has(name)
}

/// Authorization for a tool call in an unattended run. There is nobody to prompt, so the only
/// answers are allow and deny — a `'prompt'` outcome here would hang a scheduled task until its
/// timeout, which is the worst of both.
export function unattendedToolAuthorization({ name, permissionMode }) {
  if (isUnattendedWithheldTool(name)) return 'deny'
  if (READ_ONLY_TOOLS.has(name)) return 'allow'
  if (permissionMode === 'bypassPermissions') return 'allow'
  return 'deny'
}

/// The tool specs an unattended run may see. `dontAsk` (the default for a scheduled task) is capped
/// at the read-only profile so a task cannot edit files or run shell commands unless its author
/// explicitly chose "Trust all".
export function unattendedToolSpecs(specs, { permissionMode } = {}) {
  return (specs ?? []).filter((spec) => {
    const name = spec?.name
    if (!name || isUnattendedWithheldTool(name)) return false
    if (permissionMode === 'bypassPermissions') return true
    return READ_ONLY_TOOLS.has(name)
  })
}

const DEFAULTS = Object.freeze({
  anthropicAPIKey: 'ANTHROPIC_API_KEY',
  openAIAPIKey: 'OPENAI_API_KEY',
  mcpSecret: 'ai.mechanician.mcp-secret',
  mcpOAuth: 'ai.mechanician.mcp-oauth',
})

// Service names cross from the signed app into the native Keychain helper as a single argument.
// Accept only the reverse-DNS/key-name alphabet emitted by MechanicianEnvironment; an invalid or
// inherited value falls back to the historical public service instead of addressing an arbitrary
// Keychain record.
export function validatedCredentialService(value, fallback) {
  return typeof value === 'string' && value.length > 0 && value.length <= 200
    && /^[A-Za-z0-9._-]+$/.test(value)
    ? value
    : fallback
}

export function credentialServices(environment = process.env) {
  return {
    anthropicAPIKey: validatedCredentialService(
      environment.MECHANICIAN_ANTHROPIC_API_KEY_SERVICE, DEFAULTS.anthropicAPIKey),
    openAIAPIKey: validatedCredentialService(
      environment.MECHANICIAN_OPENAI_API_KEY_SERVICE, DEFAULTS.openAIAPIKey),
    mcpSecret: validatedCredentialService(
      environment.MECHANICIAN_MCP_SECRET_SERVICE, DEFAULTS.mcpSecret),
    mcpOAuth: validatedCredentialService(
      environment.MECHANICIAN_MCP_OAUTH_SERVICE, DEFAULTS.mcpOAuth),
  }
}

export const DEFAULT_CREDENTIAL_SERVICES = DEFAULTS

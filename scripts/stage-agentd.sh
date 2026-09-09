#!/usr/bin/env bash
# Materialize the exact production agentd dependency tree described by package-lock.json.
# Install scripts are deliberately disabled: release inputs must not execute registry-provided
# lifecycle hooks. node-pty ships the darwin prebuild that Mechanician uses at runtime.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-}"

if [ -z "$DEST" ]; then
  echo "usage: $0 /absolute/output/directory" >&2
  exit 64
fi
case "$DEST" in
  /*) ;;
  *) echo "!! output directory must be absolute: $DEST" >&2; exit 64 ;;
esac
[ ! -e "$DEST" ] \
  || { echo "!! output already exists (remove it explicitly first): $DEST" >&2; exit 1; }

# Non-interactive macOS shells do not consistently include Homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
command -v node >/dev/null || { echo "!! Node.js is required to stage agentd" >&2; exit 1; }
command -v npm >/dev/null || { echo "!! npm is required to stage agentd" >&2; exit 1; }

PARENT="$(dirname "$DEST")"
mkdir -p "$PARENT"
TMP="$(mktemp -d "$PARENT/.agentd-stage.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cp "$REPO/agentd/package.json" "$REPO/agentd/package-lock.json" "$TMP/"
(
  cd "$TMP"
  npm ci --omit=dev --ignore-scripts --no-audit --no-fund
  npm audit signatures
)

# node-pty invokes this helper directly. npm lifecycle scripts normally set this bit, but release
# staging disables all lifecycle scripts and performs the one required, auditable action here.
find "$TMP/node_modules/node-pty" -name spawn-helper -exec chmod +x {} +

# Smoke-test the modules that the daemon imports before accepting the stage. Use only imports here;
# starting a provider engine belongs to runtime integration tests, not dependency installation.
(
  cd "$TMP"
  node --input-type=module -e \
    "await Promise.all([import('@anthropic-ai/claude-agent-sdk'), import('diff'), import('isomorphic-git'), import('node-pty'), import('zod')])"

  # @openai/codex's JavaScript entry point launches the CLI, so validate the locked package and
  # its direct Darwin arm64 App Server executable instead of importing it. This is the exact path
  # agentd and the Swift account probe resolve inside Mechanician.app.
  EXPECTED_CODEX_VERSION="0.148.0"
  CODEX_VERSION="$(node -p "require('./node_modules/@openai/codex/package.json').version")"
  [ "$CODEX_VERSION" = "$EXPECTED_CODEX_VERSION" ] \
    || { echo "!! staged Codex $CODEX_VERSION does not match audited $EXPECTED_CODEX_VERSION"; exit 1; }
  CODEX_BIN="node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
  [ -x "$CODEX_BIN" ] || { echo "!! staged Codex App Server missing: $CODEX_BIN"; exit 1; }
  [ "$("./$CODEX_BIN" --version)" = "codex-cli $EXPECTED_CODEX_VERSION" ] \
    || { echo "!! staged Codex executable failed its version check"; exit 1; }

  npm sbom --omit=dev --sbom-format=cyclonedx > agentd-sbom.raw.json
  # npm injects a random UUID and wall-clock timestamp. Remove those optional fields so identical
  # lockfiles produce an identical SBOM and do not make otherwise reproducible bundles differ.
  node --input-type=module -e \
    "import fs from 'node:fs'; const b=JSON.parse(fs.readFileSync('agentd-sbom.raw.json')); delete b.serialNumber; if (b.metadata) { delete b.metadata.timestamp; if (b.metadata.component) b.metadata.component.name='@mechanician/agentd'; } fs.writeFileSync('agentd-sbom.cdx.json', JSON.stringify(b, null, 2) + '\\n')"
  rm agentd-sbom.raw.json
)

mv "$TMP" "$DEST"
trap - EXIT
echo "==> staged locked production dependencies: $DEST"
